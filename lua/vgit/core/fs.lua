local Path = require('plenary.path')
local plenary_filetype = require('plenary.filetype')

local fs = {}

fs.detect_filetype = plenary_filetype.detect

function fs.make_relative(dirname, filepath)
  return Path:new(filepath):make_relative(dirname)
end

function fs.relative_filename(filepath)
  return fs.make_relative(vim.loop.cwd(), filepath)
end

function fs.short_filename(filepath)
  local filename = ''

  for i = #filepath, 1, -1 do
    local letter = filepath:sub(i, i)
    if letter == '/' then break end
    filename = letter .. filename
  end

  return filename
end

function fs.tmpname()
  return os.tmpname()
end

function fs.filetype(buffer)
  return buffer:get_option('filetype')
end

function fs.read_file(filepath)
  if not fs.exists(filepath) then return nil, { 'file not found' } end
  return vim.fn.readfile(filepath)
end

function fs.write_file(filepath, lines)
  local fd, open_err = io.open(filepath, 'wb')
  if not fd then return nil, { open_err } end

  local ok, err = true, nil
  for i = 1, #lines do
    ok, err = fd:write(lines[i], '\n')
    if not ok then break end
  end

  local closed, close_err = fd:close()
  if not ok or not closed then return nil, { err or close_err } end
end

-- Write via a sibling temp file and rename, so a crash mid-write leaves the
-- previous file intact instead of a truncated one. The temp file is this
-- process's own, so concurrent writers can't truncate each other's. Returns
-- the stat of the file written, taken before the rename, so it describes
-- this write even if another writer replaces the file right after.
function fs.write_file_atomic(filepath, lines)
  local tmp = string.format('%s.%d.tmp', filepath, vim.loop.os_getpid())
  local _, err = fs.write_file(tmp, lines)
  local stat = not err and vim.loop.fs_stat(tmp)
  local ok, rename_err = stat and os.rename(tmp, filepath)
  if not ok then
    os.remove(tmp)
    return nil, err or { rename_err or 'failed to stat ' .. tmp }
  end
  return stat
end

function fs.remove_file(filepath)
  return os.remove(filepath)
end

function fs.exists(filepath)
  return (vim.loop.fs_stat(filepath) and true) or false
end

function fs.dirname(filepath)
  return vim.fn.fnamemodify(filepath, ':h') or ''
end

function fs.is_dir(filepath)
  return Path:new(filepath):is_dir()
end

function fs.open(filepath)
  vim.cmd.drop(vim.fn.fnameescape(filepath))

  return fs
end

return fs
