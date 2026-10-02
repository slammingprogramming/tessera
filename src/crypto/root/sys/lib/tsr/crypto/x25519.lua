-- SPDX-License-Identifier: AGPL-3.0-or-later
-- X25519 Diffie-Hellman (RFC 7748) with the Montgomery ladder, on the field of tsr.crypto.fe.
--   x25519.publicKey(secret32)        -> public32     (the base point u = 9)
--   x25519.shared(secret32, public32) -> shared32     (nil for the all-zero result of a low-order point)
local fe = require("tsr.crypto.fe")
local util = require("tsr.crypto.yield")

local sbyte, schar = string.byte, string.char
local floor = math.floor

local M = {}

local A24 = fe.new({ 0xDB41, 1 })   -- (486662 - 2) / 4 = 121665

local function clamp(secret)
  local b = { sbyte(secret, 1, 32) }
  b[1] = b[1] - b[1] % 8
  b[32] = b[32] % 64 + 64
  return b
end

local function ladder(secret, u)
  local z = clamp(secret)
  local x = fe.unpack(u)
  local a, b, c, d = fe.new(), fe.copy(x), fe.new(), fe.new()
  a[1], d[1] = 1, 1
  local e, f = fe.new(), fe.new()
  local swap = 0
  for i = 254, 0, -1 do
    local r = floor(z[floor(i / 8) + 1] / 2 ^ (i % 8)) % 2
    if r ~= swap then a, b = b, a c, d = d, c swap = r end
    fe.add(e, a, c)
    fe.sub(a, a, c)
    fe.add(c, b, d)
    fe.sub(b, b, d)
    fe.sqr(d, e)
    fe.sqr(f, a)
    fe.mul(a, c, a)
    fe.mul(c, b, e)
    fe.add(e, a, c)
    fe.sub(a, a, c)
    fe.sqr(b, a)
    fe.sub(c, d, f)
    fe.mul(a, c, A24)
    fe.add(a, a, d)
    fe.mul(c, c, a)
    fe.mul(a, d, f)
    fe.mul(d, b, x)
    fe.sqr(b, e)
    if i % 16 == 0 then util.maybe() end
  end
  if swap == 1 then a, b = b, a c, d = d, c end
  fe.inv(c, c)
  fe.mul(a, a, c)
  return fe.pack(a)
end

local BASE = schar(9) .. string.rep("\0", 31)

function M.publicKey(secret)
  assert(#secret == 32, "x25519 secret keys are 32 bytes")
  return ladder(secret, BASE)
end

function M.shared(secret, public)
  assert(#secret == 32 and #public == 32, "x25519 keys are 32 bytes")
  local out = ladder(secret, public)
  if out == string.rep("\0", 32) then return nil end
  return out
end

return M
