-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Wi-Fi keys, in the manner of WPA2-Personal: the passphrase and the network name make a Pairwise Master Key (PBKDF2), the handshake mixes in two random
-- numbers and both addresses to make a Pairwise Transient Key that nobody can compute without the passphrase, and every data frame is sealed
-- (ChaCha20-Poly1305) with a packet number that must increase, which stops replays.
--   PMK = PBKDF2-HMAC-SHA256(passphrase, ssid, iterations)           (the iteration count is lower than WPA2's 4096: this runs in Lua)
--   PTK = HKDF(PMK, "tessera-wpa" .. sorted MACs .. ANonce .. SNonce, 64)  -> KCK (16, for MICs) | KEK (16, unused) | TK (32, for data)
local crypto = require("tsr.crypto")
local B = require("tsr.inet.bytes")

local M = {}

M.ITERATIONS = 256

local pmkCache = {}

function M.pmk(passphrase, ssid, iterations)
  iterations = iterations or M.ITERATIONS
  local k = ssid .. "\0" .. iterations .. "\0" .. passphrase
  local c = pmkCache[k]
  if c then return c end
  c = crypto.kdf.pbkdf2(passphrase, ssid, iterations, 32)
  pmkCache[k] = c
  return c
end

function M.ptk(pmk, apMac, staMac, anonce, snonce)
  local lo, hi = apMac, staMac
  if hi < lo then lo, hi = hi, lo end
  local material = crypto.kdf.hkdf(pmk, "tessera-wpa", lo .. hi .. anonce .. snonce, 64)
  return { kck = material:sub(1, 16), kek = material:sub(17, 32), tk = material:sub(33, 64) }
end

--- A message integrity code over the handshake message (with the MIC field left out).
function M.mic(kck, data) return crypto.kdf.hmac(kck, data):sub(1, 16) end

function M.nonce() return crypto.rand.bytes(32) end

local function nonceFor(pn, direction) return string.char(direction, 0, 0, 0) .. B.u32(math.floor(pn / 4294967296)) .. B.u32(pn % 4294967296) end

--- Seal an Ethernet frame for the air. `direction`: 0 station->AP, 1 AP->station. aad = the 19 header bytes.
function M.seal(tk, pn, direction, plain, aad)
  return B.u32(math.floor(pn / 4294967296)) .. B.u32(pn % 4294967296) .. crypto.chacha.seal(tk, nonceFor(pn, direction), plain, aad)
end

--- Returns the frame and its packet number, or nil.
function M.open(tk, direction, body, aad)
  if #body < 8 + 16 then return nil end
  local pn = B.rd32(body, 1) * 4294967296 + B.rd32(body, 5)
  local plain = crypto.chacha.open(tk, nonceFor(pn, direction), body:sub(9), aad)
  if not plain then return nil end
  return plain, pn
end

return M
