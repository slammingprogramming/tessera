-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Signed registries, the pure part (no files, no configuration; the bootstrap installer uses this module too).
--
-- Trust chain:   trusted public key  ->  signature file  ->  registry/index.json (raw bytes)
--                index entry "docSha256"  ->  registry/packages/<name>.json (raw bytes)
--                package manifest file hashes  ->  every payload
-- so one Ed25519 verification (plus SHA-256 checks) vouches for everything that is installed.
--
-- A signature file is JSON:  { "format": 1, "alg": "ed25519", "keyid": "<16 hex>", "sig": "<base64 of 64 bytes>" }.
-- The key id is the first 8 bytes of SHA-256(public key) in hex. Keys are listed as { "name": "...", "public": "<64 hex>" }.
local sign = require("tsr.crypto.sign")
local kdf = require("tsr.crypto.kdf")
local hash = require("tsr.hash")

local M = {}

M.CONTEXT = "registry-index"
M.TRUST_CONTEXT = "registry-trust"

--- The id of a 32-byte public key.
function M.keyId(public)
  return hash.toHex(kdf.sha256(public)):sub(1, 16)
end

--- Keys from a JSON string or a list: returns { [keyid] = { id, name, public (32 bytes), source } }.
function M.parseKeys(list, source)
  if type(list) == "string" then list = textutils.unserializeJSON(list) end
  local out = {}
  if type(list) ~= "table" then return out end
  for _, k in ipairs(list) do
    local public = type(k) == "table" and type(k.public) == "string" and k.public:match("^%x+$") and #k.public == 64 and hash.fromHex(k.public)
    if public then
      local id = M.keyId(public)
      out[id] = { id = id, name = k.name or id, public = public, source = source }
    end
  end
  return out
end

--- Decode a signature file. Returns { keyid, sig } or nil + reason.
function M.parseSignature(raw)
  local doc = type(raw) == "string" and textutils.unserializeJSON(raw)
  if type(doc) ~= "table" or doc.alg ~= "ed25519" or type(doc.keyid) ~= "string" or type(doc.sig) ~= "string" then
    return nil, "unreadable signature file"
  end
  local sig = hash.base64Decode(doc.sig)
  if not sig or #sig ~= 64 then return nil, "malformed signature" end
  return { keyid = doc.keyid, sig = sig }
end

--- Verify `raw` against signature file text `sigRaw` using `keys` (table from parseKeys). Returns the key entry that signed, or nil + reason.
function M.verify(raw, sigRaw, keys, context)
  local s, err = M.parseSignature(sigRaw)
  if not s then return nil, err end
  local key = keys[s.keyid]
  if not key then return nil, "signed by an unknown or revoked key (" .. s.keyid .. ")" end
  if not sign.verify(key.public, raw, s.sig, context or M.CONTEXT) then return nil, "signature does not match (" .. key.name .. ")" end
  return key
end

--- Build the text of a signature file (used by tests and in-game tools; the build tooling does this in Node).
function M.makeSignature(secret, public, raw, context)
  local s = sign.data(secret, raw, context or M.CONTEXT)
  return textutils.serializeJSON({ format = 1, alg = "ed25519", keyid = M.keyId(public), sig = hash.base64Encode(s) })
end

--- Does the package description text `raw` match the hash the signed index recorded for it?
function M.checkDoc(raw, entry)
  if type(entry) ~= "table" or type(entry.docSha256) ~= "string" then return nil, "the signed index has no hash for this package" end
  if hash.sha256(raw) ~= entry.docSha256 then return nil, "package description does not match the signed index" end
  return true
end

return M
