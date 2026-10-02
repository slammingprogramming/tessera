-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The cryptographic core of the in-game secure shell: handshake transcript, key derivation, signatures and the record layer.
--
--   client                                   server
--   hello  { sid, ce }              ->                       ce = client ephemeral X25519 public key
--                                   <-  reply { sid, se, hostkey, sig }
--          shared = X25519(ce, se)         sig = Ed25519(host key, SHA-256(transcript))   (transcript binds sid, both ids, ce, se, hostkey)
--          keys   = HKDF-SHA256(shared, salt = transcript hash)  ->  one ChaCha20-Poly1305 key per direction
--   then every message is an authenticated, encrypted record with a counter (replays and reordering are rejected).
-- Forward secrecy: the ephemeral keys exist only for the session, so a later theft of a host or user key does not reveal old
-- sessions. The client decides whether it trusts the host key (known_hosts); the server decides whether it trusts the user
-- (authorized_keys or password) inside the encrypted channel. This resembles SSH and the Noise framework's NK pattern, but it
-- is its own small protocol for ComputerCraft networks (not wire compatible with real SSH, and it never leaves the game).
local crypto = require("tsr.crypto")

local floor = math.floor
local schar = string.char

local M = {}

M.VERSION = 1
M.CLIENT_TO_SERVER, M.SERVER_TO_CLIENT = 0, 1
M.HOST_CONTEXT, M.USER_CONTEXT = "ssh-host", "ssh-user"

local function field(s) return #s .. ":" .. s end

--- SHA-256 over everything both sides must agree on (32 bytes).
function M.transcript(sid, clientId, serverId, ce, se, hostPublic)
  return crypto.kdf.sha256(table.concat({
    "tessera-ssh-v1", field(sid), field(tostring(clientId)), field(tostring(serverId)), field(ce), field(se), field(hostPublic),
  }))
end

--- The two directional keys: clientToServer, serverToClient.
function M.deriveKeys(shared, transcriptHash)
  local okm = crypto.kdf.hkdf(shared, transcriptHash, "tessera-ssh-v1 keys", 64)
  return okm:sub(1, 32), okm:sub(33, 64)
end

function M.hostSign(hostSecret, h) return crypto.sign.data(hostSecret, h, M.HOST_CONTEXT) end
function M.hostVerify(hostPublic, h, sig) return crypto.sign.verify(hostPublic, h, sig, M.HOST_CONTEXT) end

--- Proof that the client owns a user key for this very session: a signature over the transcript and the user name.
function M.userSign(userSecret, h, user) return crypto.sign.data(userSecret, h .. user, M.USER_CONTEXT) end
function M.userVerify(userPublic, h, user, sig) return crypto.sign.verify(userPublic, h .. user, sig, M.USER_CONTEXT) end

local function nonce(direction, n)
  local b = {}
  for i = 8, 1, -1 do b[i] = n % 256 n = floor(n / 256) end
  return schar(direction, 0, 0, 0) .. schar(table.unpack(b))
end

--- Encrypt a message body (a table) as record number `n` in `direction`. Returns base64 text.
function M.seal(key, direction, sid, n, body)
  return crypto.base64Encode(crypto.chacha.seal(key, nonce(direction, n), textutils.serialize(body), sid))
end

--- Decrypt and parse a record. Returns the body table, or nil when it does not authenticate.
function M.open(key, direction, sid, n, text)
  if type(text) ~= "string" or type(n) ~= "number" then return nil end
  local raw = crypto.base64Decode(text)
  if not raw then return nil end
  local plain = crypto.chacha.open(key, nonce(direction, n), raw, sid)
  if not plain then return nil end
  local body = textutils.unserialize(plain)
  if type(body) ~= "table" then return nil end
  return body
end

return M
