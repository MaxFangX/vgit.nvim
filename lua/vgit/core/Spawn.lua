local loop = require('vgit.core.loop')
local Object = require('vgit.core.Object')

local Spawn = Object:extend()

function Spawn:constructor(spec)
  return { spec = spec }
end

function Spawn:parse_result(output, callback)
  if not callback then return end

  output = table.concat(output)

  local start = 1
  while true do
    local newline_pos = output:find('\n', start, true)
    if not newline_pos then
      -- Last line without newline
      if start <= #output then
        callback(output:sub(start))
      end
      break
    end
    callback(output:sub(start, newline_pos - 1))
    start = newline_pos + 1
  end
end

-- spec: command, args, cwd, env (luv's `KEY=value` list, replaces the
-- environment), stdin (string written to the process), and callbacks
-- on_stdout/on_stderr (per line), on_stdout_raw (all of stdout, unsplit),
-- and on_exit(code, signal).
function Spawn:start()
  local stdout_result = {}
  local stderr_result = {}
  local stdin = self.spec.stdin and vim.loop.new_pipe(false)
  local stdout = vim.loop.new_pipe(false)
  local stderr = vim.loop.new_pipe(false)
  local handle

  local on_stdout = function(_, chunk)
    if chunk then stdout_result[#stdout_result + 1] = chunk end
  end

  local on_stderr = function(_, chunk)
    if chunk then stderr_result[#stderr_result + 1] = chunk end
  end

  local on_exit = loop.coroutine(function(code, signal)
    stdout:read_stop()
    stderr:read_stop()

    if stdin and not stdin:is_closing() then stdin:close() end
    if not stdout:is_closing() then stdout:close() end
    if not stderr:is_closing() then stderr:close() end
    if handle and not handle:is_closing() then handle:close() end

    self:parse_result(stdout_result, self.spec.on_stdout)
    if self.spec.on_stdout_raw then self.spec.on_stdout_raw(table.concat(stdout_result)) end
    self:parse_result(stderr_result, self.spec.on_stderr)

    if self.spec.on_exit then self.spec.on_exit(code, signal) end
  end)

  local err
  handle, err = vim.loop.spawn(self.spec.command, {
    args = self.spec.args,
    stdio = { stdin, stdout, stderr },
    cwd = self.spec.cwd,
    env = self.spec.env,
  }, on_exit)

  -- Spawn failed (e.g. command not found): report it as stderr and exit -1,
  -- so callers waiting on on_exit don't hang
  if not handle then
    stderr_result[1] = err
    on_exit(-1, 0)
    return self
  end

  stdout:read_start(on_stdout)
  stderr:read_start(on_stderr)
  if stdin then
    stdin:write(self.spec.stdin, function()
      if not stdin:is_closing() then stdin:shutdown() end
    end)
  end

  return self
end

return Spawn
