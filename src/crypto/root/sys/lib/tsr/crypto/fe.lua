-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Arithmetic in the field GF(2^255 - 19), the base of X25519 and Ed25519.
-- An element is a table of 16 limbs of 16 bits (little endian, 1-based), the representation used by TweetNaCl: every
-- product of two limbs fits in a double (53 bits) so plain Lua numbers are exact. Limbs may be a little unnormalised
-- between operations; `pack` produces the canonical 32 bytes.
-- The hot function `mul` is generated as unrolled straight-line code at load time: no table indexing in the inner loops
-- makes it several times faster than the obvious double loop on the CC:T VM.
local floor = math.floor
local sbyte, schar = string.byte, string.char

local M = {}

M.D = { 0x78a3, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070, 0xe898, 0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f, 0x6cee, 0x5203 }
M.D2 = { 0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0, 0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406 }
M.BX = { 0xd51a, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c, 0xdc5c, 0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e, 0x36d3, 0x2169 }
M.BY = { 0x6658, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666 }
M.SQRTM1 = { 0xa0b0, 0x4a0e, 0x1b27, 0xc4ee, 0xe478, 0xad2f, 0x1806, 0x2f43, 0xd7a7, 0x3dfb, 0x0099, 0x2b4d, 0xdf0b, 0x4fc1, 0x2480, 0x2b83 }

function M.new(v)
  local o = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
  if v then for i = 1, 16 do o[i] = v[i] or 0 end end
  return o
end

function M.copy(a)
  return { a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15], a[16] }
end

M.ZERO = M.new()
M.ONE = M.new({ 1 })

--- Propagate carries so every limb is in [0, 65535] (limb 16 wraps around with the factor 38 = 2^256 mod p).
function M.car(o)
  for i = 1, 16 do
    local x = o[i] + 65536
    local c = floor(x / 65536)
    if i < 16 then o[i + 1] = o[i + 1] + c - 1 else o[1] = o[1] + 38 * (c - 1) end
    o[i] = x - c * 65536
  end
end

function M.add(o, a, b)
  for i = 1, 16 do o[i] = a[i] + b[i] end
end

function M.sub(o, a, b)
  for i = 1, 16 do o[i] = a[i] - b[i] end
end

local function generateMul()
  local s = { "local floor = math.floor", "return function(o, a, b)" }
  for i = 0, 15 do s[#s + 1] = ("local a%d, b%d = a[%d], b[%d]"):format(i, i, i + 1, i + 1) end
  for k = 0, 30 do
    local terms = {}
    for i = math.max(0, k - 15), math.min(15, k) do terms[#terms + 1] = ("a%d*b%d"):format(i, k - i) end
    s[#s + 1] = ("local t%d = %s"):format(k, table.concat(terms, " + "))
  end
  for i = 0, 14 do s[#s + 1] = ("t%d = t%d + 38 * t%d"):format(i, i, i + 16) end
  s[#s + 1] = "local c, x"
  for _ = 1, 2 do
    for i = 0, 15 do
      s[#s + 1] = ("x = t%d + 65536 c = floor(x / 65536)"):format(i)
      if i < 15 then s[#s + 1] = ("t%d = t%d + c - 1 t%d = x - c * 65536"):format(i + 1, i + 1, i)
      else s[#s + 1] = "t0 = t0 + 38 * (c - 1) t15 = x - c * 65536" end
    end
  end
  for i = 0, 15 do s[#s + 1] = ("o[%d] = t%d"):format(i + 1, i) end
  s[#s + 1] = "end"
  local fn, err = load(table.concat(s, "\n"), "=fe.mul", "t", { math = math })
  if not fn then error(err) end
  return fn()
end

--- o = a * b (o may be a or b).
M.mul = generateMul()

--- o = a * a.
function M.sqr(o, a) M.mul(o, a, a) end

--- o = a^-1 (Fermat: a^(p-2)).
function M.inv(o, a)
  local c = M.copy(a)
  for i = 253, 0, -1 do
    M.mul(c, c, c)
    if i ~= 2 and i ~= 4 then M.mul(c, c, a) end
  end
  for i = 1, 16 do o[i] = c[i] end
end

--- o = a^((p-5)/8) = a^(2^252 - 3), used for square roots.
function M.pow2523(o, a)
  local c = M.copy(a)
  for i = 250, 0, -1 do
    M.mul(c, c, c)
    if i ~= 1 then M.mul(c, c, a) end
  end
  for i = 1, 16 do o[i] = c[i] end
end

--- Canonical 32-byte little-endian string of the (fully reduced) element.
function M.pack(n)
  local t = M.copy(n)
  M.car(t) M.car(t) M.car(t)
  local m = {}
  for _ = 1, 2 do
    m[1] = t[1] - 0xffed
    for i = 2, 15 do
      m[i] = t[i] - 0xffff - (m[i - 1] < 0 and 1 or 0)
      m[i - 1] = m[i - 1] % 65536
    end
    m[16] = t[16] - 0x7fff - (m[15] < 0 and 1 or 0)
    local borrow = m[16] < 0
    m[15] = m[15] % 65536
    if not borrow then for i = 1, 16 do t[i] = m[i] end end   -- t >= p: use t - p
  end
  local out = {}
  for i = 1, 16 do out[2 * i - 1] = t[i] % 256 out[2 * i] = floor(t[i] / 256) end
  return schar(table.unpack(out))
end

--- 32-byte string (top bit ignored) to an element.
function M.unpack(s)
  local o = {}
  for i = 1, 16 do o[i] = sbyte(s, 2 * i - 1) + sbyte(s, 2 * i) * 256 end
  o[16] = o[16] % 32768
  return o
end

--- Parity (lowest bit) of the canonical value.
function M.parity(a)
  return sbyte(M.pack(a), 1) % 2
end

--- Are a and b different field elements?
function M.neq(a, b)
  return M.pack(a) ~= M.pack(b)
end

return M
