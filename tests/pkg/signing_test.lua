-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Signed registries: the signature module, trust policy and state, source verification, bundle import and key updates.
local sig = require("tsr.pkg.sig")
local trust = require("tsr.pkg.trust")
local source = require("tsr.pkg.source")
local config = require("tsr.config")
local crypto = require("tsr.crypto")
local hash = require("tsr.hash")
local vfs = require("tsr.vfs")
local fx = dofile("/tests/fixtures/crypto_vectors.lua")

local REG = "/tmp-sreg"

local seedA = crypto.fromHex(fx.ed25519[4].seed)
local seedB = crypto.fromHex(fx.ed25519[5].seed)
local keyA, keyB = crypto.signingKey(seedA), crypto.signingKey(seedB)

local function reset()
  for _, p in ipairs({ REG, "/tmp-sstate" }) do if fs.exists(p) then fs.delete(p) end end
  trust.trustPath = "/tmp-sstate/trust.json"
  trust.statePath = "/tmp-sstate/state.json"
  source.cacheDir = "/tmp-sstate/cache"
  source.offlineDir = "/tmp-sstate/cache/offline"
  config.reset()
  config.set("pkg.sources", { { name = "test", type = "dir", path = REG } }, "user")
end

local function trustA() trust.add("key A", crypto.toHex(keyA.public)) end

--- A signed registry directory with packages app (needs lib) and lib. opts: key (default A), serial, expires, unsigned, dir.
local function publish(opts)
  opts = opts or {}
  local dir = opts.dir or REG
  local key = opts.key or keyA
  local index = { format = 1, serial = opts.serial or 100, expires = opts.expires, packages = {} }
  local docs = {}
  for _, name in ipairs({ "app", "lib" }) do
    local content = "return '" .. name .. "'"
    local sha = hash.sha256(content)
    vfs.writeFile(dir .. "/blobs/" .. sha, content, true)
    local doc = textutils.serializeJSON({ name = name, latest = "1.0.0", versions = { ["1.0.0"] = {
      name = name, version = "1.0.0", type = "lib", requires = name == "app" and { lib = "*" } or {},
      files = { { path = "/tmp-sx/" .. name .. ".lua", sha256 = sha, size = #content } } } } })
    docs[name] = doc
    vfs.writeFile(dir .. "/registry/packages/" .. name .. ".json", doc)
    index.packages[name] = { version = "1.0.0", type = "lib", description = name, docSha256 = hash.sha256(doc) }
  end
  local indexText = textutils.serializeJSON(index)
  vfs.writeFile(dir .. "/registry/index.json", indexText)
  local sigText
  if not opts.unsigned then
    sigText = sig.makeSignature(key.secret, key.public, indexText)
    vfs.writeFile(dir .. "/registry/index.json.sig", sigText)
  end
  return { index = indexText, sig = sigText, docs = docs, dir = dir }
end

test("a registry signature made by the Node build tooling verifies in Lua (and not for another purpose)", function()
  local r = fx.registry
  local keys = sig.parseKeys({ { name = "build", public = r.public } }, "test")
  eq(next(keys), r.keyid)
  local key = sig.verify(r.text, r.sig, keys)
  eq(key.name, "build")
  eq(sig.keyId(crypto.fromHex(r.public)), r.keyid)
  local k, why = sig.verify(r.text .. " ", r.sig, keys)
  ok(k == nil and why:find("does not match", 1, true), why)
  k, why = sig.verify(r.text, r.trustSig, keys)              -- made for another context
  ok(k == nil, "a trust-update signature must not pass as an index signature")
  ok(sig.verify(r.text, r.trustSig, keys, sig.TRUST_CONTEXT))
end)

test("signature files and key lists are parsed strictly", function()
  ok(not sig.parseSignature("not json"))
  ok(not sig.parseSignature('{"alg":"rsa","keyid":"x","sig":"AAAA"}'))
  ok(not sig.parseSignature('{"alg":"ed25519","keyid":"x","sig":"AAAA"}'), "short signature")
  eq(next(sig.parseKeys({ { name = "x", public = "zz" }, { public = string.rep("ab", 31) } })), nil)
  eq(next(sig.parseKeys("not json")), nil)
end)

test("policy: off without keys, require with a key, config can override", function()
  reset()
  eq(trust.policy(), "off")
  trustA()
  eq(trust.policy(), "require")
  config.set("pkg.signatures", "warn", "user")
  eq(trust.policy(), "warn")
  config.set("pkg.signatures", "bogus", "user")
  eq(trust.policy(), "require")
end)

test("a signed index from a trusted key is accepted, and the state remembers it", function()
  reset() trustA()
  local r = publish()
  local ok1, status = trust.verifyIndex("s", r.index, r.sig)
  ok(ok1, status)
  eq(status, "verified")
  local info = trust.sourceInfo("s")
  eq(info.key, "key A")
  eq(info.serial, 100)
  -- the second check is answered from the state (same bytes)
  ok(trust.verifyIndex("s", r.index, r.sig))
end)

test("unsigned, tampered and foreign-signed indexes are refused when signatures are required", function()
  reset() trustA()
  local r = publish()
  local good, why = trust.verifyIndex("s", r.index, nil)
  ok(good == nil and why:find("not signed", 1, true), why)
  good, why = trust.verifyIndex("s", r.index .. " ", r.sig)
  ok(good == nil and why:find("does not match", 1, true), why)
  local other = publish({ key = keyB, dir = "/tmp-sreg2" })
  good, why = trust.verifyIndex("s", other.index, other.sig)
  ok(good == nil and why:find("unknown or revoked", 1, true), why)
  fs.delete("/tmp-sreg2")
end)

test("warn mode lets problems through with a note, off checks nothing", function()
  reset() trustA()
  local r = publish({ unsigned = true })
  config.set("pkg.signatures", "warn", "user")
  local good, status = trust.verifyIndex("s", r.index, nil)
  ok(good and status == "unsigned")
  config.set("pkg.signatures", "off", "user")
  good, status = trust.verifyIndex("s", r.index, "garbage")
  ok(good and status == "unchecked")
end)

test("rollback to an older serial is refused, an expired index only warns", function()
  reset() trustA()
  local newer = publish({ serial = 500 })
  ok(trust.verifyIndex("s", newer.index, newer.sig))
  local older = publish({ serial = 400 })
  local good, why = trust.verifyIndex("s", older.index, older.sig)
  ok(good == nil and why:find("rollback", 1, true), why)
  ok(trust.verifyIndex("other-source", older.index, older.sig), "state is per source")
  local old = publish({ serial = 900, expires = 1000 })
  local ok2, status = trust.verifyIndex("s", old.index, old.sig)
  ok(ok2)
  eq(status, "expired")
end)

test("sources hand out verified indexes and package descriptions only", function()
  reset() trustA()
  publish()
  local src = { name = "test", type = "dir", path = REG }
  local idx, status = source.getIndex(src, true)
  ok(idx, status)
  ok(source.getPackage(src, "app"))
  -- a tampered description is refused
  local f = REG .. "/registry/packages/lib.json"
  vfs.writeFile(f, vfs.readFile(f):gsub('"1.0.0"', '"6.6.6"', 1))
  local doc, why = source.getPackage(src, "lib")
  ok(doc == nil and why:find("signed index", 1, true), tostring(why))
  local found, ferr = source.findPackage("lib")
  ok(found == nil and tostring(ferr):find("signed index", 1, true), tostring(ferr))
  -- an unsigned registry is refused outright
  reset() trustA()
  publish({ unsigned = true })
  local idx2, why2 = source.getIndex({ name = "test", type = "dir", path = REG }, true)
  ok(idx2 == nil and why2:find("not signed", 1, true), tostring(why2))
end)

test("importing a bundle: signed accepted, unsigned or altered refused, older refused", function()
  reset() trustA()
  local r = publish()
  local function bundleFrom(reg, tweak)
    local b = { index = textutils.unserializeJSON(reg.index), indexRaw = reg.index, indexSig = reg.sig, packages = {}, packageRaw = {}, blobs = {} }
    for name, raw in pairs(reg.docs) do b.packages[name] = textutils.unserializeJSON(raw) b.packageRaw[name] = raw end
    for _, f in ipairs(fs.list(reg.dir .. "/blobs")) do b.blobs[f] = vfs.readFile(reg.dir .. "/blobs/" .. f, true) end
    if tweak then tweak(b) end
    return b
  end
  local res, err = source.importBundle(bundleFrom(r))
  ok(res, err)
  eq(res.packages, 2)
  ok(fs.exists(source.offlineDir .. "/registry/index.json.sig"))
  local bad = bundleFrom(r, function(b) b.packageRaw.app = b.packageRaw.app .. " " end)
  res, err = source.importBundle(bad)
  ok(res == nil and err:find("signed index", 1, true), tostring(err))
  bad = bundleFrom(r, function(b) b.indexSig = nil end)
  res, err = source.importBundle(bad)
  ok(res == nil and err:find("not signed", 1, true), tostring(err))
  local older = publish({ serial = 5, dir = "/tmp-sreg2" })
  res, err = source.importBundle(bundleFrom(older))
  ok(res == nil, "an older bundle must not replace newer data")
  fs.delete("/tmp-sreg2")
  -- the imported offline store is itself a verified source
  local idx = source.getIndex({ name = "offline", type = "dir", path = source.offlineDir }, true)
  ok(idx and idx.packages.app)
end)

test("trust list: add, revoke (also a built-in style key), re-add", function()
  reset()
  local id = trust.add("key A", crypto.toHex(keyA.public))
  eq(id, sig.keyId(keyA.public))
  eq(#trust.list(), 1)
  ok(not trust.add("bad", "1234"))
  trust.revoke(id)
  eq(#trust.list(), 0)
  eq(trust.policy(), "off")
  trust.add("key A again", crypto.toHex(keyA.public))
  eq(#trust.list(), 1)
end)

test("signed trust updates add keys and revoke keys, once, and only from trusted signers", function()
  reset() trustA()
  local update = textutils.serializeJSON({ format = 1, serial = 2, keys = { { name = "key B", public = crypto.toHex(keyB.public) } }, revoked = {} })
  local signature = sig.makeSignature(keyA.secret, keyA.public, update, sig.TRUST_CONTEXT)
  local res, err = trust.applyUpdate(update, signature)
  ok(res, err)
  eq(res.added, 1)
  eq(#trust.list(), 2)
  local again, aerr = trust.applyUpdate(update, signature)
  ok(again == nil and aerr:find("not newer", 1, true), tostring(aerr))
  -- signed by an unknown key
  reset() trustA()
  local forged = sig.makeSignature(keyB.secret, keyB.public, update, sig.TRUST_CONTEXT)
  local r2, e2 = trust.applyUpdate(update, forged)
  ok(r2 == nil and e2:find("unknown or revoked", 1, true), tostring(e2))
  -- an index signature is not a trust-update signature
  local wrongContext = sig.makeSignature(keyA.secret, keyA.public, update, sig.CONTEXT)
  ok(trust.applyUpdate(update, wrongContext) == nil)
  -- B can now sign, A can be revoked by B's update
  trust.applyUpdate(update, signature)
  local revokeUpdate = textutils.serializeJSON({ format = 1, serial = 3, keys = {}, revoked = { sig.keyId(keyA.public) } })
  local r3 = trust.applyUpdate(revokeUpdate, sig.makeSignature(keyB.secret, keyB.public, revokeUpdate, sig.TRUST_CONTEXT))
  ok(r3 and r3.revoked == 1)
  local keys = trust.keys()
  ok(keys[sig.keyId(keyA.public)] == nil and keys[sig.keyId(keyB.public)] ~= nil)
end)
