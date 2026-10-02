-- SPDX-License-Identifier: AGPL-3.0-or-later
-- PGP-style public key cryptography for ComputerCraft: key pairs with an identity, signing and verification, encryption to several
-- recipients or with a passphrase, key certification (web of trust) and revocation.
--
-- HONEST NOTE: this follows the ideas of OpenPGP (identity-bound keys, self-signatures, certifications, session keys, armored
-- text) with modern primitives (Ed25519 signatures, X25519 key agreement, ChaCha20-Poly1305, HKDF, PBKDF2), but it is its own
-- compact format: it cannot talk to GnuPG and it is not meant to. The primitives are the real, standard ones and are
-- checked against test vectors; see tsr.crypto.
--
-- A key (table):  { packet, created, expires, signPub, encPub, uid, fp (32 bytes), fp20, selfSig, certs, revoked, secret }
--   fingerprint  = SHA-256 of the key packet; shown as 10 groups of 4 hex digits (the first 20 bytes). Key id = its last 16 hex digits.
local crypto = require("tsr.crypto")
local armor = require("tsr.pgp.armor")
local hash = require("tsr.hash")

local T = armor.TYPE
local u8, u16, u32, u64 = armor.u8, armor.u16, armor.u32, armor.u64

local M = {}

M.CHUNK = 4096
M.KDF_ITERATIONS = 2000

local ZERO12 = string.rep("\0", 12)

local function now() return math.floor((os.epoch and os.epoch("utc") or 0) / 1000) end
M.now = now

---------------------------------------------------------------------------------------------------------------------
-- Keys
---------------------------------------------------------------------------------------------------------------------

local function packetOf(created, expires, signPub, encPub, uid)
  return u8(1) .. u64(created) .. u64(expires or 0) .. signPub .. encPub .. u16(#uid) .. uid
end

--- Decode a key packet (type 1 record data) into a key table (without secrets or signatures).
function M.parsePacket(packet)
  local ok, key = pcall(function()
    local r = armor.reader(packet)
    if r:u8() ~= 1 then error("unsupported key version", 0) end
    local created, expires = r:u64(), r:u64()
    local signPub, encPub = r:bytes(32), r:bytes(32)
    local uid = r:bytes(r:u16())
    if not r:eof() then error("trailing data in key packet", 0) end
    return { packet = packet, created = created, expires = expires, signPub = signPub, encPub = encPub, uid = uid, certs = {} }
  end)
  if not ok then return nil, tostring(key) end
  key.fp = crypto.kdf.sha256(packet)
  key.fp20 = key.fp:sub(1, 20)
  return key
end

--- The fingerprint as "ABCD EF01 ..." (40 hex digits in groups of four, upper case).
function M.fingerprint(key)
  local hex = crypto.toHex(key.fp20):upper()
  return (hex:gsub("(%x%x%x%x)", "%1 "):gsub(" $", ""))
end

--- Short key id (the last 16 hex digits of the fingerprint).
function M.keyId(key) return crypto.toHex(key.fp20):upper():sub(-16) end

local function fpHex(key) return crypto.toHex(key.fp20) end
M.fpHex = fpHex

--- Create a key pair for identity `uid` ("Name <note>"). opts: expires (seconds from now), created (default now).
function M.generate(uid, opts)
  opts = opts or {}
  local created = opts.created or now()
  local sign, agree = crypto.signingKey(), crypto.agreementKey()
  local expires = opts.expires and (created + opts.expires) or 0
  local key = M.parsePacket(packetOf(created, expires, sign.public, agree.public, uid))
  key.selfSig = crypto.sign.data(sign.secret, key.packet, "pgp-self")
  key.secret = { sign = sign.secret, enc = agree.secret }
  key.revoked = false
  return key
end

--- Is the key's self-signature valid (the identity really belongs to the key)?
function M.selfSigned(key)
  return key.selfSig ~= nil and crypto.sign.verify(key.signPub, key.packet, key.selfSig, "pgp-self")
end

function M.expired(key, at)
  return key.expires ~= nil and key.expires ~= 0 and (at or now()) > key.expires
end

--- Revoke a key (needs its secret): marks it and keeps a signed revocation certificate. reason: 0 unspecified, 1 compromised, 2 retired.
function M.revoke(key, reason)
  assert(key.secret, "revoking needs the secret key")
  local created = now()
  local statement = key.fp .. u8(reason or 0) .. u64(created)
  key.revocation = { reason = reason or 0, created = created, sig = crypto.sign.data(key.secret.sign, statement, "pgp-revoke") }
  key.revoked = true
  return key.revocation
end

local function revocationValid(key, rev)
  return crypto.sign.verify(key.signPub, key.fp .. u8(rev.reason) .. u64(rev.created), rev.sig, "pgp-revoke")
end

--- Certify (vouch for) another key: signer says "this identity belongs to this key". level 1 = checked casually, 2 = checked carefully.
function M.certify(signer, target, level)
  assert(signer.secret, "certifying needs your secret key")
  local created = now()
  local statement = target.fp .. signer.fp20 .. u64(created) .. u8(level or 1)
  local cert = { signer = signer.fp20, created = created, level = level or 1, sig = crypto.sign.data(signer.secret.sign, statement, "pgp-cert") }
  target.certs[#target.certs + 1] = cert
  return cert
end

--- Is `cert` on `target` genuinely made by `signer` (a key table)?
function M.certValid(target, cert, signer)
  if signer.fp20 ~= cert.signer then return false end
  return crypto.sign.verify(signer.signPub, target.fp .. cert.signer .. u64(cert.created) .. u8(cert.level), cert.sig, "pgp-cert")
end

---------------------------------------------------------------------------------------------------------------------
-- Key blocks (public and secret), armored
---------------------------------------------------------------------------------------------------------------------

local function publicRecords(key)
  local list = { { T.KEY, key.packet }, { T.SELFSIG, key.selfSig } }
  for _, c in ipairs(key.certs) do list[#list + 1] = { T.CERT, c.signer .. u64(c.created) .. u8(c.level) .. c.sig } end
  if key.revoked and key.revocation then
    list[#list + 1] = { T.REVOKE, u8(key.revocation.reason) .. u64(key.revocation.created) .. key.revocation.sig }
  end
  return list
end

--- Armored public key block (identity, self-signature, certifications, revocation).
function M.exportPublic(key) return armor.armor("PUBLIC KEY", armor.records(publicRecords(key))) end

--- Armored secret key block. A non-empty passphrase seals the secret part.
function M.exportSecret(key, passphrase)
  assert(key.secret, "no secret key")
  local plain = key.secret.sign .. key.secret.enc
  local rec
  if passphrase and passphrase ~= "" then
    local salt = crypto.rand.bytes(16)
    local k = crypto.kdf.pbkdf2(passphrase, salt, M.KDF_ITERATIONS, 32)
    rec = u8(1) .. salt .. u32(M.KDF_ITERATIONS) .. crypto.chacha.seal(k, ZERO12, plain, key.fp)
  else
    rec = u8(0) .. plain
  end
  local list = publicRecords(key)
  list[#list + 1] = { T.SECRET, rec }
  return armor.armor("SECRET KEY", armor.records(list))
end

--- Parse a key block (public or secret). Returns key (secret is nil until unlocked: see `unlock`) or nil + reason.
--- The key's self-signature and every revocation are checked; certifications are kept and verified by whoever has the signer's key.
function M.parseBlock(bin)
  local recs, err = armor.parse(bin)
  if not recs then return nil, err end
  local key
  for _, rec in ipairs(recs) do
    local t, data = rec[1], rec[2]
    if t == T.KEY then
      local k, perr = M.parsePacket(data)
      if not k then return nil, perr end
      key = k
      key.revoked = false
    elseif not key then return nil, "the key packet must come first"
    elseif t == T.SELFSIG then
      if #data ~= 64 then return nil, "malformed self-signature" end
      key.selfSig = data
    elseif t == T.CERT then
      if #data ~= 20 + 8 + 1 + 64 then return nil, "malformed certification" end
      local r = armor.reader(data)
      key.certs[#key.certs + 1] = { signer = r:bytes(20), created = r:u64(), level = r:u8(), sig = r:bytes(64) }
    elseif t == T.REVOKE then
      local r = armor.reader(data)
      local rev = { reason = r:u8(), created = r:u64(), sig = r:bytes(64) }
      if revocationValid(key, rev) then key.revoked, key.revocation = true, rev end
    elseif t == T.SECRET then
      key.sealedSecret = data
    end
  end
  if not key then return nil, "no key in this block" end
  if not M.selfSigned(key) then return nil, "the key's self-signature is invalid: the identity or keys were altered" end
  return key
end

--- Parse armored text.
function M.importText(text)
  local kind, bin = armor.dearmor(text)
  if kind ~= "PUBLIC KEY" and kind ~= "SECRET KEY" then return nil, kind and ("not a key block (" .. kind .. ")") or bin end
  return M.parseBlock(bin)
end

--- Does this key (from a SECRET KEY block) have a secret part, and does it need a passphrase?
function M.needsPassphrase(key)
  return key.sealedSecret ~= nil and key.sealedSecret:byte(1) == 1
end

--- Unlock the secret part of a parsed key. Returns true or nil + "passphrase" (needed or wrong) / reason.
function M.unlock(key, passphrase)
  local data = key.sealedSecret
  if not data then return nil, "this key has no secret part" end
  local plain
  if data:byte(1) == 0 then
    plain = data:sub(2)
  else
    if not passphrase then return nil, "passphrase" end
    local r = armor.reader(data:sub(2))
    local salt, iter = r:bytes(16), r:u32()
    local k = crypto.kdf.pbkdf2(passphrase, salt, iter, 32)
    plain = crypto.chacha.open(k, ZERO12, r:rest(), key.fp)
    if not plain then return nil, "passphrase" end
  end
  if #plain ~= 64 then return nil, "damaged secret key" end
  local secret = { sign = plain:sub(1, 32), enc = plain:sub(33, 64) }
  if crypto.ed25519.publicKey(secret.sign) ~= key.signPub or crypto.x25519.publicKey(secret.enc) ~= key.encPub then return nil, "damaged secret key" end
  key.secret = secret
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- Signatures
---------------------------------------------------------------------------------------------------------------------

--- Canonical text form for text signatures: LF line ends, no trailing blanks.
local function canonicalText(text)
  local lines = {}
  for line in (text:gsub("\r\n", "\n") .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = (line:gsub("[ \t]+$", "")) end
  if lines[#lines] == "" then lines[#lines] = nil end
  return table.concat(lines, "\n")
end
M.canonicalText = canonicalText

local function sigStatement(kind, created, digest, fp20)
  return u8(kind) .. u64(created) .. digest .. fp20
end

--- Sign data. opts: text (sign the canonical text form). Returns the signature as a binary blob (one SIGNATURE record).
function M.sign(data, key, opts)
  assert(key.secret, "signing needs your secret key")
  local kind = (opts and opts.text) and 1 or 0
  if kind == 1 then data = canonicalText(data) end
  local created = now()
  local digest = crypto.kdf.sha256(data)
  local sig = crypto.sign.data(key.secret.sign, sigStatement(kind, created, digest, key.fp20), "pgp-sig")
  return armor.records({ { T.SIGNATURE, u8(1) .. key.fp20 .. u64(created) .. u8(kind) .. digest .. sig } })
end

--- Decode a signature blob. Returns { signer (fp20), created, kind, digest, sig } or nil + reason.
function M.parseSignature(bin)
  local recs, err = armor.parse(bin)
  if not recs or not recs[1] or recs[1][1] ~= T.SIGNATURE then return nil, err or "not a signature" end
  local ok, sig = pcall(function()
    local r = armor.reader(recs[1][2])
    if r:u8() ~= 1 then error("unsupported signature version", 0) end
    return { signer = r:bytes(20), created = r:u64(), kind = r:u8(), digest = r:bytes(32), sig = r:bytes(64) }
  end)
  if not ok then return nil, tostring(sig) end
  return sig
end

--- Check a signature against `data` and the signer's public key. Returns true, or false + reason.
function M.verify(data, sigInfo, key)
  if sigInfo.signer ~= key.fp20 then return false, "signed by a different key" end
  if sigInfo.kind == 1 then data = canonicalText(data) end
  if crypto.kdf.sha256(data) ~= sigInfo.digest then return false, "the data does not match the signature" end
  if not crypto.sign.verify(key.signPub, sigStatement(sigInfo.kind, sigInfo.created, sigInfo.digest, key.fp20), sigInfo.sig, "pgp-sig") then
    return false, "bad signature"
  end
  return true
end

--- Armored detached signature.
function M.armorSignature(bin) return armor.armor("SIGNATURE", bin) end

--- Clear-signed text: the readable message plus an armored signature of its canonical form.
function M.clearsign(text, key)
  local sig = M.sign(text, key, { text = true })
  local escaped = {}
  for line in (canonicalText(text) .. "\n"):gmatch("([^\n]*)\n") do   -- dash escaping: lines starting with '-' get "- " in front
    escaped[#escaped + 1] = line:sub(1, 1) == "-" and ("- " .. line) or line
  end
  return "-----BEGIN TESSERA SIGNED MESSAGE-----\n\n" .. table.concat(escaped, "\n") .. "\n" .. M.armorSignature(sig)
end

--- Split a clear-signed message into its text and signature info. Returns text, sigInfo or nil + reason.
function M.parseClearsigned(text)
  local body, rest = text:match("^%-%-%-%-%-BEGIN TESSERA SIGNED MESSAGE%-%-%-%-%-\r?\n\r?\n(.-)\n(%-%-%-%-%-BEGIN TESSERA SIGNATURE%-%-%-%-%-.*)$")
  if not body then return nil, "not a clear-signed message" end
  local kind, bin = armor.dearmor(rest, "SIGNATURE")
  if not kind then return nil, bin end
  local info, err = M.parseSignature(bin)
  if not info then return nil, err end
  local lines = {}
  for line in (body .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line:sub(1, 2) == "- " and line:sub(3) or line end
  return table.concat(lines, "\n"), info
end

---------------------------------------------------------------------------------------------------------------------
-- Encryption
---------------------------------------------------------------------------------------------------------------------

local function wrapKey(keyMaterial, fileKey, info)
  return crypto.chacha.seal(keyMaterial, ZERO12, fileKey, info)
end

local function chunkNonce(i) return "\0\0\0\0" .. u64(i) end

--- Encrypt `plain` to `recipients` (list of key tables) and/or a passphrase. opts: signer (secret key table), passphrase.
--- Returns the message as a binary blob.
function M.encrypt(plain, recipients, opts)
  opts = opts or {}
  recipients = recipients or {}
  assert(#recipients > 0 or opts.passphrase, "need a recipient or a passphrase")
  local fileKey = crypto.rand.bytes(32)
  local list = { { T.HEADER, u8(1) .. u8(opts.signer and 1 or 0) .. u16(M.CHUNK) } }
  for _, rec in ipairs(recipients) do
    if rec.revoked then error("the key " .. M.keyId(rec) .. " is revoked", 0) end
    if M.expired(rec) then error("the key " .. M.keyId(rec) .. " has expired", 0) end
    local eph = crypto.agreementKey()
    local shared = assert(crypto.x25519.shared(eph.secret, rec.encPub), "invalid recipient key")
    local wrapKeyMaterial = crypto.kdf.hkdf(shared, eph.public .. rec.encPub, "tessera-pgp-wrap", 32)
    list[#list + 1] = { T.PKESK, eph.public .. rec.fp20:sub(1, 8) .. wrapKey(wrapKeyMaterial, fileKey, "pkesk") }
  end
  if opts.passphrase then
    local salt = crypto.rand.bytes(16)
    local k = crypto.kdf.pbkdf2(opts.passphrase, salt, M.KDF_ITERATIONS, 32)
    list[#list + 1] = { T.SKESK, salt .. u32(M.KDF_ITERATIONS) .. wrapKey(k, fileKey, "skesk") }
  end
  local body = plain
  if opts.signer then
    local sig = M.sign(plain, opts.signer)
    body = u32(#sig) .. sig .. plain
  end
  local chunks = math.max(1, math.ceil(#body / M.CHUNK))
  for i = 1, chunks do
    local piece = body:sub((i - 1) * M.CHUNK + 1, i * M.CHUNK)
    local final = i == chunks
    list[#list + 1] = { T.DATA, crypto.chacha.seal(fileKey, chunkNonce(i), piece, (final and "F" or "M") .. u64(i)) }
  end
  return armor.records(list)
end

--- Decrypt a message blob. `keys` is a list of key tables with unlocked secrets; opts.passphrase is tried for passphrase-encrypted
--- messages. Returns plaintext, info ({ signature = sigInfo|nil, recipient = key|nil }) or nil + reason.
function M.decrypt(bin, keys, opts)
  opts = opts or {}
  local recs, err = armor.parse(bin)
  if not recs then return nil, err end
  if not recs[1] or recs[1][1] ~= T.HEADER then return nil, "not an encrypted message" end
  local r = armor.reader(recs[1][2])
  local version, flags, chunkSize = r:u8(), r:u8(), r:u16()
  if version ~= 1 then return nil, "unsupported message version" end
  local fileKey, used
  for i = 2, #recs do
    local t, data = recs[i][1], recs[i][2]
    if t == T.PKESK and not fileKey then
      local eph, hint, wrapped = data:sub(1, 32), data:sub(33, 40), data:sub(41)
      for _, key in ipairs(keys or {}) do
        if key.secret and key.fp20:sub(1, 8) == hint then
          local shared = crypto.x25519.shared(key.secret.enc, eph)
          if shared then
            local m = crypto.kdf.hkdf(shared, eph .. key.encPub, "tessera-pgp-wrap", 32)
            local k = crypto.chacha.open(m, ZERO12, wrapped, "pkesk")
            if k then fileKey, used = k, key break end
          end
        end
      end
    elseif t == T.SKESK and not fileKey and opts.passphrase then
      local rr = armor.reader(data)
      local salt, iter = rr:bytes(16), rr:u32()
      local k = crypto.kdf.pbkdf2(opts.passphrase, salt, iter, 32)
      local fk = crypto.chacha.open(k, ZERO12, rr:rest(), "skesk")
      if fk then fileKey = fk end
    end
  end
  if not fileKey then return nil, "no secret key or passphrase here can open this message" end
  local parts, index, last = {}, 0, nil
  for i = 2, #recs do
    if recs[i][1] == T.DATA then
      index = index + 1
      last = i
    end
  end
  if index == 0 then return nil, "the message has no data" end
  local n = 0
  for i = 2, #recs do
    if recs[i][1] == T.DATA then
      n = n + 1
      local piece = crypto.chacha.open(fileKey, chunkNonce(n), recs[i][2], (n == index and "F" or "M") .. u64(n))
      if not piece then return nil, "the message is damaged or truncated" end
      parts[n] = piece
    end
  end
  local body = table.concat(parts)
  local info = { recipient = used }
  if flags % 2 == 1 then
    local rr = armor.reader(body)
    local len = rr:u32()
    local sigBin = rr:bytes(len)
    local plain = rr:rest()
    info.signature = M.parseSignature(sigBin)
    info.signedData = plain
    return plain, info
  end
  return plain or body, info
end

function M.armorMessage(bin) return armor.armor("MESSAGE", bin) end

---------------------------------------------------------------------------------------------------------------------
-- Web of trust
---------------------------------------------------------------------------------------------------------------------

--- Which keys can be considered valid, given a list of keys, owner trust levels ({ [fpHex] = "ultimate"|"full"|"marginal"|"none" })
--- and the keys the user owns? A key is valid when it is ultimately trusted (your own), certified by one valid key of full trust,
--- or certified by `marginals` (default 3) valid keys of marginal trust; validity spreads up to `depth` (default 5) steps.
--- Returns { [fpHex] = { valid = bool, reason = string } }.
function M.validity(keys, ownerTrust, opts)
  opts = opts or {}
  local marginals, depth = opts.marginals or 3, opts.depth or 5
  local byFp, state = {}, {}
  for _, k in ipairs(keys) do byFp[k.fp20] = k end
  for _, k in ipairs(keys) do
    local hex = fpHex(k)
    if (ownerTrust[hex] == "ultimate") then state[hex] = { valid = true, reason = "your own key (ultimate trust)", level = 0 } else state[hex] = { valid = false, reason = "no valid certification path" } end
  end
  for level = 1, depth do
    local changed = false
    for _, k in ipairs(keys) do
      local hex = fpHex(k)
      if not state[hex].valid and not k.revoked then
        local full, marginal = 0, 0
        local viaFull
        for _, cert in ipairs(k.certs) do
          local signer = byFp[cert.signer]
          if signer and signer ~= k and M.certValid(k, cert, signer) and not signer.revoked then
            local sv = state[fpHex(signer)]
            if sv.valid and sv.level < level then
              local trust = ownerTrust[fpHex(signer)]
              if trust == "full" or trust == "ultimate" then full = full + 1 viaFull = signer
              elseif trust == "marginal" then marginal = marginal + 1 end
            end
          end
        end
        if full >= 1 then
          state[hex] = { valid = true, level = level, reason = "certified by trusted key " .. M.keyId(viaFull) }
          changed = true
        elseif marginal >= marginals then
          state[hex] = { valid = true, level = level, reason = ("certified by %d marginally trusted keys"):format(marginal) }
          changed = true
        end
      end
    end
    if not changed then break end
  end
  for _, k in ipairs(keys) do
    if k.revoked then state[fpHex(k)] = { valid = false, reason = "REVOKED" } end
  end
  return state
end

return M
