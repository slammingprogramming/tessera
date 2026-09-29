-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Raw DEFLATE (RFC 1951) decoder, structured after zlib's "puff". Used to unpack offline bundles that were compressed
-- by tools/build (Node zlib) or by the browser bundle builder (CompressionStream "deflate-raw").
local band, rshift, lshift = bit32.band, bit32.rshift, bit32.lshift
local sbyte, schar = string.byte, string.char
local unpack = table.unpack or unpack

local M = {}

local LBASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEXT = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DBASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
                4097, 6145, 8193, 12289, 16385, 24577 }
local DEXT = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
local ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

local function yieldNow()
  os.queueEvent("tsr_yield")
  os.pullEventRaw("tsr_yield")
end

-- Canonical Huffman table from code lengths lens[0..n-1]
local function construct(lens, n)
  local count, symbol, offs = {}, {}, {}
  for i = 0, 15 do count[i] = 0 end
  for s = 0, n - 1 do count[lens[s]] = count[lens[s]] + 1 end
  offs[1] = 0
  for len = 1, 14 do offs[len + 1] = offs[len] + count[len] end
  for s = 0, n - 1 do
    local l = lens[s]
    if l ~= 0 then
      symbol[offs[l]] = s
      offs[l] = offs[l] + 1
    end
  end
  return { count = count, symbol = symbol }
end

local fixedLit, fixedDist
local function fixedTables()
  if fixedLit then return fixedLit, fixedDist end
  local l = {}
  for s = 0, 143 do l[s] = 8 end
  for s = 144, 255 do l[s] = 9 end
  for s = 256, 279 do l[s] = 7 end
  for s = 280, 287 do l[s] = 8 end
  fixedLit = construct(l, 288)
  local d = {}
  for s = 0, 29 do d[s] = 5 end
  fixedDist = construct(d, 30)
  return fixedLit, fixedDist
end

--- Decompress raw DEFLATE data in `src` starting at byte `start` (default 1).
--- Returns the decompressed string and the position just after the compressed stream. Raises on corrupt input.
function M.inflate(src, start)
  local pos = start or 1
  local bitbuf, bitcnt = 0, 0
  local out, n = {}, 0
  local srcLen = #src

  local function bits(need)
    while bitcnt < need do
      if pos > srcLen then error("inflate: unexpected end of data", 0) end
      bitbuf = bitbuf + lshift(sbyte(src, pos), bitcnt)
      pos = pos + 1
      bitcnt = bitcnt + 8
    end
    local v = band(bitbuf, lshift(1, need) - 1)
    bitbuf = rshift(bitbuf, need)
    bitcnt = bitcnt - need
    return v
  end

  local function decode(h)
    local code, first, index = 0, 0, 0
    local count, symbol = h.count, h.symbol
    for len = 1, 15 do
      code = code + bits(1)
      local c = count[len]
      if code - c < first then return symbol[index + (code - first)] end
      index = index + c
      first = (first + c) * 2
      code = code * 2
    end
    error("inflate: bad huffman code", 0)
  end

  local function codes(lit, dist)
    while true do
      local sym = decode(lit)
      if sym < 256 then
        n = n + 1
        out[n] = sym
      elseif sym == 256 then
        return
      else
        sym = sym - 257
        if sym >= 29 then error("inflate: bad length symbol", 0) end
        local len = LBASE[sym + 1] + bits(LEXT[sym + 1])
        local ds = decode(dist)
        if ds >= 30 then error("inflate: bad distance symbol", 0) end
        local d = DBASE[ds + 1] + bits(DEXT[ds + 1])
        if d > n then error("inflate: distance too far back", 0) end
        for _ = 1, len do
          n = n + 1
          out[n] = out[n - d]
        end
      end
      if n % 32768 == 0 then yieldNow() end
    end
  end

  local function stored()
    bitbuf, bitcnt = 0, 0
    if pos + 3 > srcLen then error("inflate: unexpected end of data", 0) end
    local len = sbyte(src, pos) + sbyte(src, pos + 1) * 256
    local nlen = sbyte(src, pos + 2) + sbyte(src, pos + 3) * 256
    if band(len, 0xFFFF) ~= band(0xFFFF - nlen, 0xFFFF) then error("inflate: stored block length mismatch", 0) end
    pos = pos + 4
    if pos + len - 1 > srcLen then error("inflate: unexpected end of data", 0) end
    for i = pos, pos + len - 1 do
      n = n + 1
      out[n] = sbyte(src, i)
    end
    pos = pos + len
  end

  local function dynamic()
    local nlen = bits(5) + 257
    local ndist = bits(5) + 1
    local ncode = bits(4) + 4
    if nlen > 286 or ndist > 30 then error("inflate: bad counts", 0) end
    local lens = {}
    for i = 0, 18 do lens[i] = 0 end
    for i = 1, ncode do lens[ORDER[i]] = bits(3) end
    local lencode = construct(lens, 19)
    local idx = 0
    local all = {}
    while idx < nlen + ndist do
      local sym = decode(lencode)
      if sym < 16 then
        all[idx] = sym
        idx = idx + 1
      else
        local prev, rep = 0, 0
        if sym == 16 then
          if idx == 0 then error("inflate: no previous length", 0) end
          prev = all[idx - 1]
          rep = 3 + bits(2)
        elseif sym == 17 then
          rep = 3 + bits(3)
        else
          rep = 11 + bits(7)
        end
        if idx + rep > nlen + ndist then error("inflate: too many lengths", 0) end
        for _ = 1, rep do
          all[idx] = prev
          idx = idx + 1
        end
      end
    end
    local ll, dl = {}, {}
    for i = 0, nlen - 1 do ll[i] = all[i] end
    for i = 0, ndist - 1 do dl[i] = all[nlen + i] end
    codes(construct(ll, nlen), construct(dl, ndist))
  end

  repeat
    local last = bits(1)
    local kind = bits(2)
    if kind == 0 then
      stored()
    elseif kind == 1 then
      local l, d = fixedTables()
      codes(l, d)
    elseif kind == 2 then
      dynamic()
    else
      error("inflate: invalid block type", 0)
    end
  until last == 1

  local parts = {}
  for i = 1, n, 4000 do
    parts[#parts + 1] = schar(unpack(out, i, math.min(i + 3999, n)))
  end
  return table.concat(parts), pos
end

return M
