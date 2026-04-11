local bit = require('bit')

local str = {}

str.split = vim.split

-- FNV-1a hash (32-bit, pure Lua)
-- Returns an 8-character hex string.
function str.fnv1a(s)
  local hash = 2166136261
  for i = 1, #s do
    hash = bit.bxor(hash, s:byte(i))
    hash = bit.band(hash * 16777619, 0xFFFFFFFF)
  end
  -- Ensure unsigned for formatting (LuaJIT bit ops return signed int32)
  if hash < 0 then hash = hash + 0x100000000 end
  return string.format('%08x', hash)
end

function str.length(s)
  local _, count = string.gsub(s, '[^\128-\193]', '')

  return count
end

function str.shorten(s, limit)
  if #s > limit then
    s = s:sub(1, limit - 3)
    s = s .. '...'
  end

  return s
end

function str.concat(existing_text, new_text)
  local top_range = #existing_text
  local end_range = top_range + #new_text
  local text = existing_text .. new_text

  return text, {
    top = top_range,
    bot = end_range,
  }
end

function str.strip(given_string, substring)
  if substring == '' then return given_string end

  local rc_s = ''
  local i = 1
  local found = false

  while i <= #given_string do
    local temp_i = 0

    if not found then
      for j = 1, #substring do
        local s_j = substring:sub(j, j)
        local s_i = given_string:sub(i + temp_i, i + temp_i)

        if s_j == s_i then temp_i = temp_i + 1 end
      end
    end
    if temp_i == #substring then
      found = true
      i = i + temp_i
    else
      rc_s = rc_s .. given_string:sub(i, i)
      i = i + 1
    end
  end

  return rc_s
end

return str
