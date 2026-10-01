-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Small cryptographic helpers built on SHA-256/HMAC (tsr.hash).
--   * random bytes from a pool that mixes whatever entropy a ComputerCraft computer has (clock, timers, key timings): there
--     is no real random source in the game, so treat keys as "good enough to keep other players out", not as military grade;
--   * an HMAC-SHA256 stream cipher (CTR mode) for optional message encryption;
--   * constant-time comparison.
local hash = require("tsr.hash")

local M = {}

local pool = nil
local counter = 0

local function seed()
  local parts = {
    tostring(os.epoch and os.epoch("utc") or 0), tostring(os.clock()), tostring(os.getComputerID()),
    tostring(os.getComputerLabel() or ""), tostring({}), tostring(math.random()), tostring(os.day and os.day() or 0),
    tostring(os.time()),
  }
  return hash.sha256(table.concat(parts, "|"))
end

--- Mix more entropy into the pool (event timings, user input...).
function M.addEntropy(...)
  pool = pool or seed()
  local parts = { pool, tostring(os.clock()), tostring(os.epoch and os.epoch("utc") or 0) }
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  pool = hash.sha256(table.concat(parts, "|"))
end

--- n random bytes as a string.
function M.random(n)
  pool = pool or seed()
  local out = {}
  local have = 0
  while have < n do
    counter = counter + 1
    pool = hash.sha256(pool .. "|" .. counter .. "|" .. tostring(os.clock()) .. "|" .. tostring(os.epoch and os.epoch("utc") or 0))
    local block = hash.fromHex(hash.sha256("out|" .. pool))
    out[#out + 1] = block
    have = have + #block
  end
  return table.concat(out):sub(1, n)
end

function M.randomHex(n) return hash.toHex(M.random(n)) end

function M.mac(key, text) return hash.hmacSha256(key, text) end

--- Constant-time string comparison.
function M.equal(a, b)
  if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then return false end
  local diff = 0
  for i = 1, #a do diff = bit32.bor(diff, bit32.bxor(a:byte(i), b:byte(i))) end
  return diff == 0
end

--- Keystream of `len` bytes for (key, nonce).
function M.stream(key, nonce, len)
  local out, have, i = {}, 0, 0
  while have < len do
    i = i + 1
    local block = hash.fromHex(hash.hmacSha256(key, tostring(nonce) .. "|" .. i))
    out[#out + 1] = block
    have = have + #block
  end
  return table.concat(out):sub(1, len)
end

local function xor(data, ks)
  local out = {}
  local CH = 4096
  for from = 1, #data, CH do
    local piece = {}
    for i = from, math.min(#data, from + CH - 1) do
      piece[#piece + 1] = string.char(bit32.bxor(data:byte(i), ks:byte(i)))
    end
    out[#out + 1] = table.concat(piece)
  end
  return table.concat(out)
end

--- Encrypt to text (base64). Never reuse a nonce with the same key.
function M.encrypt(key, nonce, plain)
  return hash.base64Encode(xor(plain, M.stream(key, nonce, #plain)))
end

function M.decrypt(key, nonce, cipher64)
  local raw = hash.base64Decode(cipher64)
  if not raw then return nil end
  return xor(raw, M.stream(key, nonce, #raw))
end

--- A pairing code: 10 characters from an alphabet without look-alikes, shown as XXXXX-XXXXX (about 50 bits).
local ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
function M.pairingCode()
  local bytes = M.random(10)
  local chars = {}
  for i = 1, 10 do chars[i] = ALPHABET:sub(bytes:byte(i) % #ALPHABET + 1, bytes:byte(i) % #ALPHABET + 1) end
  local s = table.concat(chars)
  return s:sub(1, 5) .. "-" .. s:sub(6)
end

--- Normalise what a person typed: upper case, no dashes or spaces.
function M.cleanCode(code)
  local clean = tostring(code or ""):upper():gsub("[%s%-]", "")
  return clean
end

return M
