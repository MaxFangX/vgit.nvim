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
    on_stderr = function(line)
      err[#err + 1] = line
    end,
    on_stdout = function(line)
      stdout[#stdout + 1] = line
    end,
    on_exit = function()
      if #err ~= 0 then return callback(nil, err) end
      callback(stdout, nil)
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
