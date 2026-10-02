-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Binary records and ASCII armor for the PGP-style tool (tsr.pgp).
-- A binary blob is a sequence of records:  u8 type, u32 length, data.  Armor wraps a blob in base64 between BEGIN/END lines with a
-- CRC-32 check line, so keys, signatures and encrypted messages can be pasted into a terminal, a chat or a book.
local hash = require("tsr.hash")

local floor = math.floor
local schar, sbyte = string.char, string.byte

local M = {}

M.TYPE = { KEY = 1, SELFSIG = 2, CERT = 3, REVOKE = 4, SECRET = 5, SIGNATURE = 6, PKESK = 7, SKESK = 8, DATA = 9, HEADER = 10 }

function M.u8(n) return schar(n % 256) end
function M.u16(n) return schar(floor(n / 256) % 256, n % 256) end
function M.u32(n) return schar(floor(n / 16777216) % 256, floor(n / 65536) % 256, floor(n / 256) % 256, n % 256) end
function M.u64(n)
  local b = {}
  for i = 8, 1, -1 do b[i] = n % 256 n = floor(n / 256) end
  return schar(table.unpack(b))
end

--- A reader over a binary string: r:u8(), r:u16(), r:u32(), r:u64(), r:bytes(n), r:rest(), r:eof().
function M.reader(s)
  local pos = 1
  local r = {}
  local function need(n) if pos + n - 1 > #s then error("truncated data", 0) end end
  function r:u8() need(1) local v = sbyte(s, pos) pos = pos + 1 return v end
  function r:u16() need(2) local a, b = sbyte(s, pos, pos + 1) pos = pos + 2 return a * 256 + b end
  function r:u32() need(4) local a, b, c, d = sbyte(s, pos, pos + 3) pos = pos + 4 return ((a * 256 + b) * 256 + c) * 256 + d end
  function r:u64()
    need(8)
    local v = 0
    for i = 0, 7 do v = v * 256 + sbyte(s, pos + i) end
    pos = pos + 8
    return v
  end
  function r:bytes(n) need(n) local v = s:sub(pos, pos + n - 1) pos = pos + n return v end
  function r:rest() local v = s:sub(pos) pos = #s + 1 return v end
  function r:eof() return pos > #s end
  return r
end

--- Concatenate records: list of { type, data }.
function M.records(list)
  local out = {}
  for i, rec in ipairs(list) do out[i] = M.u8(rec[1]) .. M.u32(#rec[2]) .. rec[2] end
  return table.concat(out)
end

--- Split a blob into records. Returns a list of { type, data } or nil + reason.
function M.parse(bin)
  local out = {}
  local ok, err = pcall(function()
    local r = M.reader(bin)
    while not r:eof() do
      local t, len = r:u8(), r:u32()
      out[#out + 1] = { t, r:bytes(len) }
    end
  end)
  if not ok then return nil, tostring(err) end
  return out
end

---------------------------------------------------------------------------------------------------------------------
-- Armor
---------------------------------------------------------------------------------------------------------------------

--- Text form of a blob: kind is e.g. "PUBLIC KEY", "SIGNATURE", "MESSAGE".
function M.armor(kind, bin)
  local b64 = hash.base64Encode(bin)
  local lines = { "-----BEGIN TESSERA " .. kind .. "-----", "" }
  for i = 1, #b64, 64 do lines[#lines + 1] = b64:sub(i, i + 63) end
  local crc = hash.crc32(bin)
  lines[#lines + 1] = "=" .. hash.base64Encode(M.u32(crc))
  lines[#lines + 1] = "-----END TESSERA " .. kind .. "-----"
  return table.concat(lines, "\n") .. "\n"
end

--- Find the first armored block in `text` (optionally of one `kind`). Returns kind, blob, rest-of-text or nil + reason.
function M.dearmor(text, wanted)
  local start = 1
  while true do
    local a, b, kind = text:find("%-%-%-%-%-BEGIN TESSERA ([%u ]-)%-%-%-%-%-\r?\n", start)
    if not a then return nil, "no armored data found" end
    local endLine = "-----END TESSERA " .. kind .. "-----"
    local c, d = text:find(endLine, b + 1, true)
    if not c then return nil, "armor is missing its END line" end
    if not wanted or wanted == kind then
      local body = text:sub(b + 1, c - 1)
      local crcLine = body:match("\n=(%S+)%s*$") or body:match("^=(%S+)%s*$")
      local data = body:gsub("\n=%S+%s*$", ""):gsub("%s+", "")
      local bin = hash.base64Decode(data)
      if not bin then return nil, "armor is damaged (bad base64)" end
      if crcLine then
        local want = hash.base64Decode(crcLine)
        if not want or #want ~= 4 or want ~= M.u32(hash.crc32(bin)) then return nil, "armor checksum mismatch (the text was damaged in transit)" end
      end
      return kind, bin, text:sub(d + 1)
    end
    start = d + 1
  end
end

return M
