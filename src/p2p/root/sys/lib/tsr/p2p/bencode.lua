-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Bencode, the encoding of BitTorrent metadata: integers  i42e,  strings  4:spam,  lists  l...e,  dictionaries  d...e  (keys sorted).
-- Dictionary keys are sorted, so encoding is canonical: the same data always gives the same bytes, which is what makes an
-- info hash well defined. In Lua a table with keys 1..n is a list, any other table (also an empty one) is a dictionary.
local M = {}

local sformat = string.format

local function isList(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
    n = n + 1
  end
  return n > 0 and n == #t
end

local function enc(v, out)
  local t = type(v)
  if t == "number" then
    if v % 1 ~= 0 then error("bencode has no floating point numbers", 0) end
    out[#out + 1] = sformat("i%.0fe", v)
  elseif t == "string" then
    out[#out + 1] = #v .. ":" .. v
  elseif t == "table" then
    if isList(v) then
      out[#out + 1] = "l"
      for i = 1, #v do enc(v[i], out) end
      out[#out + 1] = "e"
    else
      local keys = {}
      for k in pairs(v) do
        if type(k) ~= "string" then error("dictionary keys must be strings", 0) end
        keys[#keys + 1] = k
      end
      table.sort(keys)
      out[#out + 1] = "d"
      for _, k in ipairs(keys) do
        out[#out + 1] = #k .. ":" .. k
        enc(v[k], out)
      end
      out[#out + 1] = "e"
    end
  elseif t == "boolean" then
    out[#out + 1] = v and "i1e" or "i0e"
  else
    error("cannot encode a " .. t, 0)
  end
end

--- Encode a value (number, string, boolean, list or dictionary) to a string.
function M.encode(v)
  local out = {}
  enc(v, out)
  return table.concat(out)
end

local function dec(s, pos, depth)
  if depth > 32 then error("nested too deeply", 0) end
  local c = s:sub(pos, pos)
  if c == "i" then
    local num, stop = s:match("^(-?%d+)e()", pos + 1)
    if not num or (num:sub(1, 1) == "0" and #num > 1) or num == "-0" then error("bad integer at " .. pos, 0) end
    return tonumber(num), stop
  elseif c == "l" then
    local list, p = {}, pos + 1
    while s:sub(p, p) ~= "e" do
      if p > #s then error("unterminated list", 0) end
      list[#list + 1], p = dec(s, p, depth + 1)
    end
    return list, p + 1
  elseif c == "d" then
    local dict, p, last = {}, pos + 1, nil
    while s:sub(p, p) ~= "e" do
      if p > #s then error("unterminated dictionary", 0) end
      local key
      key, p = dec(s, p, depth + 1)
      if type(key) ~= "string" then error("dictionary key is not a string", 0) end
      if last and key <= last then error("dictionary keys out of order", 0) end
      last = key
      dict[key], p = dec(s, p, depth + 1)
    end
    return dict, p + 1
  elseif c:match("%d") then
    local len, start = s:match("^(%d+):()", pos)
    if not len then error("bad string at " .. pos, 0) end
    len = tonumber(len)
    if start + len - 1 > #s then error("string runs past the end", 0) end
    return s:sub(start, start + len - 1), start + len
  end
  error("unexpected '" .. c .. "' at " .. pos, 0)
end

--- Decode a complete bencoded string. Returns the value or nil + reason.
function M.decode(s)
  local ok, v, stop = pcall(dec, s, 1, 0)
  if not ok then return nil, tostring(v) end
  if stop ~= #s + 1 then return nil, "trailing data after the value" end
  return v
end

return M
