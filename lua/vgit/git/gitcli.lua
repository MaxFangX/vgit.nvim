local loop = require('vgit.core.loop')
local Spawn = require('vgit.core.Spawn')
local console = require('vgit.core.console')
local git_setting = require('vgit.settings.git')

local gitcli = {}

-- Returns stdout lines, or with `opts.raw` one unsplit string (for `-z`
-- output). By default any stderr output is a failure. `opts.by_exit_code`
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
-- '<oid> <type> <size>' header plus content, or '<request> missing' (or
-- 'ambiguous'). Only blobs are file content, so a tree (file <-> dir change)
-- or a gitlink (submodule) counts as missing.
local function parse_batch(output, count)
  local results = {}
  local blob_lines = {} -- oid -> lines
  local pos = 1
  for i = 1, count do
    local nl = output:find('\n', pos, true)
    if not nl then return nil, { 'git cat-file: output ended early' } end

    local oid, type, size = output:sub(pos, nl - 1):match('^(%x+) (%a+) (%d+)$')
    if not size then
      results[i] = { missing = true }
      pos = nl + 1
    else
      size = tonumber(size)
      if nl + size + 1 > #output then return nil, { 'git cat-file: output ended early' } end
      if type == 'blob' then
        blob_lines[oid] = blob_lines[oid] or to_lines(output:sub(nl + 1, nl + size))
        results[i] = { lines = blob_lines[oid] }
      else
        results[i] = { missing = true }
      end
      pos = nl + size + 2 -- skip content and its separator newline
    end
  end
  return results
end

-- Fetch many objects' contents through one `git cat-file --batch` process.
-- `requests` is a list of object names (e.g. '<rev>:<path>'). Returns a list
-- aligned with it of { lines = {...} } or { missing = true }, or nil, err if
-- git fails. Requests for the same blob share one line array, so line arrays
-- must not be modified.
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

local MAX_PARALLEL = 50

-- Run several git commands in parallel, at most MAX_PARALLEL at a time.
-- Each command is an args table (as for gitcli.run); returns a list aligned
-- with them of { result = lines } or { err = lines }.
gitcli.run_parallel = loop.suspend(function(commands, callback)
  local cmd = git_setting:get('cmd')
  local results = {}
  local total = #commands
  if total == 0 then return callback(results) end

  local next_idx, running, completed = 1, 0, 0

  local function start_next()
    while running < MAX_PARALLEL and next_idx <= total do
      local i = next_idx
      next_idx = next_idx + 1
      running = running + 1

      local stdout, stderr = {}, {}
      Spawn({
        command = cmd,
        args = commands[i],
        on_stdout = function(line)
          stdout[#stdout + 1] = line
        end,
        on_stderr = function(line)
          stderr[#stderr + 1] = line
        end,
        on_exit = function()
          results[i] = #stderr == 0 and { result = stdout } or { err = stderr }
          running = running - 1
          completed = completed + 1
          if completed == total then
            -- Resume the caller in Vim context once, not per process
            vim.schedule(function()
              callback(results)
            end)
          else
            start_next()
          end
        end,
      }):start()
    end
  end

  start_next()
end, 2)

return gitcli
