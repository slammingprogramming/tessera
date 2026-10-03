-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Certificates and a certificate authority for the in-game network: a certificate says "this public key belongs to this name, from this day to that day"
-- and carries a signature (Ed25519) of whoever vouches for it. A player (or a whole server) can run a CA: its public certificate goes into the trust
-- store of every computer that should believe it, and from then on every certificate it signs is believed. Without a CA a server certificate can still
-- be pinned the first time it is seen (like SSH host keys). Wildcard names ("*.lan") cover one label.
--
-- Text form (one value per line, easy to copy into a chat or a book):
--   TESSERA CERTIFICATE 1
--   subject: mail.lan            names: smtp.lan, pop.lan            (names is optional)
--   key: <base64 public key>
--   from: <UTC ms>   until: <UTC ms>
--   issuer: Lab CA               issuerKey: <base64 public key of the issuer>   ca: true|false
--   serial: <hex>
--   signature: <base64>
local crypto = require("tsr.crypto")

local M = {}

M.CONTEXT = "tls-cert"
M.DAY = 86400000

local function now() return os.epoch and os.epoch("utc") or 0 end

local function body(c)
  local lines = { "TESSERA CERTIFICATE 1", "subject: " .. c.subject }
  if c.names and #c.names > 0 then lines[#lines + 1] = "names: " .. table.concat(c.names, ", ") end
  lines[#lines + 1] = "key: " .. crypto.base64Encode(c.key)
  lines[#lines + 1] = ("from: %.0f"):format(c.from)
  lines[#lines + 1] = ("until: %.0f"):format(c.until_)
  lines[#lines + 1] = "issuer: " .. c.issuer
  lines[#lines + 1] = "issuerKey: " .. crypto.base64Encode(c.issuerKey)
  lines[#lines + 1] = "ca: " .. (c.ca and "true" or "false")
  lines[#lines + 1] = "serial: " .. c.serial
  return table.concat(lines, "\n") .. "\n"
end

--- Issue a certificate. opts: subject, names (more names it is valid for), key (the public key to certify), issuerName, issuerKey (signing key pair of the issuer),
--- days (valid for, default 365), ca (may sign other certificates).
function M.issue(opts)
  local c = {
    subject = opts.subject:lower(), names = opts.names, key = opts.key, from = opts.from or now(), until_ = (opts.from or now()) + (opts.days or 365) * M.DAY,
    issuer = opts.issuerName, issuerKey = opts.issuerKey.public, ca = opts.ca or false, serial = crypto.toHex(crypto.rand.bytes(8)),
  }
  c.signature = crypto.signData(opts.issuerKey.secret, body(c), M.CONTEXT)
  return c
end

--- A self-signed certificate for a key pair (used by servers without a CA, and for the CA's own certificate).
function M.selfSigned(subject, keypair, opts)
  opts = opts or {}
  return M.issue({ subject = subject, names = opts.names, key = keypair.public, issuerName = subject, issuerKey = keypair, days = opts.days or 3650, ca = opts.ca, from = opts.from })
end

function M.encode(c)
  return body(c) .. "signature: " .. crypto.base64Encode(c.signature) .. "\n"
end

function M.decode(text)
  if type(text) ~= "string" or not text:find("^TESSERA CERTIFICATE 1") then return nil, "not a Tessera certificate" end
  local f = {}
  for k, v in text:gmatch("([%w]+): ([^\n]*)") do f[k] = v end
  local c = { subject = f.subject, key = f.key and crypto.base64Decode(f.key), from = tonumber(f.from), until_ = tonumber(f["until"]), issuer = f.issuer,
    issuerKey = f.issuerKey and crypto.base64Decode(f.issuerKey), ca = f.ca == "true", serial = f.serial, signature = f.signature and crypto.base64Decode(f.signature) }
  if f.names then
    c.names = {}
    for n in f.names:gmatch("[^,%s]+") do c.names[#c.names + 1] = n:lower() end
  end
  if not (c.subject and c.key and #c.key == 32 and c.from and c.until_ and c.issuer and c.issuerKey and #c.issuerKey == 32 and c.signature and #c.signature == 64 and c.serial) then
    return nil, "damaged certificate"
  end
  return c
end

--- Does the signature verify against the key the certificate names as issuer's?
function M.signatureOk(c)
  return crypto.verifyData(c.issuerKey, body(c), c.signature, M.CONTEXT)
end

function M.fingerprint(c) return crypto.fingerprint(c.key) end

--- Is `host` one of the names of the certificate (exact, or a wildcard for one label)?
function M.matches(c, host)
  host = tostring(host or ""):lower()
  local function one(pattern)
    if pattern == host then return true end
    if pattern:sub(1, 2) == "*." then
      local rest = host:match("^[^%.]+%.(.+)$")
      return rest == pattern:sub(3)
    end
    return false
  end
  if one(c.subject) then return true end
  for _, n in ipairs(c.names or {}) do if one(n) then return true end end
  return false
end

function M.expired(c, at)
  at = at or now()
  return at < c.from or at > c.until_
end

--- Is the certificate self-signed (its issuer key is its own key)?
function M.isSelfSigned(c) return c.issuerKey == c.key end

M.body = body
return M
