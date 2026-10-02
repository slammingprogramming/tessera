-- SPDX-License-Identifier: AGPL-3.0-or-later
-- DEFLATE compression (RFC 1951): LZ77 matching with a hash of the next three bytes (window 32 KB, lazy matching) and the fixed
-- Huffman codes. The output is a valid raw DEFLATE stream that zlib, gzip, Node and tsr.inflate all read; it does not reach the ratio of a
-- tuned compressor with dynamic Huffman tables (expect roughly 40-60% of the original size for text and Lua), but it is small and quick
-- enough for a ComputerCraft computer. Incompressible data falls back to stored blocks, so the output is never much larger than the input.
local hash = require("tsr.hash")
local yield = require("tsr.crypto.yield")

local sbyte, schar = string.byte, string.char
local floor = math.floor

local M = {}

M.WINDOW = 32768
M.MAX_CHAIN = 24          -- how many earlier positions with the same hash are tried
M.MAX_MATCH = 258
M.MIN_MATCH = 3

-- length code table: for lengths 3..258 -> code 257..285, extra bits and base
local LBASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEXT = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DBASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
                4097, 6145, 8193, 12289, 16385, 24577 }
local DEXT = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }

local lengthCode = {}      -- length -> code index (1..29)
do
  local code = 1
  for len = 3, 258 do
    while code < 29 and LBASE[code + 1] <= len do code = code + 1 end
    lengthCode[len] = code
  end
  lengthCode[258] = 29
end

local function distCode(d)
  local lo, hi = 1, 30
  while lo < hi do
    local mid = floor((lo + hi + 1) / 2)
    if DBASE[mid] <= d then lo = mid else hi = mid - 1 end
  end
  return lo
end

--- A bit writer: bits are packed least significant first; Huffman codes are written most significant bit first.
local function writer()
  local out, n = {}, 0
  local cur, bits = 0, 0
  local w = {}
  function w.bits(value, count)               -- value's low `count` bits, LSB first
    cur = cur + value * 2 ^ bits
    bits = bits + count
    while bits >= 8 do
      n = n + 1
      out[n] = schar(cur % 256)
      cur = floor(cur / 256)
      bits = bits - 8
    end
  end
  function w.code(code, len)                  -- a Huffman code: reverse so the first bit lands first
    local rev = 0
    for _ = 1, len do rev = rev * 2 + code % 2 code = floor(code / 2) end
    w.bits(rev, len)
  end
  function w.align()
    if bits > 0 then n = n + 1 out[n] = schar(cur % 256) cur, bits = 0, 0 end
  end
  function w.bytes(s) w.align() n = n + 1 out[n] = s end
  function w.result() w.align() return table.concat(out) end
  return w
end

local function literalCode(w, sym)             -- fixed Huffman literal/length code of symbol 0..287
  if sym < 144 then w.code(0x30 + sym, 8)
  elseif sym < 256 then w.code(0x190 + sym - 144, 9)
  elseif sym < 280 then w.code(sym - 256, 7)
  else w.code(0xC0 + sym - 280, 8) end
end

--- Compress `data` to a raw DEFLATE stream. level 0 stores without compression.
function M.deflate(data, level)
  local len = #data
  if level == 0 or len == 0 then
    -- stored blocks (also the representation of an empty input)
    local w = writer()
    if len == 0 then w.bits(1, 1) w.bits(0, 2) w.align() w.bytes("\0\0\255\255") return w.result() end
    local pos = 1
    while pos <= len do
      local piece = data:sub(pos, pos + 65534)
      local last = pos + #piece > len
      w.bits(last and 1 or 0, 1) w.bits(0, 2) w.align()
      w.bytes(schar(#piece % 256, floor(#piece / 256), (65535 - #piece) % 256, floor((65535 - #piece) / 256)) .. piece)
      pos = pos + #piece
    end
    return w.result()
  end
  local w = writer()
  w.bits(1, 1)          -- one final block
  w.bits(1, 2)          -- fixed Huffman
  local head, prev = {}, {}
  local function key(i)
    local a, b, c = sbyte(data, i, i + 2)
    return (a * 256 + b) * 256 + c
  end
  local function insert(i)
    if i + 2 > len then return end
    local k = key(i)
    prev[i] = head[k]
    head[k] = i
  end
  local function findMatch(i)
    if i + 2 > len then return 0, 0 end
    local candidate = head[key(i)]
    local bestLen, bestDist = 0, 0
    local chain = 0
    local maxLen = math.min(M.MAX_MATCH, len - i + 1)
    while candidate and chain < M.MAX_CHAIN and i - candidate <= M.WINDOW do
      if sbyte(data, candidate + bestLen) == sbyte(data, i + bestLen) then
        local l = 0
        while l < maxLen and sbyte(data, candidate + l) == sbyte(data, i + l) do l = l + 1 end
        if l > bestLen then
          bestLen, bestDist = l, i - candidate
          if l >= maxLen then break end
        end
      end
      candidate = prev[candidate]
      chain = chain + 1
    end
    if bestLen < M.MIN_MATCH then return 0, 0 end
    return bestLen, bestDist
  end

  local i = 1
  local count = 0
  while i <= len do
    local mlen, mdist = findMatch(i)
    if mlen >= M.MIN_MATCH and mlen < 32 and i + 1 <= len then       -- lazy: is the next position's match longer?
      insert(i)
      local nlen = findMatch(i + 1)
      if nlen > mlen + 1 then mlen = 0 end
    elseif mlen >= M.MIN_MATCH then
      insert(i)
    end
    if mlen >= M.MIN_MATCH then
      local lc = lengthCode[mlen]
      literalCode(w, 256 + lc)
      if LEXT[lc] > 0 then w.bits(mlen - LBASE[lc], LEXT[lc]) end
      local dc = distCode(mdist)
      w.code(dc - 1, 5)
      if DEXT[dc] > 0 then w.bits(mdist - DBASE[dc], DEXT[dc]) end
      for k = i + 1, i + mlen - 1 do insert(k) end
      i = i + mlen
    else
      if not (head[i + 2 <= len and key(i) or 0] == i) then insert(i) end
      literalCode(w, sbyte(data, i))
      i = i + 1
    end
    count = count + 1
    if count % 4000 == 0 then yield.maybe() end
  end
  literalCode(w, 256)   -- end of block
  local out = w.result()
  if #out > len + 5 * (floor(len / 65535) + 1) then return M.deflate(data, 0) end     -- not worth it: store
  return out
end

--- zlib-compatible CRC-32 (see tsr.hash) and the gzip container around deflate.
local function le32(n) return schar(n % 256, floor(n / 256) % 256, floor(n / 65536) % 256, floor(n / 16777216) % 256) end

--- gzip file bytes for `data` (RFC 1952). opts: name (stored in the header), mtime (seconds), level.
function M.gzip(data, opts)
  opts = opts or {}
  local flags = opts.name and 8 or 0
  local header = "\31\139\8" .. schar(flags) .. le32(opts.mtime or 0) .. "\0\3" .. (opts.name and (opts.name .. "\0") or "")
  return header .. M.deflate(data, opts.level) .. le32(hash.crc32(data)) .. le32(#data % 4294967296)
end

--- Unpack gzip bytes. Returns data, name or nil + reason (the CRC and size are checked).
function M.gunzip(bytes)
  local inflate = require("tsr.inflate")
  if #bytes < 18 or bytes:sub(1, 2) ~= "\31\139" or sbyte(bytes, 3) ~= 8 then return nil, "not a gzip file" end
  local flags = sbyte(bytes, 4)
  local pos = 11
  if flags % 8 >= 4 then
    local xlen = sbyte(bytes, pos) + sbyte(bytes, pos + 1) * 256
    pos = pos + 2 + xlen
  end
  local name
  if floor(flags / 8) % 2 == 1 then
    local z = bytes:find("\0", pos, true)
    if not z then return nil, "damaged gzip header" end
    name = bytes:sub(pos, z - 1)
    pos = z + 1
  end
  if floor(flags / 16) % 2 == 1 then
    local z = bytes:find("\0", pos, true)
    if not z then return nil, "damaged gzip header" end
    pos = z + 1
  end
  if floor(flags / 2) % 2 == 1 then pos = pos + 2 end
  local ok, data, after = pcall(inflate.inflate, bytes, pos)
  if not ok then return nil, tostring(data) end
  local a, b, c, d = sbyte(bytes, after, after + 3)
  local e, f, g, h = sbyte(bytes, after + 4, after + 7)
  if not (a and h) then return nil, "the gzip file is truncated" end
  if a + b * 256 + c * 65536 + d * 16777216 ~= hash.crc32(data) then return nil, "gzip checksum mismatch (the file is damaged)" end
  if e + f * 256 + g * 65536 + h * 16777216 ~= #data % 4294967296 then return nil, "gzip size mismatch" end
  return data, name
end

return M
