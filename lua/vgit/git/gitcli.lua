local loop = require('vgit.core.loop')
local Spawn = require('vgit.core.Spawn')
local console = require('vgit.core.console')
local git_setting = require('vgit.settings.git')

local gitcli = {}

-- Fast spawn that doesn't use vim.schedule for each callback
-- Only safe when callbacks don't call Vim APIs
local function spawn_fast(spec)
  local stdout_result = {}
  local stderr_result = {}
  local stdout = vim.loop.new_pipe(false)
  local stderr = vim.loop.new_pipe(false)

  local on_stdout = function(_, chunk)
    if chunk then stdout_result[#stdout_result + 1] = chunk end
  end

  local on_stderr = function(_, chunk)
    if chunk then stderr_result[#stderr_result + 1] = chunk end
  end

  -- Parse output into lines (same as Spawn:parse_result but inline)
  local function parse_lines(output)
    local lines = {}
    local text = table.concat(output)
    local start = 1
    while true do
      local newline_pos = text:find('\n', start, true)
      if not newline_pos then
        if start <= #text then
          lines[#lines + 1] = text:sub(start)
        end
        break
      end
      lines[#lines + 1] = text:sub(start, newline_pos - 1)
      start = newline_pos + 1
    end
    return lines
  end

  local on_exit = function()
    stdout:read_stop()
    stderr:read_stop()
    if not stdout:is_closing() then stdout:close() end
    if not stderr:is_closing() then stderr:close() end

    local out_lines = parse_lines(stdout_result)
    local err_lines = parse_lines(stderr_result)
    if spec.on_exit then spec.on_exit(out_lines, err_lines) end
  end

  vim.loop.spawn(spec.command, {
    args = spec.args,
    stdio = { nil, stdout, stderr },
  }, on_exit)

  stdout:read_start(on_stdout)
  stderr:read_start(on_stderr)
end

-- Returns stdout lines, or with `opts.raw` stdout as one unsplit string (for
-- `-z` output). By default any stderr output is a failure. `opts.by_exit_code`
-- judges by the exit code instead, for read-only commands whose stderr can
-- carry warnings on success (rename-limit, ambiguous refnames, signatures).
-- `opts.env` replaces the environment (luv's `KEY=value` list).
gitcli.run = loop.suspend(function(args, opts, callback)
  local cmd = git_setting:get('cmd')

  opts = opts or {}
  local debug = opts.debug

  if debug then console.info(cmd .. ' ' .. table.concat(args, ' ')) end

  local err = {}
  local stdout = {}

  Spawn({
    command = cmd,
    args = args,
    env = opts.env,
    on_stderr = function(line)
      err[#err + 1] = line
    end,
    on_stdout = not opts.raw and function(line)
      stdout[#stdout + 1] = line
    end or nil,
    on_stdout_raw = opts.raw and function(output)
      stdout = output
    end or nil,
    on_exit = function(code)
      local failed
      if opts.by_exit_code then
        failed = code ~= 0
      else
        failed = #err ~= 0
      end
      if not failed then return callback(stdout, nil) end
      if #err == 0 then err = { string.format('%s exited with code %d', cmd, code) } end
      callback(nil, err)
    end,
  }):start()
end, 3)

-- Mirror `git show` line semantics ('' -> {}, trailing newline dropped)
local function to_lines(content)
  if content == '' then return {} end
  if content:sub(-1) == '\n' then content = content:sub(1, -2) end
  return vim.split(content, '\n', { plain = true })
end

-- Parse `cat-file --batch` output for `count` requests. Each response is a
-- '<oid> <type> <size>' header plus content, or '<request> missing' (also
-- 'ambiguous'). Only blobs count as found: a tree (file <-> dir change) or a
-- gitlink (submodule) isn't file content.
local function parse_batch(output, count)
  local results = {}
  local pos = 1
  for i = 1, count do
    local nl = output:find('\n', pos, true)
    if not nl then return nil, { 'git cat-file: output ended early' } end

    local type, size = output:sub(pos, nl - 1):match('^%x+ (%a+) (%d+)$')
    if not size then
      results[i] = { missing = true }
      pos = nl + 1
    else
      size = tonumber(size)
      if nl + size + 1 > #output then return nil, { 'git cat-file: output ended early' } end
      results[i] = type == 'blob' and { lines = to_lines(output:sub(nl + 1, nl + size)) } or { missing = true }
      pos = nl + size + 2 -- skip content and its separator newline
    end
  end
  return results
end

-- Fetch many objects' contents through one `git cat-file --batch` process.
-- `requests` is a list of object names (e.g. '<rev>:<path>'); returns a list
-- aligned with it: { lines = {...} } or { missing = true } per request, or
-- nil, err if git fails. Responses are framed by byte-length headers, so any
-- content (including binary) parses safely.
gitcli.cat_file_batch = loop.suspend(function(reponame, requests, callback)
  if #requests == 0 then return callback({}) end

  local output = ''
  local err = {}

  Spawn({
    command = git_setting:get('cmd'),
    args = { '-C', reponame, 'cat-file', '--batch' },
    stdin = table.concat(requests, '\n') .. '\n',
    on_stdout_raw = function(raw)
      output = raw
    end,
    on_stderr = function(line)
      err[#err + 1] = line
    end,
    on_exit = function(code)
      local results, parse_err
      if code ~= 0 then
        parse_err = #err > 0 and err or { string.format('git cat-file exited with code %d', code) }
      else
        results, parse_err = parse_batch(output, #requests)
      end
      vim.schedule(function()
        callback(results, parse_err)
      end)
    end,
  }):start()
end, 3)

-- Run multiple git commands in parallel with concurrency limit
-- Each item in commands_list is an args table (same format as gitcli.run)
-- Runs up to 50 processes concurrently to avoid overwhelming the system
gitcli.run_parallel = loop.suspend(function(commands_list, callback)
  local cmd = git_setting:get('cmd')
  local results = {}
  local total = #commands_list
  local max_concurrent = 50

  if total == 0 then
    return callback(results)
  end

  local next_idx = 1
  local running = 0
  local completed = 0

  local function start_next()
    while running < max_concurrent and next_idx <= total do
      local i = next_idx
      next_idx = next_idx + 1
      running = running + 1

      local args = commands_list[i]

      spawn_fast({
        command = cmd,
        args = args,
        on_exit = function(stdout, err)
          if #err ~= 0 then
            results[i] = { result = nil, err = err }
          else
            results[i] = { result = stdout, err = nil }
          end
          running = running - 1
          completed = completed + 1
          if completed == total then
            -- Schedule callback to run in Vim context (once, not 754 times)
            vim.schedule(function()
              callback(results)
            end)
          else
            start_next()
          end
        end,
      })
    end
  end

  start_next()
end, 2)

return gitcli
