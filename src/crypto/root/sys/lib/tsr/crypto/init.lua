-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Tessera cryptography: real, standard algorithms in pure Lua, checked against the RFC test vectors.
--   crypto.sha512 / crypto.hash.sha256   hashes             crypto.kdf     HKDF, PBKDF2, HMAC
--   crypto.ed25519                       signatures         crypto.x25519  Diffie-Hellman key agreement
--   crypto.chacha                        ChaCha20-Poly1305  crypto.rand    random bytes (see its notes on entropy)
-- plus small conveniences: key pair creation, constant-time comparison, a sealed-box ("encrypt to a public key") and
-- a "sign a digest" scheme for large documents (tsr.crypto.sign).
local hash = require("tsr.hash")
local sha512 = require("tsr.crypto.sha512")
local ed25519 = require("tsr.crypto.ed25519")
local x25519 = require("tsr.crypto.x25519")
local chacha = require("tsr.crypto.chacha")
local kdf = require("tsr.crypto.kdf")
local rand = require("tsr.crypto.rand")

local M = {
  sha512 = sha512, ed25519 = ed25519, x25519 = x25519, chacha = chacha, kdf = kdf, rand = rand, hash = hash,
}

--- Constant-time comparison of two strings.
function M.equal(a, b)
  if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then return false end
  local diff = 0
  for i = 1, #a do diff = bit32.bor(diff, bit32.bxor(a:byte(i), b:byte(i))) end
  return diff == 0
end

--- A new signing key pair { secret = seed32, public = public32 }.
function M.signingKey(seed)
  seed = seed or rand.bytes(32)
  return { secret = seed, public = ed25519.publicKey(seed) }
end

--- A new key agreement pair { secret, public }.
function M.agreementKey(secret)
  secret = secret or rand.bytes(32)
  return { secret = secret, public = x25519.publicKey(secret) }
end

local sign = require("tsr.crypto.sign")
M.sign = sign

--- Sign arbitrary-length data (see tsr.crypto.sign): `context` separates uses ("registry-index", "file"...).
function M.signData(secret, data, context) return sign.data(secret, data, context) end

function M.verifyData(public, data, signature, context) return sign.verify(public, data, signature, context) end

--- Short human-checkable fingerprint of a public key: SHA256:<base64 without padding> (like OpenSSH).
function M.fingerprint(public)
  return "SHA256:" .. hash.base64Encode(kdf.sha256(public)):gsub("=+$", "")
end

--- Lowercase hex of a binary string, and back.
M.toHex, M.fromHex = hash.toHex, hash.fromHex
M.base64Encode, M.base64Decode = hash.base64Encode, hash.base64Decode

--- "Sealed box": encrypt `plain` so that only the owner of `recipientPublic` (x25519) can read it. A fresh ephemeral key is
--- used for every message, so a leaked sender key reveals nothing. Output: ephemeralPublic(32) .. ciphertext .. tag.
function M.seal(recipientPublic, plain, info)
  local eph = M.agreementKey()
  local shared = assert(x25519.shared(eph.secret, recipientPublic), "invalid recipient key")
  local key = kdf.hkdf(shared, eph.public .. recipientPublic, "tessera-seal-v1" .. (info or ""), 32)
  return eph.public .. chacha.seal(key, string.rep("\0", 12), plain, info or "")
end

function M.open(recipient, sealed, info)
  if #sealed < 48 then return nil end
  local ephPublic = sealed:sub(1, 32)
  local shared = x25519.shared(recipient.secret, ephPublic)
  if not shared then return nil end
  local key = kdf.hkdf(shared, ephPublic .. recipient.public, "tessera-seal-v1" .. (info or ""), 32)
  return chacha.open(key, string.rep("\0", 12), sealed:sub(33), info or "")
end

return M
