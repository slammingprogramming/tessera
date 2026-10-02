-- SPDX-License-Identifier: AGPL-3.0-or-later
-- ChaCha20 (RFC 8439), Poly1305 and the combined AEAD, pure Lua on bit32.
--   chacha.xor(key32, nonce12, counter, data)          -> data XOR keystream
--   chacha.poly1305(key32, message)                    -> tag16
--   chacha.seal(key32, nonce12, plaintext, aad)        -> ciphertext .. tag16
--   chacha.open(key32, nonce12, sealed, aad)           -> plaintext, or nil when the tag does not match
-- A (key, nonce) pair must never be used twice. The ChaCha20 core is generated as straight-line code at load time.
local yield = require("tsr.crypto.yield")

local sbyte, schar, srep = string.byte, string.char, string.rep
local floor = math.floor
local bxor = bit32.bxor

local M = {}

---------------------------------------------------------------------------------------------------------------------
-- ChaCha20
---------------------------------------------------------------------------------------------------------------------

local function generateCore()
  local s = { "local band, bxor, bor, lshift, rshift = bit32.band, bit32.bxor, bit32.bor, bit32.lshift, bit32.rshift",
    "local MOD = 4294967296",
    "return function(s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11, s12, s13, s14, s15)",
    "local x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15 = s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11, s12, s13, s14, s15",
    "for _ = 1, 10 do" }
  local function qr(a, b, c, d)
    for _, step in ipairs({ { a, b, d, 16 }, { c, d, b, 12 }, { a, b, d, 8 }, { c, d, b, 7 } }) do
      local p, q, r, n = step[1], step[2], step[3], step[4]
      s[#s + 1] = ("x%d = (x%d + x%d) %% MOD x%d = bxor(x%d, x%d) x%d = bor(lshift(x%d, %d), rshift(x%d, %d)) "):format(p, p, q, r, r, p, r, r, n, r, 32 - n)
    end
  end
  qr(0, 4, 8, 12) qr(1, 5, 9, 13) qr(2, 6, 10, 14) qr(3, 7, 11, 15)
  qr(0, 5, 10, 15) qr(1, 6, 11, 12) qr(2, 7, 8, 13) qr(3, 4, 9, 14)
  s[#s + 1] = "end"
  local out = {}
  for i = 0, 15 do out[#out + 1] = ("(x%d + s%d) %% MOD"):format(i, i) end
  s[#s + 1] = "return " .. table.concat(out, ", ")
  s[#s + 1] = "end"
  local fn, err = load(table.concat(s, "\n"), "=chacha.core", "t", { bit32 = bit32 })
  if not fn then error(err) end
  return fn()
end

local core = generateCore()

local function word(s, i)   -- little-endian 32-bit word starting at byte i
  local a, b, c, d = sbyte(s, i, i + 3)
  return a + b * 256 + c * 65536 + d * 16777216
end

local function wordBytes(w)
  return schar(w % 256, floor(w / 256) % 256, floor(w / 65536) % 256, floor(w / 16777216))
end

--- XOR `data` with the ChaCha20 keystream for (key, nonce) starting at block `counter`.
function M.xor(key, nonce, counter, data)
  assert(#key == 32 and #nonce == 12, "chacha20 needs a 32-byte key and a 12-byte nonce")
  local k = {}
  for i = 0, 7 do k[i + 1] = word(key, i * 4 + 1) end
  local n1, n2, n3 = word(nonce, 1), word(nonce, 5), word(nonce, 9)
  local out = {}
  for pos = 1, #data, 64 do
    local blk = { core(0x61707865, 0x3320646e, 0x79622d32, 0x6b206574, k[1], k[2], k[3], k[4], k[5], k[6], k[7], k[8],
      counter % 4294967296, n1, n2, n3) }
    counter = counter + 1
    local len = math.min(64, #data - pos + 1)
    local ks = {}
    for i = 1, 16 do ks[i] = wordBytes(blk[i]) end
    ks = table.concat(ks)
    local piece = {}
    for i = 1, len do piece[i] = schar(bxor(sbyte(data, pos + i - 1), sbyte(ks, i))) end
    out[#out + 1] = table.concat(piece)
    if (pos - 1) % 4096 == 0 then yield.maybe() end
  end
  return table.concat(out)
end

---------------------------------------------------------------------------------------------------------------------
-- Poly1305 with 13-bit limbs (the multiplication stays far below 2^53)
---------------------------------------------------------------------------------------------------------------------

local function limbs(str)   -- little-endian bytes -> up to 11 limbs of 13 bits (index 0-based)
  local out, acc, nb, idx = {}, 0, 0, 0
  for i = 1, #str do
    acc = acc + sbyte(str, i) * 2 ^ nb
    nb = nb + 8
    while nb >= 13 do
      out[idx] = acc % 8192
      acc = floor(acc / 8192)
      nb = nb - 13
      idx = idx + 1
    end
  end
  out[idx] = acc
  return out
end

--- 16-byte Poly1305 authenticator of `msg` under the 32-byte one-time key.
function M.poly1305(key, msg)
  assert(#key == 32, "poly1305 needs a 32-byte key")
  local rb = { sbyte(key, 1, 16) }
  for _, i in ipairs({ 4, 8, 12, 16 }) do rb[i] = rb[i] % 16 end
  for _, i in ipairs({ 5, 9, 13 }) do rb[i] = rb[i] - rb[i] % 4 end
  local r = limbs(schar(table.unpack(rb)))
  for i = 0, 9 do r[i] = r[i] or 0 end
  local h = {}
  for i = 0, 9 do h[i] = 0 end
  for pos = 1, #msg, 16 do
    local m = limbs(msg:sub(pos, pos + 15) .. "\1")
    for i = 0, 9 do h[i] = h[i] + (m[i] or 0) end
    local t = {}
    for k = 0, 18 do t[k] = 0 end
    for i = 0, 9 do
      local hi = h[i]
      for j = 0, 9 do t[i + j] = t[i + j] + hi * r[j] end
    end
    for k = 18, 10, -1 do t[k - 10] = t[k - 10] + 5 * t[k] end
    local c = 0
    for i = 0, 9 do
      local v = t[i] + c
      c = floor(v / 8192)
      h[i] = v - c * 8192
    end
    h[0] = h[0] + 5 * c
    c = floor(h[0] / 8192)
    h[0] = h[0] - c * 8192
    h[1] = h[1] + c
  end
  -- full carry, then conditionally subtract p = 2^130 - 5
  local c = 0
  for _ = 1, 3 do
    c = 0
    for i = 0, 9 do
      local v = h[i] + c
      c = floor(v / 8192)
      h[i] = v - c * 8192
    end
    h[0] = h[0] + 5 * c
  end
  c = 0
  for i = 0, 9 do
    local v = h[i] + c
    c = floor(v / 8192)
    h[i] = v - c * 8192
  end
  local g = {}
  c = 5
  for i = 0, 9 do
    local v = h[i] + c
    c = floor(v / 8192)
    g[i] = v - c * 8192
  end
  if c >= 1 then for i = 0, 9 do h[i] = g[i] end end    -- h >= p: h - p = (h + 5) mod 2^130
  -- to 16 bytes (the low 128 bits), then add s modulo 2^128
  local bytes, acc, nb = {}, 0, 0
  for i = 0, 9 do
    acc = acc + h[i] * 2 ^ nb
    nb = nb + 13
    while nb >= 8 and #bytes < 16 do
      bytes[#bytes + 1] = acc % 256
      acc = floor(acc / 256)
      nb = nb - 8
    end
  end
  local out, carry = {}, 0
  for i = 1, 16 do
    local v = bytes[i] + sbyte(key, 16 + i) + carry
    out[i] = v % 256
    carry = floor(v / 256)
  end
  return schar(table.unpack(out))
end

---------------------------------------------------------------------------------------------------------------------
-- AEAD (RFC 8439 section 2.8)
---------------------------------------------------------------------------------------------------------------------

local function pad16(s) return srep("\0", (16 - #s % 16) % 16) end

local function le64(n)
  local b = {}
  for i = 1, 8 do b[i] = n % 256 n = floor(n / 256) end
  return schar(table.unpack(b))
end

local function macData(aad, ct)
  return aad .. pad16(aad) .. ct .. pad16(ct) .. le64(#aad) .. le64(#ct)
end

local function equal(a, b)
  if #a ~= #b then return false end
  local diff = 0
  for i = 1, #a do diff = bit32.bor(diff, bxor(sbyte(a, i), sbyte(b, i))) end
  return diff == 0
end

function M.seal(key, nonce, plain, aad)
  aad = aad or ""
  local otk = M.xor(key, nonce, 0, srep("\0", 32))
  local ct = M.xor(key, nonce, 1, plain)
  return ct .. M.poly1305(otk, macData(aad, ct))
end

function M.open(key, nonce, sealed, aad)
  aad = aad or ""
  if #sealed < 16 then return nil end
  local ct, tag = sealed:sub(1, -17), sealed:sub(-16)
  local otk = M.xor(key, nonce, 0, srep("\0", 32))
  if not equal(M.poly1305(otk, macData(aad, ct)), tag) then return nil end
  return M.xor(key, nonce, 1, ct)
end

return M
