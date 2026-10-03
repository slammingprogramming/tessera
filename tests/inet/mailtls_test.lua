-- SPDX-License-Identifier: AGPL-3.0-or-later
local msg = require("tsr.mail.message")
local storeMod = require("tsr.mail.store")
local mailMod = require("tsr.mail")
local smtp = require("tsr.mail.smtp")
local smtpd = require("tsr.mail.smtpd")
local pop3d = require("tsr.mail.pop3d")
local pop3 = require("tsr.mail.pop3")
local client = require("tsr.mail.client")
local tls = require("tsr.inet.tls")
local cert = require("tsr.inet.tls.cert")
local crypto = require("tsr.crypto")
local vfs = require("tsr.vfs")
local Sim = dofile("/tests/lib/inetsim.lua")

local ROOT = "/tmp/mailtls-test"

test("encrypted mail: STARTTLS and SMTPS, STLS and POP3S; passwords only over TLS; untrusted certificates refused", function()
  if vfs.fs.exists(ROOT) then vfs.fs.delete(ROOT) end
  vfs.fs.makeDir(ROOT) vfs.fs.makeDir(ROOT .. "/tls") vfs.fs.makeDir(ROOT .. "/tls/ca")
  local ca = crypto.signingKey(string.rep("\1", 32))
  local key = crypto.signingKey(string.rep("\2", 32))
  local c = cert.issue({ subject = "mx1.lan", key = key.public, issuerName = "Lab CA", issuerKey = ca })
  vfs.writeFile(ROOT .. "/tls/mx1.lan.crt", cert.encode(c))
  tls.saveKey(ROOT .. "/tls/mx1.lan.key", key)
  local trusting = tls.store({ dir = ROOT .. "/tls", tofu = false })
  trusting:addCa(cert.selfSigned("Lab CA", ca, { ca = true }))
  local strangers = tls.store({ dir = ROOT .. "/tls-empty", tofu = false })

  local sim = Sim.new()
  local seg = sim:segment("lan")
  local h = sim:host("mx1")
  sim:plug(h, "eth0", seg, "10.0.0.1/24")
  local pc = sim:host("pc")
  sim:plug(pc, "eth0", seg, "10.0.0.9/24")
  local cfg = { hostname = "mx1.lan", domains = { "example.lan" }, root = ROOT .. "/mb", users = ROOT .. "/users.db", queueDir = ROOT .. "/queue",
    allowPlainAuth = false, tls = { name = "mx1.lan", dir = ROOT .. "/tls" }, now = function() return 1000000 + sim.now end }
  local st = storeMod.new({ root = cfg.root, users = cfg.users, iterations = 3 })
  assert(st:addUser("alice", "password-alice"))
  assert(st:addUser("bob", "password-bob"))
  local m = mailMod.new(h, cfg, st)
  m.resolveMx = function() return nil, "nowhere" end
  for _, job in ipairs(assert(smtpd.workers(m, 2))) do local t = sim:spawn(job) t.daemon = true end
  for _, job in ipairs(assert(pop3d.workers(m, 2))) do local t = sim:spawn(job) t.daemon = true end
  sim:run(0.3)

  local function send(opts)
    local o = { from = "alice@example.lan", rcpts = { "bob@example.lan" }, helo = "pc.lan", data = msg.build({ from = "alice@example.lan", to = "bob@example.lan", subject = opts.subject or "Hi", body = "x", host = "example.lan" }),
      store = trusting, tlsName = "mx1.lan" }
    for k, v in pairs(opts) do o[k] = v end
    return smtp.deliver(pc, "10.0.0.1", o)
  end
  -- a login over a plain connection is refused, over STARTTLS it works
  local plain = send({ port = 587, tls = nil, auth = { user = "alice", pass = "password-alice" } })
  ok(not plain.ok and plain.error:find("does not offer authentication", 1, true), tostring(plain.error))
  local starttls = send({ port = 587, tls = "starttls", auth = { user = "alice", pass = "password-alice" }, subject = "via STARTTLS" })
  ok(starttls.ok and starttls.secure, tostring(starttls.error))
  eq(m.store:list("bob")[1].subject, "via STARTTLS")
  -- the secure port: TLS from the first byte
  local smtps = send({ port = 465, tls = "smtps", auth = { user = "alice", pass = "password-alice" }, subject = "via SMTPS" })
  ok(smtps.ok and smtps.secure, tostring(smtps.error))
  eq(#m.store:list("bob"), 2)
  -- a client that does not trust the certificate refuses to continue
  local bad = send({ port = 587, tls = "starttls", store = strangers, auth = { user = "alice", pass = "password-alice" } })
  ok(not bad.ok and bad.error:find("secure connection failed", 1, true), tostring(bad.error))
  -- STARTTLS required but not offered by a server without TLS
  local nokey = send({ port = 25, tls = "opportunistic" })
  ok(nokey.ok and nokey.secure, "opportunistic encryption between servers")
  -- POP3: USER/PASS only after STLS
  local clear, err = pop3.connect(pc, "10.0.0.1", { user = "bob", pass = "password-bob", tls = nil })
  ok(clear == nil and err:find("Encryption required", 1, true), tostring(err))
  local p = assert(pop3.connect(pc, "10.0.0.1", { user = "bob", pass = "password-bob", tls = "starttls", store = trusting, tlsName = "mx1.lan" }))
  ok(p.secure)
  ok(p:stat() >= 3)
  p:quit()
  local p2 = assert(pop3.connect(pc, "10.0.0.1", { user = "bob", pass = "password-bob", tls = "pop3s", store = trusting, tlsName = "mx1.lan" }))
  ok(p2.secure)
  eq(#assert(p2:list()), 3)
  p2:quit()
  local p3, err3 = pop3.connect(pc, "10.0.0.1", { user = "bob", pass = "password-bob", tls = "starttls", store = strangers, tlsName = "mx1.lan" })
  ok(p3 == nil and err3:find("secure connection failed", 1, true), tostring(err3))
  -- the mail program with the account setting tls=starttls
  local c2 = client.open({ home = ROOT .. "/home/.mail", stack = pc, tlsStore = trusting,
    account = { address = "bob@example.lan", server = "10.0.0.1", user = "bob", pass = "password-bob", tls = "starttls", tlsname = "mx1.lan" } })
  eq(c2:fetch(), 3)
  local sent, why = c2:send({ to = "alice@example.lan", subject = "Reply over TLS", body = "hello alice" })
  ok(sent, tostring(why))
  eq(m.store:list("alice")[1].subject, "Reply over TLS")
  pop3d.stop(m) smtpd.stop(m)
end)
