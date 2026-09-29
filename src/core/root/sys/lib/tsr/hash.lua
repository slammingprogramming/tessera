-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Hashing and encoding primitives: SHA-256, CRC-32, Base64, hex. Pure Lua on top of bit32 (present in CC:T).
-- Long inputs yield to the scheduler periodically so CC's "too long without yielding" watchdog never fires.
local band, bxor, bnot, rshift, rrotate = bit32.band, bit32.bxor, bit32.bnot, bit32.rshift, bit32.rrotate
local sbyte, schar, srep, sformat = string.byte, string.char, string.rep, string.format
local floor = math.floor

local M = {}

local function yieldNow()
  os.queueEvent("tsr_yield")
  os.pullEventRaw("tsr_yield")
end

---------------------------------------------------------------------------------------------------------------------
-- SHA-256
---------------------------------------------------------------------------------------------------------------------

-- Constants are the fractional parts of cube/square roots of the first primes (FIPS 180-4), derived once.
local K, H0 = {}, {}
do
  local primes, n = {}, 2
  while #primes < 64 do
    local isPrime = true
    for i = 1, #primes do
      if primes[i] * primes[i] > n then break end
      if n % primes[i] == 0 then isPrime = false break end
    end
    if isPrime then primes[#primes + 1] = n end
    n = n + 1
  end
  for i = 1, 64 do
    local c = primes[i] ^ (1 / 3)
    K[i] = floor((c - floor(c)) * 4294967296)
  end
  for i = 1, 8 do
    local s = primes[i] ^ 0.5
    H0[i] = floor((s - floor(s)) * 4294967296)
  end
end

--- SHA-256 of `msg`, returned as a 64-character lowercase hex string.
function M.sha256(msg)
  local len = #msg
  local h1, h2, h3, h4, h5, h6, h7, h8 = H0[1], H0[2], H0[3], H0[4], H0[5], H0[6], H0[7], H0[8]
  local pad = srep("\0", (55 - len) % 64)
  local bits = len * 8
  msg = msg .. "\128" .. pad .. schar(0, 0, 0, 0,
    floor(bits / 16777216) % 256, floor(bits / 65536) % 256, floor(bits / 256) % 256, bits % 256)
  local w = {}
  local blocks = #msg / 64
  for b = 0, blocks - 1 do
    local base = b * 64
    for i = 0, 15 do
      local a, bb, c, d = sbyte(msg, base + i * 4 + 1, base + i * 4 + 4)
      w[i + 1] = ((a * 256 + bb) * 256 + c) * 256 + d
    end
    for i = 17, 64 do
      local x, y = w[i - 15], w[i - 2]
      local s0 = bxor(rrotate(x, 7), rrotate(x, 18), rshift(x, 3))
      local s1 = bxor(rrotate(y, 17), rrotate(y, 19), rshift(y, 10))
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % 4294967296
    end
    local a, bb, c, d, e, f, g, h = h1, h2, h3, h4, h5, h6, h7, h8
    for i = 1, 64 do
      local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local t1 = (h + S1 + ch + K[i] + w[i]) % 4294967296
      local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
      local maj = bxor(band(a, bb), band(a, c), band(bb, c))
      local t2 = (S0 + maj) % 4294967296
      h, g, f, e, d, c, bb, a = g, f, e, (d + t1) % 4294967296, c, bb, a, (t1 + t2) % 4294967296
    end
    h1, h2, h3, h4 = (h1 + a) % 4294967296, (h2 + bb) % 4294967296, (h3 + c) % 4294967296, (h4 + d) % 4294967296
    h5, h6, h7, h8 = (h5 + e) % 4294967296, (h6 + f) % 4294967296, (h7 + g) % 4294967296, (h8 + h) % 4294967296
    if b % 32 == 31 then yieldNow() end
  end
  return sformat("%08x%08x%08x%08x%08x%08x%08x%08x", h1, h2, h3, h4, h5, h6, h7, h8)
end

---------------------------------------------------------------------------------------------------------------------
-- CRC-32 (IEEE, as used by zip/gzip/PNG)
---------------------------------------------------------------------------------------------------------------------

local crcTable
local function buildCrc()
  crcTable = {}
  for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
      if band(c, 1) == 1 then c = bxor(rshift(c, 1), 0xEDB88320) else c = rshift(c, 1) end
    end
    crcTable[i] = c
  end
end

--- CRC-32 of `s` as an unsigned number. `crc` continues a previous result.
function M.crc32(s, crc)
  if not crcTable then buildCrc() end
  crc = bxor(crc or 0, 0xFFFFFFFF)
  for i = 1, #s do
    crc = bxor(rshift(crc, 8), crcTable[band(bxor(crc, sbyte(s, i)), 0xFF)])
    if i % 16384 == 0 then yieldNow() end
  end
  return bxor(crc, 0xFFFFFFFF)
end

---------------------------------------------------------------------------------------------------------------------
-- Base64 / hex
---------------------------------------------------------------------------------------------------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64enc, b64dec = {}, {}
for i = 1, 64 do
  b64enc[i - 1] = B64:sub(i, i)
  b64dec[sbyte(B64, i)] = i - 1
end

function M.base64Encode(s)
  local out, n = {}, 0
  for i = 1, #s, 3 do
    local a, b, c = sbyte(s, i, i + 2)
    local v = a * 65536 + (b or 0) * 256 + (c or 0)
    n = n + 1
    out[n] = b64enc[floor(v / 262144) % 64] .. b64enc[floor(v / 4096) % 64] ..
      (b and b64enc[floor(v / 64) % 64] or "=") .. (c and b64enc[v % 64] or "=")
    if n % 4096 == 0 then yieldNow() end
  end
  return table.concat(out)
end

--- Decode Base64; whitespace is ignored. Returns nil, err on invalid input.
function M.base64Decode(s)
  s = s:gsub("%s+", "")
  if #s % 4 ~= 0 then return nil, "bad base64 length" end
  local out, n = {}, 0
  for i = 1, #s, 4 do
    local c1, c2, c3, c4 = sbyte(s, i, i + 3)
    local v1, v2 = b64dec[c1], b64dec[c2]
    if not v1 or not v2 then return nil, "bad base64 character" end
    local v3, v4 = b64dec[c3], b64dec[c4]
    if c3 == 61 then v3 = 0 elseif not v3 then return nil, "bad base64 character" end
    if c4 == 61 then v4 = 0 elseif not v4 then return nil, "bad base64 character" end
    local v = ((v1 * 64 + v2) * 64 + v3) * 64 + v4
    local chunk = schar(floor(v / 65536) % 256, floor(v / 256) % 256, v % 256)
    if c3 == 61 then chunk = chunk:sub(1, 1) elseif c4 == 61 then chunk = chunk:sub(1, 2) end
    n = n + 1
    out[n] = chunk
    if n % 4096 == 0 then yieldNow() end
  end
  return table.concat(out)
end

function M.toHex(s)
  return (s:gsub(".", function(c) return sformat("%02x", sbyte(c)) end))
end

function M.fromHex(h)
  return (h:gsub("%x%x", function(x) return schar(tonumber(x, 16)) end))
end

return M
