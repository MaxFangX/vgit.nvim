local utils = require('vgit.core.utils')
local Spawn = require('vgit.core.Spawn')

describe('Spawn:', function()
  describe('constructor', function()
    it('should be able to construct Spawn with specifications', function()
      Spawn({
        command = 'ls',
        args = { '-l' },
        on_stderr = function() end,
        on_stdout = function() end,
        on_exit = function() end,
      })
    end)
  end)

  describe('parse_result', function()
    it('parses the output correctly', function()
      local spawn = Spawn({
        command = 'ls',
        args = { '-l' },
        on_stderr = function() end,
        on_stdout = function() end,
        on_exit = function() end,
      })
      local output = {}
      spawn:parse_result({ 'line1\nline2\nline3', '\nline4', '\nline5\nline6' }, function(line)
        table.insert(output, line)
      end)
      assert.are.same(table.concat(output), 'line1line2line3line4line5line6')
    end)
  end)

  describe('start', function()
    it('should be able to spawn a process and pipe stdout', function()
      local stdout = {}

      Spawn({
        command = 'ls',
        args = { '-l' },
        on_stderr = function() end,
        on_stdout = function(line)
          table.insert(stdout, line)
        end,
        on_exit = function()
          assert.is_true(not utils.list.is_empty(stdout))
        end,
      }):start()
    end)

    it('should pipe stderr correctly', function()
      local stderr = {}
      local stdout = {}

      Spawn({
        command = 'ls',
        args = { '-lasdasd' },
        on_stderr = function(line)
          table.insert(stdout, line)
        end,
        on_stdout = function(line)
          table.insert(stdout, line)
        end,
        on_exit = function()
          assert.is_true(utils.list.is_empty(stderr))
          assert.is_true(not utils.list.is_empty(stdout))
        end,
      }):start()
    end)
  end)
end)

local async = require('plenary.async.tests')
local loop = require('vgit.core.loop')

-- Run a Spawn to completion, returning its exit code and stderr lines.
local run = loop.suspend(function(spec, callback)
  local stderr = {}
  spec.on_stderr = function(line)
    stderr[#stderr + 1] = line
  end
  spec.on_exit = function(code)
    callback(code, stderr)
  end
  Spawn(spec):start()
end, 2)

local function process_handles()
  local count = 0
  vim.loop.walk(function(handle)
    if handle:get_type() == 'process' and not handle:is_closing() then count = count + 1 end
  end)
  return count
end

async.describe('Spawn lifecycle:', function()
  async.it('exits -1 with the error on stderr when the command is missing', function()
    local code, stderr = run({ command = 'vgit-no-such-binary', args = {} })
    assert.are.same(code, -1)
    assert.is_true(#stderr > 0)
  end)

  async.it('closes the process handle on exit', function()
    local before = process_handles()
    for _ = 1, 3 do
      run({ command = 'true', args = {} })
    end
    loop.free_textlock()
    assert.are.same(process_handles(), before)
  end)
end)
