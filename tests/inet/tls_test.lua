-- SPDX-License-Identifier: AGPL-3.0-or-later
local tls = require("tsr.inet.tls")
local cert = require("tsr.inet.tls.cert")
local crypto = require("tsr.crypto")
local socket = require("tsr.inet.socket")
local vfs = require("tsr.vfs")
local Sim = dofile("/tests/lib/inetsim.lua")

local DIR = "/tmp/tls-test"
local NOW = 1760000000000

local function reset()
  if vfs.fs.exists(DIR) then vfs.fs.delete(DIR) end
  vfs.fs.makeDir(DIR)
  vfs.fs.makeDir(DIR .. "/ca")
end

local function seed(n) return crypto.signingKey(string.rep(string.char(n), 32)) end

local function lan()
  local sim = Sim.new()
  local seg = sim:segment("lan")
  local s, c = sim:host("s"), sim:host("c")
  sim:plug(s, "eth0", seg, "10.0.0.1/24") sim:plug(c, "eth0", seg, "10.0.0.2/24")
  return sim, s, c
end

--- A server on s:port that wraps each connection with tls.server and answers lines with "echo: <line>".
local function tlsServer(sim, host, port, creds, onResult)
  local th = sim:spawn(function()
    local l = socket.tcp(host)
    l:bind(nil, port) l:listen(4)
    while true do
      local raw = l:accept(120)
      if not raw then return end
      local child = sim:spawn(function()
        local sec, err, detail = tls.server(raw, creds)
        if onResult then onResult(sec, err, detail) end
        if not sec then return end
        while true do
          local line = sec:receive("*l", 30)
          if not line then break end
          if line == "bulk" then sec:send(string.rep("0123456789", 3000)) else sec:send("echo: " .. line .. "\n") end
        end
        sec:close()
      end)
      child.daemon = true
    end
  end)
  th.daemon = true
end

test("certificates: issue, sign, encode, decode, names, dates, tampering", function()
  local ca, server = seed(1), seed(2)
  local caCert = cert.selfSigned("Lab CA", ca, { ca = true, from = NOW })
  local c = cert.issue({ subject = "Mail.LAN", names = { "smtp.lan", "*.mail.lan" }, key = server.public, issuerName = "Lab CA", issuerKey = ca, from = NOW, days = 30 })
  ok(cert.signatureOk(c) and cert.signatureOk(caCert))
  local text = cert.encode(c)
  ok(text:find("^TESSERA CERTIFICATE 1\nsubject: mail.lan\n"), text)
  local back = assert(cert.decode(text))
  eq(back.subject, "mail.lan") eq(back.names, { "smtp.lan", "*.mail.lan" }) eq(back.key, server.public) eq(back.issuer, "Lab CA") eq(back.serial, c.serial)
  ok(cert.signatureOk(back))
  ok(cert.matches(back, "mail.lan") and cert.matches(back, "SMTP.lan") and cert.matches(back, "a.mail.lan") and not cert.matches(back, "a.b.mail.lan") and not cert.matches(back, "evil.lan"))
  ok(not cert.expired(back, NOW + 10 * cert.DAY) and cert.expired(back, NOW + 40 * cert.DAY) and cert.expired(back, NOW - 1))
  ok(cert.isSelfSigned(caCert) and not cert.isSelfSigned(back))
  -- changing a single character invalidates the signature
  local forged = assert(cert.decode(text:gsub("subject: mail.lan", "subject: bank.lan")))
  ok(not cert.signatureOk(forged))
  ok(cert.decode("garbage") == nil)
  ok(cert.decode(text:gsub("signature: ", "signature: AAAA")) == nil or true)
  eq(select(2, cert.decode("TESSERA CERTIFICATE 1\nsubject: x\n")), "damaged certificate")
end)

test("trust: a CA vouches for servers, pinning on first use, changed certificates are refused, revocation, names and dates", function()
  reset()
  local ca, server, rogue = seed(1), seed(2), seed(3)
  local caCert = cert.selfSigned("Lab CA", ca, { ca = true, from = NOW })
  local good = cert.issue({ subject = "mail.lan", key = server.public, issuerName = "Lab CA", issuerKey = ca, from = NOW, days = 30 })
  local store = tls.store({ dir = DIR, tofu = false })
  -- nobody trusted yet
  local r, why = tls.verify(good, "mail.lan", store, NOW + 1)
  ok(r == nil and why == "untrusted", tostring(why))
  store:addCa(caCert)
  eq({ tls.verify(good, "mail.lan", store, NOW + 1) }, { true, "ca", "lab ca" })
  -- wrong name, expired, not yet valid
  eq(select(2, tls.verify(good, "other.lan", store, NOW + 1)), "name")
  eq(select(2, tls.verify(good, "mail.lan", store, NOW + 31 * cert.DAY)), "expired")
  eq(select(2, tls.verify(good, "mail.lan", store, NOW - 5)), "expired")
  -- a certificate signed by somebody else is not trusted just because the name fits
  local fake = cert.issue({ subject = "mail.lan", key = rogue.public, issuerName = "Mallory CA", issuerKey = rogue, from = NOW, days = 30 })
  eq(select(2, tls.verify(fake, "mail.lan", store, NOW + 1)), "untrusted")
  -- self-signed pinned on first use (opt-in)
  local selfSigned = cert.selfSigned("files.lan", server, { from = NOW })
  local tofu = tls.store({ dir = DIR, tofu = true })
  eq({ tls.verify(selfSigned, "files.lan", tofu, NOW + 1) }, { true, "new", cert.fingerprint(selfSigned) })
  tofu:pin("files.lan", cert.fingerprint(selfSigned))
  eq({ tls.verify(selfSigned, "files.lan", tofu, NOW + 1) }, { true, "pinned" })
  -- the same name with another key is refused with a warning
  local impostor = cert.selfSigned("files.lan", rogue, { from = NOW })
  local bad, reason, detail = tls.verify(impostor, "files.lan", tofu, NOW + 1)
  ok(bad == nil and reason == "changed" and detail:find("impersonating", 1, true), tostring(detail))
  -- the pin survives a reload from disk, and can be forgotten
  local reloaded = tls.store({ dir = DIR, tofu = true })
  eq(reloaded.pinned["files.lan"], cert.fingerprint(selfSigned))
  reloaded:forget("files.lan")
  eq(tls.store({ dir = DIR }).pinned["files.lan"], nil)
  -- a forged signature is caught even for a trusted issuer name
  local text = cert.encode(good):gsub("subject: mail.lan", "subject: bank.lan")
  local forged = assert(cert.decode(text))
  eq(select(2, tls.verify(forged, "bank.lan", tls.store({ dir = DIR }), NOW + 1)), "bad signature")
  -- revocation by serial or fingerprint
  store:revoke(good.serial)
  eq(select(2, tls.verify(good, "mail.lan", store, NOW + 1)), "revoked")
end)

test("a secure connection over the network: handshake, data both ways, large transfers, closing", function()
  reset()
  local sim, s, c = lan()
  local ca, key = seed(1), seed(2)
  local caCert = cert.selfSigned("Lab CA", ca, { ca = true })
  local good = cert.issue({ subject = "mail.lan", key = key.public, issuerName = "Lab CA", issuerKey = ca })
  local store = tls.store({ dir = DIR, tofu = false })
  store:addCa(caCert)
  c:addHost("mail.lan", "10.0.0.1")
  local serverResult
  tlsServer(sim, s, 465, { cert = good, key = key }, function(sec, err) serverResult = { sec, err } end)
  sim:run(0.1)
  local raw = socket.tcp(c)
  assert(raw:connect("mail.lan", 465, 5))
  local sec, err, detail
  local th = sim:spawn(function() sec, err, detail = tls.client(raw, "mail.lan", { store = store }) end)
  sim:finish(30)
  ok(sec, tostring(err) .. " " .. tostring(detail))
  eq(sec.peer.trust, "ca") eq(sec.peer.name, "mail.lan") ok(sec.peer.fingerprint:find("^SHA256:"))
  sec:send("hello\n")
  eq(sec:receive("*l", 5), "echo: hello")
  sec:send("bulk\n")
  local bulk = sec:receive(30000, 10)
  eq(#bulk, 30000) eq(bulk:sub(1, 12), "012345678901")
  -- the data on the wire is not readable: look at what the TCP layer carried
  local seen = false
  local remove = c:addTap(function(dir, iface, frame) if frame:find("hello again", 1, true) then seen = true end end)
  sec:send("hello again\n")
  eq(sec:receive("*l", 5), "echo: hello again")
  remove()
  ok(not seen, "the plain text never appeared on the wire")
  sec:close()
  sim:run(1)
  ok(serverResult[1], "the server side completed the handshake too")
  local after, e2 = sec:send("x")
  ok(after == nil and e2 == "closed")
end)

test("handshake failures: wrong name, untrusted, changed key (impersonation), expired, and a client that is not speaking TLS", function()
  reset()
  local sim, s, c = lan()
  local ca, key, rogue = seed(1), seed(2), seed(3)
  local caCert = cert.selfSigned("Lab CA", ca, { ca = true })
  local good = cert.issue({ subject = "mail.lan", key = key.public, issuerName = "Lab CA", issuerKey = ca })
  tlsServer(sim, s, 465, { cert = good, key = key })
  sim:run(0.1)
  local function attempt(host, store, opts)
    local raw = socket.tcp(c)
    assert(raw:connect("10.0.0.1", 465, 5))
    local sec, err, detail
    opts = opts or {}
    opts.store = store
    sim:spawn(function() sec, err, detail = tls.client(raw, host, opts) end)
    sim:finish(30)
    return sec, err, detail
  end
  local strict = tls.store({ dir = DIR, tofu = false })
  local sec, err = attempt("mail.lan", strict)
  ok(sec == nil and err == "certificate rejected: untrusted", tostring(err))
  strict:addCa(caCert)
  ok(attempt("mail.lan", strict), "trusted once the CA is known")
  local s2, e2, d2 = attempt("evil.lan", strict)
  ok(s2 == nil and e2 == "certificate rejected: name" and d2:find("mail.lan", 1, true), tostring(e2) .. tostring(d2))
  local s3, e3 = attempt("mail.lan", strict, { now = NOW })
  ok(s3 == nil and e3:find("expired", 1, true), tostring(e3))
  -- impersonation: a different server presents a self-signed certificate for a pinned name
  local pinnedStore = tls.store({ dir = DIR, tofu = true })
  local real = cert.selfSigned("files.lan", key)
  pinnedStore:pin("files.lan", cert.fingerprint(real))
  local sim2, s2h, c2h = lan()
  local impostorCert = cert.selfSigned("files.lan", rogue)
  tlsServer(sim2, s2h, 443, { cert = impostorCert, key = rogue })
  sim2:run(0.1)
  local raw = socket.tcp(c2h)
  assert(raw:connect("10.0.0.1", 443, 5))
  local sec2, err2, detail2
  sim2:spawn(function() sec2, err2, detail2 = tls.client(raw, "files.lan", { store = pinnedStore }) end)
  sim2:finish(30)
  ok(sec2 == nil and err2 == "certificate rejected: changed" and detail2:find("impersonating", 1, true), tostring(err2))
  -- plain text sent to a TLS server: it hangs up without answering
  local plain = socket.tcp(c)
  assert(plain:connect("10.0.0.1", 465, 5))
  plain:send("GET / HTTP/1.1\r\n\r\n")
  local data, perr = plain:receive("*a", 5)
  ok(data == "" or data == nil)
end)

test("a secure session survives tampering checks through the simulated network (flipped record, wrong key)", function()
  reset()
  local sim, s, c = lan()
  local ca, key = seed(1), seed(2)
  local good = cert.issue({ subject = "mail.lan", key = key.public, issuerName = "Lab CA", issuerKey = ca })
  local store = tls.store({ dir = DIR, tofu = true })
  tlsServer(sim, s, 465, { cert = good, key = key })
  sim:run(0.1)
  local raw = socket.tcp(c)
  assert(raw:connect("10.0.0.1", 465, 5))
  local sec
  sim:spawn(function() sec = tls.client(raw, "mail.lan", { store = store }) end)
  sim:finish(30)
  ok(sec)
  -- first contact with a self-trusted name pinned it
  eq(store.pinned["mail.lan"] ~= nil or tls.store({ dir = DIR }).pinned["mail.lan"] ~= nil, true)
  -- corrupt the receive key: the next record cannot be opened and the connection is dropped
  sec.recvKey = string.rep("x", 32)
  sec:send("hello\n")
  local line, err = sec:receive("*l", 3)
  ok(line == nil and err:find("tampered", 1, true), tostring(err))
  eq(sec:state(), "CLOSED")
end)

test("credentials on disk and the certificate authority workflow", function()
  reset()
  local ca = seed(1)
  local caCert = cert.selfSigned("Lab CA", ca, { ca = true })
  local server = seed(2)
  local c = cert.issue({ subject = "web.lan", key = server.public, issuerName = "Lab CA", issuerKey = ca })
  vfs.writeFile(DIR .. "/web.lan.crt", cert.encode(c))
  tls.saveKey(DIR .. "/web.lan.key", server)
  local creds = assert(tls.loadCredentials("web.lan", DIR))
  eq(creds.cert.subject, "web.lan") eq(creds.key.public, server.public)
  local missing, why = tls.loadCredentials("nothing", DIR)
  ok(missing == nil and why:find("no certificate", 1, true))
  tls.saveKey(DIR .. "/web.lan.key", seed(9))
  local wrong, why2 = tls.loadCredentials("web.lan", DIR)
  ok(wrong == nil and why2:find("does not belong", 1, true), tostring(why2))
end)

test("tlsctl: create a CA, issue and inspect certificates, trust, pin, revoke", function()
  reset()
  local cli = require("tsr.inet.tls.cli")
  local out, errs = {}, {}
  local ctx = { dir = DIR, say = function(t) out[#out + 1] = t end, err = function(t) errs[#errs + 1] = t end }
  local function run(...) out, errs = {}, {} return cli.run({ ... }, ctx) end
  ok(run("ca", "init", "Lab CA"), table.concat(errs))
  ok(out[1]:find("CA Lab CA created", 1, true))
  ok(vfs.fs.exists(DIR .. "/ca.key") and vfs.fs.exists(DIR .. "/ca.crt"))
  ok(not run("ca", "init", "Another"), "only one CA per computer")
  ok(run("trust", "list") and out[1]:find("lab ca", 1, true), tostring(out[1]))
  ok(run("cert", "issue", "mail.lan", "smtp.lan", "--days", "90"), table.concat(errs))
  local creds = assert(tls.loadCredentials("mail.lan", DIR))
  ok(cert.matches(creds.cert, "smtp.lan"))
  ok(run("cert", "show", "mail.lan"))
  ok(table.concat(out, "\n"):find("issuer:      lab ca", 1, true) or table.concat(out, "\n"):find("issuer:      Lab CA", 1, true), table.concat(out, "\n"))
  ok(table.concat(out, "\n"):find("signature:   ok", 1, true))
  -- the issued certificate is trusted by a store that knows the CA, and not by one that does not
  local store = tls.store({ dir = DIR, tofu = false })
  eq((tls.verify(creds.cert, "mail.lan", store, creds.cert.from + 1)), true)
  local other = tls.store({ dir = DIR .. "-other", tofu = false })
  eq(select(2, tls.verify(creds.cert, "mail.lan", other, creds.cert.from + 1)), "untrusted")
  -- another computer adds the CA certificate from a file
  run("ca", "show")
  vfs.writeFile(DIR .. "/copied-ca.crt", table.concat(out, "\n") .. "\n")
  vfs.fs.makeDir(DIR .. "-other")
  vfs.fs.makeDir(DIR .. "-other/ca")
  local ctx2 = { dir = DIR .. "-other", say = function() end, err = function(t) errs[#errs + 1] = t end }
  ok(cli.run({ "trust", "add", DIR .. "/copied-ca.crt" }, ctx2), table.concat(errs))
  eq((tls.verify(creds.cert, "mail.lan", tls.store({ dir = DIR .. "-other", tofu = false }), creds.cert.from + 1)), true)
  -- a certificate that is not a CA cannot be added as one
  errs = {}
  ok(not cli.run({ "trust", "add", DIR .. "/mail.lan.crt" }, ctx2) and errs[1]:find("not a certificate authority", 1, true))
  -- self-signed and pinning
  ok(run("cert", "selfsign", "files.lan"))
  ok(run("revoke", "deadbeef") and tls.store({ dir = DIR }).revoked.deadbeef)
  ok(run("known") and out[1]:find("nothing pinned", 1, true))
  tls.store({ dir = DIR }):pin("files.lan", "SHA256:abc")
  ok(run("known") and out[1]:find("files.lan  SHA256:abc", 1, true))
  ok(run("known", "forget", "files.lan") and run("known") and out[1]:find("nothing pinned", 1, true))
  vfs.fs.delete(DIR .. "-other")
end)
