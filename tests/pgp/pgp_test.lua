-- SPDX-License-Identifier: AGPL-3.0-or-later
local pgp = require("tsr.pgp")
local armor = require("tsr.pgp.armor")
local ring = require("tsr.pgp.ring")
local cli = require("tsr.pgp.cli")
local keyserver = require("tsr.pgp.keyserver")
local net = require("tsr.net")
local crypto = require("tsr.crypto")
local vfs = require("tsr.vfs")
local netbus = dofile("/tests/lib/netbus.lua")

local DIR = "/tmp-pgp"

local function reset()
  if fs.exists(DIR) then fs.delete(DIR) end
  fs.makeDir(DIR)
end

local alice, bob, carol
local function keysets()
  if not alice then
    alice = pgp.generate("Alice <alice@base>")
    bob = pgp.generate("Bob <bob@base>")
    carol = pgp.generate("Carol <carol@base>")
  end
end

local function publicOnly(key) return pgp.importText(pgp.exportPublic(key)) end

test("armor round trip, several blocks, damage is detected", function()
  local bin = armor.records({ { 1, "hello" }, { 9, string.rep("x", 1000) } })
  local text = armor.armor("MESSAGE", bin)
  ok(text:find("^%-%-%-%-%-BEGIN TESSERA MESSAGE%-%-%-%-%-\n"))
  local kind, back, rest = armor.dearmor("junk before\n" .. text .. "junk after")
  eq(kind, "MESSAGE")
  eq(back, bin)
  eq(armor.parse(back)[1][2], "hello")
  local two = text .. armor.armor("SIGNATURE", "abc")
  local k1, _, after = armor.dearmor(two)
  local k2, b2 = armor.dearmor(after)
  eq(k1, "MESSAGE") eq(k2, "SIGNATURE") eq(b2, "abc")
  eq(armor.dearmor(two, "SIGNATURE"), "SIGNATURE")
  local bad = text:gsub("(\n[A-Za-z0-9+/]+)", function(l) return l:sub(1, 5) .. (l:sub(6, 6) == "A" and "B" or "A") .. l:sub(7) end, 1)
  local bk, berr = armor.dearmor(bad)
  ok(bk == nil and berr:find("checksum", 1, true), tostring(berr))
  ok(not armor.dearmor("nothing here"))
  ok(not armor.dearmor("-----BEGIN TESSERA MESSAGE-----\nAAAA\n"))
  ok(not armor.parse("\1\0\0\0\9ab"), "truncated record")
end)

test("a generated key has a bound identity, a fingerprint and survives export/import", function()
  keysets()
  ok(pgp.selfSigned(alice))
  ok(pgp.fingerprint(alice):match("^%x%x%x%x %x%x%x%x %x%x%x%x %x%x%x%x %x%x%x%x %x%x%x%x %x%x%x%x %x%x%x%x %x%x%x%x %x%x%x%x$"), pgp.fingerprint(alice))
  eq(#pgp.keyId(alice), 16)
  local text = pgp.exportPublic(alice)
  ok(not text:find(crypto.toHex(alice.secret.sign), 1, true))
  local back = assert(pgp.importText(text))
  eq(back.uid, "Alice <alice@base>")
  eq(back.fp, alice.fp)
  eq(back.secret, nil)
  -- altering the identity breaks the self-signature
  local forged = text:gsub("", "")
  local kind, bin = armor.dearmor(text)
  local recs = armor.parse(bin)
  recs[1][2] = recs[1][2]:sub(1, -2) .. "X"
  local ok2, err = pgp.parseBlock(armor.records(recs))
  ok(ok2 == nil and err:find("self%-signature"), tostring(err))
  -- importing a secret block as text needs the passphrase before the secret is usable
  local sealed = pgp.exportSecret(alice, "open sesame")
  local parsed = assert(pgp.importText(sealed))
  ok(pgp.needsPassphrase(parsed))
  local good, why = pgp.unlock(parsed, "nope")
  ok(good == nil and why == "passphrase")
  ok(pgp.unlock(parsed, "open sesame"))
  eq(parsed.secret.sign, alice.secret.sign)
  local plainBlock = assert(pgp.importText(pgp.exportSecret(alice)))
  ok(not pgp.needsPassphrase(plainBlock))
  ok(pgp.unlock(plainBlock))
end)

test("signatures: detached, text mode, tampering, wrong key", function()
  keysets()
  local data = "the plan: meet at the red tower\n"
  local sig = pgp.sign(data, alice)
  local info = assert(pgp.parseSignature(sig))
  ok(pgp.verify(data, info, alice))
  local bad, why = pgp.verify(data .. "!", info, alice)
  ok(not bad and why:find("does not match", 1, true), tostring(why))
  bad, why = pgp.verify(data, info, bob)
  ok(not bad and why:find("different key", 1, true))
  -- forged signature bytes
  local bin = sig:sub(1, -3) .. "xx"
  local forgedInfo = assert(pgp.parseSignature(bin))
  ok(not pgp.verify(data, forgedInfo, alice))
  -- text signatures survive line-ending and trailing-space changes
  local t = pgp.sign("line one  \r\nline two\r\n", alice, { text = true })
  local tinfo = assert(pgp.parseSignature(t))
  ok(pgp.verify("line one\nline two", tinfo, alice))
  ok(not pgp.verify("line one\nline TWO", tinfo, alice))
  -- armored detached signature
  local kind, back = armor.dearmor(pgp.armorSignature(sig))
  eq(kind, "SIGNATURE")
  eq(back, sig)
end)

test("clear-signed messages, with dash escaping", function()
  keysets()
  local text = "Orders:\n- build the wall\n-----not an armor line\nthe end"
  local msg = pgp.clearsign(text, alice)
  ok(msg:find("^%-%-%-%-%-BEGIN TESSERA SIGNED MESSAGE"))
  ok(msg:find("\n- - build the wall", 1, true))
  local body, info = pgp.parseClearsigned(msg)
  eq(body, text)
  ok(pgp.verify(body, info, alice))
  local tampered = msg:gsub("build the wall", "open the gate")
  local tb, tinfo = pgp.parseClearsigned(tampered)
  ok(not pgp.verify(tb, tinfo, alice))
end)

test("encryption to several recipients, by passphrase, signed, large and empty", function()
  keysets()
  local secret = "launch codes: " .. string.rep("0123456789", 900)         -- 9000 bytes: three chunks
  local bin = pgp.encrypt(secret, { publicOnly(alice), publicOnly(bob) })
  local back, info = pgp.decrypt(bin, { alice })
  eq(back, secret)
  eq(info.recipient.fp, alice.fp)
  eq(pgp.decrypt(bin, { bob }), secret)
  local none, why = pgp.decrypt(bin, { carol })
  ok(none == nil and why:find("no secret key", 1, true), tostring(why))
  ok(not pgp.decrypt(bin, { publicOnly(alice) }), "a public key cannot decrypt")
  -- passphrase mode (and a wrong passphrase)
  local sym = pgp.encrypt("symmetric text", {}, { passphrase = "hunter2" })
  eq(pgp.decrypt(sym, {}, { passphrase = "hunter2" }), "symmetric text")
  ok(not pgp.decrypt(sym, {}, { passphrase = "hunter3" }))
  -- sign and encrypt
  local signed = pgp.encrypt("for your eyes", { publicOnly(bob) }, { signer = alice })
  local plain, sinfo = pgp.decrypt(signed, { bob })
  eq(plain, "for your eyes")
  ok(sinfo.signature and pgp.verify(sinfo.signedData, sinfo.signature, alice))
  -- empty message
  eq(pgp.decrypt(pgp.encrypt("", { publicOnly(bob) }), { bob }), "")
  -- the armored form round-trips
  local text = pgp.armorMessage(bin)
  local kind, raw = armor.dearmor(text, "MESSAGE")
  eq(pgp.decrypt(raw, { alice }), secret)
end)

test("a damaged, truncated or reordered message is refused", function()
  keysets()
  local secret = string.rep("abcdefghij", 1200)
  local bin = pgp.encrypt(secret, { publicOnly(alice) })
  local recs = armor.parse(bin)
  -- flip a byte in the first data chunk
  local firstData
  for i, r in ipairs(recs) do if r[1] == 9 then firstData = i break end end
  local copy = {}
  for i, r in ipairs(recs) do copy[i] = { r[1], r[2] } end
  copy[firstData][2] = copy[firstData][2]:sub(1, 10) .. string.char((copy[firstData][2]:byte(11) + 1) % 256) .. copy[firstData][2]:sub(12)
  local plain, why = pgp.decrypt(armor.records(copy), { alice })
  ok(plain == nil and why:find("damaged", 1, true), tostring(why))
  -- drop the last chunk: the final-chunk marker is missing
  local short = {}
  for i = 1, #recs - 1 do short[i] = recs[i] end
  plain, why = pgp.decrypt(armor.records(short), { alice })
  ok(plain == nil and why:find("damaged or truncated", 1, true), tostring(why))
  -- swap two chunks
  local swapped = {}
  for i, r in ipairs(recs) do swapped[i] = r end
  swapped[firstData], swapped[firstData + 1] = swapped[firstData + 1], swapped[firstData]
  ok(pgp.decrypt(armor.records(swapped), { alice }) == nil)
  ok(not pgp.decrypt("garbage", { alice }))
end)

test("revoked and expired keys cannot be encrypted to; revocation is signed by the key", function()
  local k = pgp.generate("Dave <dave>", { expires = 100, created = 1000 })
  ok(pgp.expired(k, 1200))
  ok(not pgp.expired(k, 1050))
  local ok1, err = pcall(pgp.encrypt, "x", { publicOnly(k) })
  ok(not ok1 and tostring(err):find("expired", 1, true), tostring(err))
  local e = pgp.generate("Eve <eve>")
  pgp.revoke(e, 1)
  local blk = pgp.exportPublic(e)
  local back = assert(pgp.importText(blk))
  ok(back.revoked)
  ok(not pcall(pgp.encrypt, "x", { back }))
  -- someone else cannot revoke Eve: a forged revocation record is ignored
  local f = pgp.generate("Frank <frank>")
  local kind, bin = armor.dearmor(pgp.exportPublic(f))
  local recs = armor.parse(bin)
  recs[#recs + 1] = { 4, armor.u8(1) .. armor.u64(5) .. string.rep("x", 64) }
  local parsed = assert(pgp.parseBlock(armor.records(recs)))
  ok(not parsed.revoked, "a forged revocation must not count")
end)

test("web of trust: own key, certification paths, trust levels, marginal counts, revocation", function()
  local me = pgp.generate("Me <me>")
  local a, b, c, d = pgp.generate("A"), pgp.generate("B"), pgp.generate("C"), pgp.generate("D")
  local function pub(k) return publicOnly(k) end
  local ka, kb, kc, kd, km = pub(a), pub(b), pub(c), pub(d), pub(me)
  local trust = { [pgp.fpHex(me)] = "ultimate" }
  local function v() return pgp.validity({ km, ka, kb, kc, kd }, trust) end
  ok(v()[pgp.fpHex(me)].valid)
  ok(not v()[pgp.fpHex(ka)].valid, "nobody certified A yet")
  pgp.certify(me, ka, 2)
  ok(v()[pgp.fpHex(ka)].valid, "certified by my ultimately trusted key")
  -- A certifies B, but I do not trust A's judgement yet
  pgp.certify(a, kb, 1)
  ok(not v()[pgp.fpHex(kb)].valid)
  trust[pgp.fpHex(a)] = "full"
  ok(v()[pgp.fpHex(kb)].valid, "now A is a trusted introducer")
  -- marginal trust needs three independent certifications
  pgp.certify(b, kc, 1)
  trust[pgp.fpHex(b)] = "marginal"
  ok(not v()[pgp.fpHex(kc)].valid)
  pgp.certify(a, kc, 1)
  trust[pgp.fpHex(a)] = "marginal"
  ok(not v()[pgp.fpHex(kc)].valid, "two marginal certifications are not enough")
  pgp.certify(me, kc, 1)
  trust[pgp.fpHex(me)] = "ultimate"
  ok(v()[pgp.fpHex(kc)].valid, "my own certification of C counts as full trust")
  -- a forged certification does not count
  local forged = pgp.generate("Mallory")
  local kd2 = pub(d)
  kd2.certs[1] = { signer = me.fp20, created = 5, level = 1, sig = string.rep("x", 64) }
  ok(not pgp.validity({ km, kd2 }, trust)[pgp.fpHex(kd2)].valid)
  -- revoked keys are never valid
  pgp.revoke(c, 1)
  local kcRevoked = publicOnly(c)
  kcRevoked.certs = kc.certs
  ok(not pgp.validity({ km, ka, kb, kcRevoked }, trust)[pgp.fpHex(kcRevoked)].valid)
end)

test("keyring: add, merge certifications, find, unlock, trust, remove", function()
  reset()
  keysets()
  local r = ring.open(DIR .. "/ring")
  eq(#r:keys(), 0)
  r:addSecret(alice, "pw1")
  eq(#r:keys(), 1)
  ok(r:keys()[1].hasSecret)
  eq(r:ownerTrust(pgp.fpHex(alice)), "ultimate")
  local k = assert(r:find("alice"))
  ok(r:needsPassphrase(k))
  local un, err = r:unlock(k, "bad")
  ok(un == nil and err == "passphrase")
  un = assert(r:unlock(k, "pw1"))
  eq(un.secret.sign, alice.secret.sign)
  local added, status = r:add(pgp.exportPublic(bob))
  eq(status, "new")
  eq(select(2, r:add(pgp.exportPublic(bob))), "unchanged")
  -- a certification arrives with a newer copy of the key
  local bobCopy = publicOnly(bob)
  pgp.certify(un, bobCopy, 1)
  local _, st = r:add(pgp.exportPublic(bobCopy))
  eq(st, "updated")
  eq(#r:find("bob").certs, 1)
  local v = r:validity()
  ok(v[pgp.fpHex(bob)].valid, "certified by my own (ultimately trusted) key")
  ok(r:setTrust(pgp.fpHex(bob), "full"))
  ok(not r:setTrust(pgp.fpHex(bob), "bogus"))
  eq(r:find("zzz"), nil)
  ok(select(2, r:find("a")), "ambiguous queries are refused")
  eq(r:find(pgp.fpHex(bob):sub(1, 10)).uid, "Bob <bob@base>")
  eq(r:find(pgp.keyId(bob)).uid, "Bob <bob@base>")
  r:remove(r:find("bob"))
  eq(#r:keys(), 1)
  -- persistence: a second ring object on the same directory sees the same keys
  eq(#ring.open(DIR .. "/ring"):keys(), 1)
end)

local function scripted(inputs)
  local io = { said = {}, errs = {}, n = 0, files = {} }
  function io.say(t) io.said[#io.said + 1] = t end
  function io.err(t) io.errs[#io.errs + 1] = t end
  function io.readLine() io.n = io.n + 1 return inputs and inputs[io.n] end
  function io.readPassword() io.n = io.n + 1 return inputs and inputs[io.n] or "" end
  function io.collect() end
  function io.all() return table.concat(io.said, "\n") end
  return io
end

test("pgp command: gen-key, sign, verify, encrypt, decrypt, export/import, certify, trust", function()
  reset()
  local r = ring.open(DIR .. "/cring")
  local function run(io, ...) return cli.run({ ... }, io, nil, r) end
  local io = scripted()
  ok(run(io, "--gen-key", "Zed <zed@base>", "--passphrase", "pw"))
  ok(io:all():find("Key created", 1, true))
  io = scripted()
  ok(run(io, "--list-keys"))
  ok(io:all():find("Zed <zed@base>", 1, true) and io:all():find("valid", 1, true), io:all())
  vfs.writeFile(DIR .. "/note.txt", "secret plans\n")
  io = scripted()
  ok(run(io, "--sign", DIR .. "/note.txt", "--passphrase", "pw"), table.concat(io.errs, "|"))
  ok(fs.exists(DIR .. "/note.txt.sig"))
  io = scripted()
  ok(run(io, "--verify", DIR .. "/note.txt.sig", DIR .. "/note.txt"), table.concat(io.errs, "|"))
  ok(io:all():find("Good signature from Zed", 1, true), io:all())
  vfs.writeFile(DIR .. "/note.txt", "changed plans\n")
  io = scripted()
  ok(not run(io, "--verify", DIR .. "/note.txt.sig", DIR .. "/note.txt"))
  ok(table.concat(io.errs):find("BAD signature", 1, true))
  vfs.writeFile(DIR .. "/note.txt", "secret plans\n")
  io = scripted()
  ok(run(io, "--encrypt", "-r", "zed", "--sign", "--passphrase", "pw", DIR .. "/note.txt"), table.concat(io.errs, "|"))
  fs.delete(DIR .. "/note.txt")
  io = scripted()
  ok(run(io, "--decrypt", DIR .. "/note.txt.asc", "--passphrase", "pw"), table.concat(io.errs, "|"))
  ok(io:all():find("Good signature from Zed", 1, true), io:all())
  eq(vfs.readFile(DIR .. "/note.txt"), "secret plans\n")
  -- clearsign + verify from the same text
  io = scripted()
  ok(run(io, "--clearsign", DIR .. "/note.txt", "--passphrase", "pw", "-o", DIR .. "/clear.asc"))
  io = scripted()
  ok(run(io, "--verify", DIR .. "/clear.asc"), table.concat(io.errs, "|"))
  -- export to a second ring, import there; trust and certify
  io = scripted()
  ok(run(io, "--export", "zed", "-o", DIR .. "/zed.pub"))
  local r2 = ring.open(DIR .. "/other")
  io = scripted()
  ok(cli.run({ "--import", DIR .. "/zed.pub" }, io, nil, r2))
  ok(io:all():find("new", 1, true), io:all())
  io = scripted()
  ok(cli.run({ "--verify", DIR .. "/note.txt.sig", DIR .. "/note.txt" }, io, nil, r2))
  ok(io:all():find("not certified", 1, true), "unknown keys are flagged: " .. io:all())
  ok(cli.run({ "--gen-key", "Yan <yan>", "--passphrase", "" }, scripted(), nil, r2))
  io = scripted()
  ok(cli.run({ "--certify", "zed", "-u", "yan" }, io, nil, r2), table.concat(io.errs, "|"))
  ok(cli.run({ "--trust", "zed", "full" }, scripted(), nil, r2))
  io = scripted()
  cli.run({ "--list-keys", "zed" }, io, nil, r2)
  ok(io:all():find("%[valid%]"), io:all())
  -- encrypting to an unknown recipient, deleting
  io = scripted()
  ok(not run(io, "--encrypt", "-r", "nobody", DIR .. "/note.txt"))
  ok(run(scripted(), "--delete-key", "zed"))
  eq(#r:keys(), 0)
end)

test("key server over the in-game network: only public material is stored", function()
  reset()
  keysets()
  keyserver.DIR = DIR .. "/ks"
  local bus = netbus.new()
  local s = net.node({ id = 11, hostname = "keys", transport = bus:transport(11), peersPath = DIR .. "/s.peers" })
  local c = net.node({ id = 22, hostname = "client", transport = bus:transport(22), peersPath = DIR .. "/c.peers" })
  local failure
  parallel.waitForAny(
    function() s:run() end,
    function() c:run() end,
    function()
      local okRun, err = pcall(function()
        parallel.waitForAll(
          function() ok(s:pairListen({ code = "ABCDE-FGHJK", timeout = 10 })) end,
          function() sleep(0.2) ok(c:pairConnect(11, "ABCDE-FGHJK", 5)) end)
        keyserver.serve(s)
        local res, err2 = keyserver.send(c, 11, alice)
        ok(res, err2)
        eq(res.status, "new")
        ok(keyserver.send(c, 11, bob))
        local list = keyserver.search(c, 11, "alice")
        eq(#list, 1)
        eq(list[1].uid, "Alice <alice@base>")
        local mine = ring.open(DIR .. "/clientring")
        local key, st = keyserver.receive(c, 11, "alice", mine)
        ok(key, st)
        eq(key.fp, alice.fp)
        ok(not keyserver.receive(c, 11, "nobody-here", mine))
        -- the server never stores a secret: even a secret block is stored public only
        local stored = vfs.readFile(DIR .. "/ks/keys/" .. pgp.fpHex(alice) .. ".pub")
        ok(stored and not stored:find("SECRET", 1, true))
        eq(#ring.open(DIR .. "/ks"):keys(), 2)
      end)
      if not okRun then failure = err end
    end)
  if failure then error(failure, 0) end
end)
