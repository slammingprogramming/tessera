-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Key derivation: HKDF-SHA256 (RFC 5869) and PBKDF2-HMAC-SHA256 (RFC 8018), on tsr.hash.
local hash = require("tsr.hash")
local yield = require("tsr.crypto.yield")

local schar, sbyte, srep = string.char, string.byte, string.rep
local floor = math.floor

local M = {}

local function hmac(key, msg) return hash.fromHex(hash.hmacSha256(key, msg)) end

--- HMAC-SHA256 as a 32-byte binary string.
M.hmac = hmac

--- SHA-256 as a 32-byte binary string.
function M.sha256(msg) return hash.fromHex(hash.sha256(msg)) end

--- HKDF-Extract: a pseudo-random key from input keying material (salt may be nil).
function M.extract(salt, ikm)
  if not salt or salt == "" then salt = srep("\0", 32) end
  return hmac(salt, ikm)
end

--- HKDF-Expand: `len` bytes (at most 255 * 32) from a pseudo-random key and context `info`.
function M.expand(prk, info, len)
  assert(len <= 255 * 32, "hkdf output too long")
  local out, t = {}, ""
  local i = 0
  while #table.concat(out) < len do
    i = i + 1
    t = hmac(prk, t .. (info or "") .. schar(i))
    out[#out + 1] = t
  end
  return table.concat(out):sub(1, len)
end

--- HKDF in one call.
function M.hkdf(ikm, salt, info, len)
  return M.expand(M.extract(salt, ikm), info, len)
end

--- PBKDF2-HMAC-SHA256: `len` bytes from a password and salt after `iterations` rounds (yields now and then).
function M.pbkdf2(password, salt, iterations, len)
  local blocks = math.ceil(len / 32)
  local out = {}
  for b = 1, blocks do
    local u = hmac(password, salt .. schar(floor(b / 16777216) % 256, floor(b / 65536) % 256, floor(b / 256) % 256, b % 256))
    local acc = { sbyte(u, 1, 32) }
    for i = 2, iterations do
      u = hmac(password, u)
      for k = 1, 32 do acc[k] = bit32.bxor(acc[k], sbyte(u, k)) end
      if i % 64 == 0 then yield.maybe() end
    end
    out[#out + 1] = schar(table.unpack(acc))
  end
  return table.concat(out):sub(1, len)
end

return M
