-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Ed25519 signatures (RFC 8032, pure Ed25519) on the field of tsr.crypto.fe; the point arithmetic follows TweetNaCl.
--   ed25519.publicKey(seed32)             -> public32
--   ed25519.sign(seed32, message)         -> signature64
--   ed25519.verify(public32, message, signature64) -> boolean
-- Verification uses one interleaved double-scalar multiplication ([S]B + [h](-A)), about half the work of two separate ones.
-- Timing side channels are not a concern on a game computer and are not defended against.
local fe = require("tsr.crypto.fe")
local sha512 = require("tsr.crypto.sha512")
local yield = require("tsr.crypto.yield")

local sbyte, schar, srep = string.byte, string.char, string.rep
local floor = math.floor

local M = {}

local L = { [0] = 0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10 }

---------------------------------------------------------------------------------------------------------------------
-- Scalars modulo the group order L (arrays of numbers, 0-based, as in TweetNaCl)
---------------------------------------------------------------------------------------------------------------------

local function modL(x)
  for i = 63, 32, -1 do
    local carry = 0
    local j = i - 32
    while j < i - 12 do
      x[j] = x[j] + carry - 16 * x[i] * L[j - (i - 32)]
      carry = floor((x[j] + 128) / 256)
      x[j] = x[j] - carry * 256
      j = j + 1
    end
    x[j] = x[j] + carry
    x[i] = 0
  end
  local carry = 0
  for j = 0, 31 do
    x[j] = x[j] + carry - floor(x[31] / 16) * L[j]
    carry = floor(x[j] / 256)
    x[j] = x[j] % 256
  end
  for j = 0, 31 do x[j] = x[j] - carry * L[j] end
  local out = {}
  for i = 0, 31 do
    x[i + 1] = (x[i + 1] or 0) + floor(x[i] / 256)
    out[i + 1] = x[i] % 256
  end
  return schar(table.unpack(out))
end

--- Reduce a 64-byte little-endian string modulo L to 32 bytes.
local function reduce64(s)
  local x = {}
  for i = 0, 63 do x[i] = sbyte(s, i + 1) end
  return modL(x)
end

--- Is the 32-byte little-endian number below L? (signatures with S >= L are malleable and rejected)
local function belowL(s)
  for i = 31, 0, -1 do
    local b = sbyte(s, i + 1)
    if b ~= L[i] then return b < L[i] end
  end
  return false
end

---------------------------------------------------------------------------------------------------------------------
-- Points in extended coordinates {X, Y, Z, T}
---------------------------------------------------------------------------------------------------------------------

local function newPoint(x, y, z, t) return { x or fe.new(), y or fe.new({ 1 }), z or fe.new({ 1 }), t or fe.new() } end

local function pointAdd(p, q)
  local a, b, c, d, t, e, f, g, h = fe.new(), fe.new(), fe.new(), fe.new(), fe.new(), fe.new(), fe.new(), fe.new(), fe.new()
  fe.sub(a, p[2], p[1])
  fe.sub(t, q[2], q[1])
  fe.mul(a, a, t)
  fe.add(b, p[2], p[1])
  fe.add(t, q[2], q[1])
  fe.mul(b, b, t)
  fe.mul(c, p[4], q[4])
  fe.mul(c, c, fe.D2)
  fe.mul(d, p[3], q[3])
  fe.add(d, d, d)
  fe.sub(e, b, a)
  fe.sub(f, d, c)
  fe.add(g, d, c)
  fe.add(h, b, a)
  local r = { fe.new(), fe.new(), fe.new(), fe.new() }
  fe.mul(r[1], e, f)
  fe.mul(r[2], h, g)
  fe.mul(r[3], g, f)
  fe.mul(r[4], e, h)
  return r
end

local function pack(p)
  local zi, tx, ty = fe.new(), fe.new(), fe.new()
  fe.inv(zi, p[3])
  fe.mul(tx, p[1], zi)
  fe.mul(ty, p[2], zi)
  local s = fe.pack(ty)
  local b32 = sbyte(s, 32)
  if fe.parity(tx) == 1 then b32 = b32 + 128 end
  return s:sub(1, 31) .. schar(b32)
end

local function basePoint()
  local x, y = fe.new(fe.BX), fe.new(fe.BY)
  local t = fe.new()
  fe.mul(t, x, y)
  return { x, y, fe.new({ 1 }), t }
end

--- Decode a point and negate it (TweetNaCl's unpackneg); nil if it is not on the curve.
local function unpackNeg(s)
  local r = { fe.new(), fe.new(), fe.new({ 1 }), fe.new() }
  local t, chk, num, den, den2, den4, den6 = fe.new(), fe.new(), fe.new(), fe.new(), fe.new(), fe.new(), fe.new()
  r[2] = fe.unpack(s)
  fe.sqr(num, r[2])
  fe.mul(den, num, fe.D)
  fe.sub(num, num, r[3])
  fe.add(den, r[3], den)
  fe.sqr(den2, den)
  fe.sqr(den4, den2)
  fe.mul(den6, den4, den2)
  fe.mul(t, den6, num)
  fe.mul(t, t, den)
  fe.pow2523(t, t)
  fe.mul(t, t, num)
  fe.mul(t, t, den)
  fe.mul(t, t, den)
  fe.mul(r[1], t, den)
  fe.sqr(chk, r[1])
  fe.mul(chk, chk, den)
  if fe.neq(chk, num) then fe.mul(r[1], r[1], fe.SQRTM1) end
  fe.sqr(chk, r[1])
  fe.mul(chk, chk, den)
  if fe.neq(chk, num) then return nil end
  if fe.parity(r[1]) == floor(sbyte(s, 32) / 128) then fe.sub(r[1], fe.ZERO, r[1]) end
  fe.mul(r[4], r[1], r[2])
  return r
end

local function bitOf(s, i)       -- bit i (0 = least significant) of a little-endian byte string
  return floor(sbyte(s, floor(i / 8) + 1) / 2 ^ (i % 8)) % 2
end

local B_POINT = nil

--- scalar * B for a 32-byte little-endian scalar.
local function scalarBase(s)
  B_POINT = B_POINT or basePoint()
  local q = newPoint()
  for i = 255, 0, -1 do
    q = pointAdd(q, q)
    if bitOf(s, i) == 1 then q = pointAdd(q, B_POINT) end
    if i % 8 == 0 then yield.maybe() end
  end
  return q
end

---------------------------------------------------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------------------------------------------------

local function expand(seed)
  local h = sha512.digest(seed)
  local a = { sbyte(h, 1, 32) }
  a[1] = a[1] - a[1] % 8
  a[32] = a[32] % 64 + 64
  return schar(table.unpack(a)), h:sub(33, 64)
end

function M.publicKey(seed)
  assert(#seed == 32, "ed25519 seeds are 32 bytes")
  local a = expand(seed)
  return pack(scalarBase(a))
end

function M.sign(seed, msg)
  assert(#seed == 32, "ed25519 seeds are 32 bytes")
  local a, prefix = expand(seed)
  local pub = pack(scalarBase(a))
  local r = reduce64(sha512.digest(prefix .. msg))
  local R = pack(scalarBase(r))
  local k = reduce64(sha512.digest(R .. pub .. msg))
  -- S = (r + k*a) mod L
  local x = {}
  for i = 0, 63 do x[i] = 0 end
  for i = 0, 31 do x[i] = sbyte(r, i + 1) end
  for i = 0, 31 do
    local ki = sbyte(k, i + 1)
    for j = 0, 31 do x[i + j] = x[i + j] + ki * sbyte(a, j + 1) end
  end
  return R .. modL(x)
end

function M.verify(pub, msg, sig)
  if type(pub) ~= "string" or #pub ~= 32 or type(sig) ~= "string" or #sig ~= 64 then return false end
  local R, S = sig:sub(1, 32), sig:sub(33, 64)
  if not belowL(S) then return false end
  local negA = unpackNeg(pub)
  if not negA then return false end
  local h = reduce64(sha512.digest(R .. pub .. msg))
  B_POINT = B_POINT or basePoint()
  local table3 = { B_POINT, negA, pointAdd(B_POINT, negA) }
  local q = newPoint()
  for i = 255, 0, -1 do
    q = pointAdd(q, q)
    local idx = bitOf(S, i) + 2 * bitOf(h, i)
    if idx > 0 then q = pointAdd(q, table3[idx]) end
    if i % 8 == 0 then yield.maybe() end
  end
  return pack(q) == R
end

return M
