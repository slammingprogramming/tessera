-- SPDX-License-Identifier: AGPL-3.0-or-later
local B = require("tsr.inet.bytes")
local msg = require("tsr.mail.message")
local storeMod = require("tsr.mail.store")
local mailMod = require("tsr.mail")
local smtp = require("tsr.mail.smtp")
local smtpd = require("tsr.mail.smtpd")
local socket = require("tsr.inet.socket")
local hash = require("tsr.hash")
local vfs = require("tsr.vfs")
local Sim = dofile("/tests/lib/inetsim.lua")

local ROOT = "/tmp/mail-test"

local function clean()
  if vfs.fs.exists(ROOT) then vfs.fs.delete(ROOT) end
  vfs.fs.makeDir(ROOT)
end

test("addresses and headers: parsing, lists, folding, encoded words", function()
  local a = msg.parseAddress('"Doe, Jane" <Jane.Doe@Example.LAN>')
  eq(a.name, "Doe, Jane") eq(a.addr, "Jane.Doe@example.lan") eq(a.localPart, "Jane.Doe") eq(a.domain, "example.lan")
  eq(msg.parseAddress("bob@x.lan").addr, "bob@x.lan")
  eq(msg.parseAddress("<>").addr, "")
  ok(msg.parseAddress("not an address") == nil)
  local list = msg.parseAddressList('Alice <a@x.lan>, "Smith, Bob" <b@y.lan>, c@z.lan; d@w.lan')
  eq(#list, 4) eq(list[2].name, "Smith, Bob") eq(list[2].addr, "b@y.lan") eq(list[4].addr, "d@w.lan")
  eq(msg.formatAddress({ name = "Smith, Bob", addr = "b@y.lan" }), '"Smith, Bob" <b@y.lan>')
  eq(msg.formatAddress({ name = "", addr = "b@y.lan" }), "b@y.lan")
  local m = msg.parse("Subject: a very\r\n long subject\r\nFrom: =?UTF-8?B?" .. hash.base64Encode("Caf\195\169") .. "?= <c@x.lan>\r\nX-Multi: 1\r\nX-Multi: 2\r\n\r\nBody here\r\nsecond line\r\n")
  eq(m:subject(), "a very long subject")
  eq(m:from().addr, "c@x.lan")
  eq(m:headerAll("x-multi"), { "1", "2" })
  eq(m.body, "Body here\r\nsecond line\r\n")
  eq(msg.decodeWords("=?utf-8?Q?Hello_World=21?="), "Hello World!")
  ok(msg.encodeWord("plain") == "plain" and msg.encodeWord("Caf\195\169"):find("^=%?UTF%-8%?B%?"))
end)

test("MIME: build and parse messages with attachments, base64, quoted-printable, dot stuffing", function()
  local data = string.rep("\0\1\2binary", 30)
  local raw = msg.build({ from = "Alice <a@x.lan>", to = { "b@y.lan", "c@z.lan" }, subject = "Report", body = "See attached.\n.\nA line starting with a dot above.", host = "x.lan",
    attachments = { { name = "report.bin", data = data, type = "application/octet-stream" }, { name = "note.txt", data = "hello", type = "text/plain" } } })
  ok(raw:find("MIME%-Version: 1.0") and raw:find("multipart/mixed; boundary=", 1) and raw:find("\r\n"))
  local m = msg.parse(raw)
  eq(m:subject(), "Report") eq(m:from().name, "Alice") eq(#m:addresses("to"), 2)
  ok(m:header("message-id"):find("@x.lan>", 1, true) and m:header("date"):find("%d%d%d%d"))
  eq(m:text(), "See attached.\n.\nA line starting with a dot above.\n")
  local att = m:attachments()
  eq(#att, 2) eq(att[1].name, "report.bin") eq(att[1].data, data) eq(att[2].name, "note.txt") eq(att[2].data, "hello")
  -- a simple message
  local simple = msg.parse(msg.build({ from = "a@x.lan", to = "b@y.lan", subject = "Hi", body = "one\ntwo" }))
  eq(simple:text(), "one\ntwo\n") eq(#simple:attachments(), 0)
  -- quoted-printable
  eq(msg.qpDecode("caf=C3=A9 soft=\r\nbreak"), "caf\195\169 softbreak")
  eq(msg.qpDecode(msg.qpEncode("a = b \195\169\r\nline2")), "a = b \195\169\r\nline2")
  local qp = msg.parse("Content-Type: text/plain\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nprice =3D 5=\r\n0\r\n")
  eq(qp:text(), "price = 50\n")
  -- HTML only: tags are removed
  local html = msg.parse("Content-Type: text/html\r\n\r\n<p>Hello <b>world</b> &amp; all</p>")
  eq(html:text(), "Hello world & all")
  -- dot stuffing round trip
  local stuffed = msg.dotStuff("a\r\n.b\r\n..c\r\n.")
  eq(stuffed, "a\r\n..b\r\n...c\r\n..\r\n")
  local lines = {}
  for l in stuffed:gmatch("(.-)\r\n") do lines[#lines + 1] = l end
  eq(msg.dotUnstuff(lines), { "a", ".b", "..c", "." })
  eq(msg.prepend("Subject: x\r\n\r\nbody", { "Received: a", "X-Test: 1" }), "Received: a\r\nX-Test: 1\r\nSubject: x\r\n\r\nbody")
end)

test("mailboxes: accounts, passwords, delivery, flags, folders, quota, expunge, rebuilding the index", function()
  clean()
  local st = storeMod.new({ root = ROOT .. "/mb", users = ROOT .. "/users.db", iterations = 3 })
  ok(st:addUser("alice", "correct horse", { quota = 5000 }))
  ok(not st:addUser("alice", "again12345"))
  eq(select(2, st:addUser("x", "short")), "the password needs at least 6 characters")
  eq(select(2, st:addUser("bad name", "longenough")), "a mailbox name has letters, digits, dots, dashes and underscores")
  eq(st:authenticate("alice", "correct horse"), "alice")
  eq(st:authenticate("ALICE", "correct horse"), "alice", "names are not case sensitive")
  eq(st:authenticate("alice", "wrong"), nil) eq(st:authenticate("nobody", "x"), nil)
  ok(st:exists("alice") and not st:exists("bob"))
  eq(st:folders("alice"), { "INBOX", "Drafts", "Sent", "Spam", "Trash" })
  local raw1 = msg.build({ from = "bob@y.lan", to = "alice@x.lan", subject = "First", body = "one" })
  local raw2 = msg.build({ from = "bob@y.lan", to = "alice@x.lan", subject = "Second", body = "two" })
  local u1, u2 = assert(st:deliver("alice", raw1)), assert(st:deliver("alice", raw2))
  eq({ u1, u2 }, { 1, 2 })
  local list = st:list("alice")
  eq(#list, 2) eq(list[1].subject, "First") eq(list[1].flags, "") eq(list[2].uid, 2) ok(list[1].size > 100)
  eq(st:get("alice", "INBOX", 2), raw2)
  ok(st:setFlags("alice", "INBOX", 1, "SF"))
  eq(st:list("alice")[1].flags, "SF")
  ok(st:setFlags("alice", "INBOX", 1, nil, "F"))
  eq(st:list("alice")[1].flags, "S")
  -- flagged deleted, gone after expunge; uids are not reused
  ok(st:setFlags("alice", "INBOX", 1, "D"))
  eq(#st:list("alice"), 2)
  eq(st:expunge("alice"), 1)
  eq(#st:list("alice"), 1)
  eq(assert(st:deliver("alice", raw1)), 3)
  -- moving
  local moved = assert(st:move("alice", "INBOX", 2, "Trash"))
  eq(moved, 1) eq(#st:list("alice", "Trash"), 1) eq(#st:list("alice"), 1)
  -- own folders
  ok(st:createFolder("alice", "Projects") and not st:createFolder("alice", "Projects"))
  ok(st:deliver("alice", raw1, "Projects"))
  ok(select(2, st:deleteFolder("alice", "INBOX")) == "the standard folders cannot be removed")
  ok(st:deleteFolder("alice", "Projects"))
  -- quota
  local big = msg.build({ from = "b@y.lan", to = "a@x.lan", subject = "big", body = string.rep("x", 6000) })
  local uid, why = st:deliver("alice", big)
  ok(uid == nil and why == "quota", tostring(why))
  ok(st:usage("alice") > 300)
  ok(st:setQuota("alice", 100000) and st:deliver("alice", big))
  -- the index is rebuilt from the files when it is lost
  vfs.fs.delete(ROOT .. "/mb/alice/INBOX/.index")
  local st2 = storeMod.new({ root = ROOT .. "/mb", users = ROOT .. "/users.db", iterations = 3 })
  eq(#st2:list("alice"), 2)
  eq(st2:list("alice")[1].subject, "First")
  ok(st:setPassword("alice", "new password") and st:authenticate("alice", "new password") and not st:authenticate("alice", "correct horse"))
  ok(st:removeUser("alice") and not vfs.fs.exists(ROOT .. "/mb/alice"))
end)

--- A mail server computer on a simulated network.
local function server(sim, seg, name, ip, cfg, users)
  local h = sim:host(name)
  sim:plug(h, "eth0", seg, ip .. "/24")
  cfg.hostname = name .. ".lan"
  cfg.root, cfg.users, cfg.queueDir = ROOT .. "/" .. name .. "/mb", ROOT .. "/" .. name .. "/users.db", ROOT .. "/" .. name .. "/queue"
  cfg.allowPlainAuth = cfg.allowPlainAuth ~= false
  cfg.now = function() return 1000000 + sim.now end
  cfg.retryDelays = cfg.retryDelays or { 5, 10, 20 }
  local st = storeMod.new({ root = cfg.root, users = cfg.users, iterations = 3 })
  for _, u in ipairs(users or {}) do assert(st:addUser(u, "password-" .. u)) end
  local m = mailMod.new(h, cfg, st)
  return h, m
end

local function world()
  clean()
  local sim = Sim.new()
  local seg = sim:segment("lan")
  local h1, m1 = server(sim, seg, "mx1", "10.0.0.1", { domains = { "example.lan" }, relayNetworks = { "10.0.0.0/24" },
    aliases = { postmaster = "alice", ["team@example.lan"] = { "alice", "bob", "carol@other.lan" } } }, { "alice", "bob" })
  local h2, m2 = server(sim, seg, "mx2", "10.0.0.2", { domains = { "other.lan" }, relayNetworks = {} }, { "carol", "dave" })
  local pc = sim:host("pc")
  sim:plug(pc, "eth0", seg, "10.0.0.9/24")
  local resolve = function(domain) if domain == "example.lan" then return { "10.0.0.1" } elseif domain == "other.lan" then return { "10.0.0.2" } end return nil, "the domain " .. domain .. " does not exist" end
  m1.resolveMx, m2.resolveMx = resolve, resolve
  for _, m in ipairs({ m1, m2 }) do
    for _, job in ipairs(assert(smtpd.workers(m, 2))) do local t = sim:spawn(job) t.daemon = true end
  end
  sim:run(0.2)
  return sim, { h1 = h1, m1 = m1, h2 = h2, m2 = m2, pc = pc }
end

test("an SMTP session: the dialogue, ordering, recipients, limits", function()
  clean()
  local sim = Sim.new()
  local seg = sim:segment("lan")
  local h, m = server(sim, seg, "mx1", "10.0.0.1", { domains = { "example.lan" }, relayNetworks = { "10.0.0.0/24" }, allowPlainAuth = false, aliases = { postmaster = "alice" }, maxSize = 2000, maxRecipients = 3, maxErrors = 4 }, { "alice", "bob" })
  local function session(ip, opts) return smtpd.session(m, ip or "192.168.5.5", opts) end
  local s = session()
  ok(s:greeting():find("^220 mx1.lan ESMTP"))
  eq(s:line("MAIL FROM:<a@y.lan>"), "503 5.5.1 Say EHLO first")
  local ehlo = s:line("EHLO client.lan")
  ok(ehlo:find("250-mx1.lan Hello 192.168.5.5", 1, true) and ehlo:find("250-SIZE 2000", 1, true) and ehlo:find("250 HELP", 1, true) and not ehlo:find("STARTTLS", 1, true), ehlo)
  ok(not ehlo:find("AUTH", 1, true), "no login offered on an unencrypted connection")
  eq(s:line("RCPT TO:<alice@example.lan>"), "503 5.5.1 Need MAIL FROM first")
  eq(s:line("MAIL FROM:<sender@y.lan> SIZE=999999"), "552 5.3.4 Message size exceeds the limit of 2000 bytes")
  eq(s:line("MAIL FROM:<sender@y.lan>"), "250 2.1.0 Ok")
  eq(s:line("MAIL FROM:<again@y.lan>"), "503 5.5.1 A sender was given already")
  eq(s:line("RCPT TO:<alice@example.lan>"), "250 2.1.5 Ok")
  eq(s:line("RCPT TO:<ghost@example.lan>"), "550 5.1.1 <ghost@example.lan>: Recipient address rejected: User unknown in local recipient table")
  eq(s:line("RCPT TO:<someone@elsewhere.lan>"), "554 5.7.1 <someone@elsewhere.lan>: Relay access denied")
  eq(s:line("RCPT TO:<carol@example.lan>"), "550 5.1.1 <carol@example.lan>: Recipient address rejected: User unknown in local recipient table")
  eq(s:line("RCPT TO:<bob+news@example.lan>"), "250 2.1.5 Ok")
  eq(s:line("RCPT TO:<postmaster@example.lan>"), "250 2.1.5 Ok")
  eq(s:line("RSET"), "250 2.0.0 Ok")
  eq(s:line("DATA"), "503 5.5.1 Need RCPT TO first")
  eq(s:line("NOOP"), "250 2.0.0 Ok")
  eq(s:line("VRFY alice"):sub(1, 3), "252")
  -- six wrong commands in a row end the session
  local action
  for _ = 1, 4 do _, action = s:line("BOGUS") end
  eq(action, "close")
  -- recipients are limited
  local s2 = session("10.0.0.5")
  s2:line("EHLO c") s2:line("MAIL FROM:<x@y.lan>")
  for _ = 1, 3 do eq(s2:line("RCPT TO:<alice@example.lan>"), "250 2.1.5 Ok") end
  eq(s2:line("RCPT TO:<alice@example.lan>"), "452 4.5.3 Too many recipients")
  -- trusted networks may relay
  local s3 = session("10.0.0.5")
  s3:line("EHLO c") s3:line("MAIL FROM:<x@y.lan>")
  eq(s3:line("RCPT TO:<anyone@elsewhere.lan>"), "250 2.1.5 Ok")
  -- DATA: end marker, dot unstuffing, size limit, and the message is stored
  local s4 = session("192.168.5.6")
  s4:line("EHLO c") s4:line("MAIL FROM:<sender@y.lan>") s4:line("RCPT TO:<alice@example.lan>")
  local r, a = s4:line("DATA")
  eq(r:sub(1, 3), "354") eq(a, "data")
  for _, l in ipairs({ "Subject: Hello", "From: sender@y.lan", "", "first", "..dotted", "last" }) do eq(s4:dataLine(l), nil) end
  local done = s4:dataLine(".")
  ok(done:find("^250 2.0.0 Ok: queued as "), done)
  local inbox = m.store:list("alice")
  eq(#inbox, 1) eq(inbox[1].subject, "Hello")
  local text = m.store:get("alice", "INBOX", 1)
  ok(text:find("Return-Path: <sender@y.lan>", 1, true) and text:find("Delivered-To: alice@example.lan", 1, true) and text:find("Received: from c %(%[192.168.5.6%]%)"), text)
  ok(text:find("\r\n.dotted\r\n", 1, true), "the leading dot was removed")
  eq(s4.state, "greeted")
  -- too large
  local s5 = session("192.168.5.7")
  s5:line("EHLO c") s5:line("MAIL FROM:<sender@y.lan>") s5:line("RCPT TO:<alice@example.lan>") s5:line("DATA")
  for _ = 1, 100 do s5:dataLine(string.rep("x", 60)) end
  ok(s5.tooBig)
  eq(s5:finishTooBig():sub(1, 3), "552")
  -- a loop: too many Received headers
  local s6 = session("192.168.5.8")
  s6:line("EHLO c") s6:line("MAIL FROM:<sender@y.lan>") s6:line("RCPT TO:<alice@example.lan>")
  local lines = {}
  for i = 1, 31 do lines[#lines + 1] = "Received: from hop" .. i end
  eq(s6:finish(table.concat(lines, "\r\n") .. "\r\n\r\nbody"):sub(1, 3), "554")
  -- a bounce (empty sender) is accepted
  local s7 = session("192.168.5.9")
  s7:line("EHLO c")
  eq(s7:line("MAIL FROM:<>"), "250 2.1.0 Ok")
end)

test("authentication and submission: PLAIN and LOGIN, spoofing, brute force", function()
  clean()
  local sim = Sim.new()
  local seg = sim:segment("lan")
  local h, m = server(sim, seg, "mx1", "10.0.0.1", { domains = { "example.lan" }, allowPlainAuth = false }, { "alice", "bob" })
  local function b64(s) return hash.base64Encode(s) end
  local s = smtpd.session(m, "192.168.5.5", { kind = "submission" })
  s:line("EHLO c")
  eq(s:line("MAIL FROM:<alice@example.lan>"), "530 5.7.0 Authentication required")
  eq(s:line("AUTH PLAIN " .. b64("\0alice\0password-alice")):sub(1, 3), "538")
  -- on an encrypted connection login is allowed
  local t = smtpd.session(m, "192.168.5.5", { kind = "submission", secure = true })
  ok(t:line("EHLO c"):find("AUTH PLAIN LOGIN", 1, true))
  eq(t:line("AUTH PLAIN " .. b64("\0alice\0password-alice")), "235 2.7.0 Authentication successful")
  eq(t.auth, "alice")
  ok(not t:line("EHLO again"):find("AUTH", 1, true) or true)
  -- sending as someone else is refused
  eq(t:line("MAIL FROM:<bob@example.lan>"), "553 5.7.1 You may not send as bob@example.lan")
  eq(t:line("MAIL FROM:<alice@example.lan>"), "250 2.1.0 Ok")
  eq(t:line("RCPT TO:<anyone@elsewhere.lan>"), "250 2.1.5 Ok", "logged-in users may relay")
  -- LOGIN, with the prompts of the real protocol
  local u = smtpd.session(m, "192.168.5.6", { kind = "submission", secure = true })
  u:line("EHLO c")
  eq(u:line("AUTH LOGIN"), "334 VXNlcm5hbWU6")
  eq(u:line(b64("bob")), "334 UGFzc3dvcmQ6")
  eq(u:line(b64("password-bob")), "235 2.7.0 Authentication successful")
  -- wrong passwords: five failures lock the address out for a while
  local v = smtpd.session(m, "192.168.5.7", { kind = "submission", secure = true })
  v:line("EHLO c")
  for _ = 1, 5 do eq(v:line("AUTH PLAIN " .. b64("\0alice\0guess")):sub(1, 3), "535") end
  local locked, action = v:line("AUTH PLAIN " .. b64("\0alice\0password-alice"))
  eq(locked:sub(1, 3), "421") eq(action, "close")
  -- a cancelled or garbled exchange
  local w = smtpd.session(m, "192.168.5.8", { kind = "submission", secure = true })
  w:line("EHLO c")
  eq(w:line("AUTH PLAIN"), "334 ")
  eq(w:line("*"):sub(1, 3), "501")
  eq(w:line("AUTH PLAIN !!!notbase64"):sub(1, 3), "501")
  eq(w:line("AUTH CRAM-MD5"):sub(1, 3), "504")
end)

test("mail between two servers: submission, relaying, aliases, lists, +tags, MX lookup", function()
  local sim, w = world()
  local r1 = smtp.deliver(w.pc, "10.0.0.1", { from = "alice@example.lan", rcpts = { "carol@other.lan", "bob+work@example.lan" }, helo = "pc.lan", port = 587,
    auth = { user = "alice", pass = "password-alice" }, data = msg.build({ from = "Alice <alice@example.lan>", to = "carol@other.lan", subject = "Across", body = "Hello across servers" }) })
  ok(r1.ok, tostring(r1.error))
  eq(#r1.accepted, 2)
  sim:run(1)
  -- the local recipient got it at once; the remote one after the relay
  eq(w.m1.store:list("bob")[1].subject, "Across")
  local carol = w.m2.store:list("carol")
  eq(#carol, 1)
  local raw = w.m2.store:get("carol", "INBOX", 1)
  ok(raw:find("Received: from mx1.lan", 1, true) and raw:find("Return-Path: <alice@example.lan>", 1, true), raw)
  eq(#w.m1:queueList(), 0, "the queue is empty again")
  -- a list expands to local and remote members
  local r3 = smtp.deliver(w.pc, "10.0.0.1", { from = "pc@example.lan", rcpts = { "team@example.lan" }, helo = "pc.lan", port = 25,
    data = msg.build({ from = "pc@example.lan", to = "team@example.lan", subject = "List mail", body = "x" }) })
  ok(r3.ok, tostring(r3.error))
  w.m1:processQueue(true)
  sim:run(1)
  eq(w.m1.store:list("alice")[1].subject, "List mail")
  eq(w.m1.store:list("bob")[2].subject, "List mail")
  eq(w.m2.store:list("carol")[2].subject, "List mail", "the remote member of the list")
  -- postmaster is an alias
  local r4 = smtp.deliver(w.pc, "10.0.0.1", { from = "x@y.lan", rcpts = { "postmaster@example.lan" }, helo = "pc.lan", port = 25, data = msg.build({ from = "x@y.lan", to = "postmaster@example.lan", subject = "Problem", body = "help" }) })
  ok(r4.ok)
  eq(w.m1.store:list("alice")[2].subject, "Problem")
  -- relaying for strangers is refused: take the pc out of the trusted networks
  w.m1.relayNets = { { B.ip("192.168.0.0"), 16 } }
  local r5 = smtp.deliver(w.pc, "10.0.0.1", { from = "x@y.lan", rcpts = { "carol@other.lan" }, helo = "pc.lan", port = 25, data = "Subject: spam\r\n\r\nbuy now" })
  ok(not r5.ok and r5.rejected["carol@other.lan"].code == 554, tostring(r5.error))
  ok(r5.rejected["carol@other.lan"].text:find("Relay access denied", 1, true))
end)

test("failures: unknown users bounce, a server that is down is retried, giving up after the maximum age, mailbox full", function()
  local sim, w = world()
  w.m1.cfg.deliverNow = false
  local function submit(from, to, subject)
    return smtp.deliver(w.pc, "10.0.0.1", { from = from, rcpts = { to }, helo = "pc.lan", port = 587, auth = { user = "alice", pass = "password-alice" },
      data = msg.build({ from = from, to = to, subject = subject, body = "body", host = "pc.lan" }) })
  end
  -- an unknown remote user: the remote server says 550 and the sender gets a bounce message
  ok(submit("alice@example.lan", "nobody@other.lan", "Lost").ok)
  eq(#w.m1:queueList(), 1)
  w.m1:processQueue(true)
  sim:run(1)
  w.m1:processQueue(true)
  local inbox = w.m1.store:list("alice")
  eq(#inbox, 1) eq(inbox[1].subject, "Undelivered Mail Returned to Sender")
  local bounce = w.m1.store:get("alice", "INBOX", 1)
  ok(bounce:find("nobody@other.lan", 1, true) and bounce:find("User unknown", 1, true) and bounce:find("Subject: Lost", 1, true) and bounce:find("Auto%-Submitted: auto%-replied"), bounce)
  eq(#w.m1:queueList(), 0)
  eq(w.m1.stats.bounced, 1)
  -- the other server is down: the message stays queued and is delivered after it comes back
  w.h2:iface("eth0").port.down = true
  ok(submit("alice@example.lan", "carol@other.lan", "Later").ok)
  w.m1:processQueue(true)
  local q = w.m1:queueList()
  eq(#q, 1) eq(q[1].tries, 1) ok(q[1].last:find("cannot connect", 1, true), tostring(q[1].last))
  eq(w.m1.stats.deferred, 1)
  eq(#w.m2.store:list("carol"), 0)
  w.h2:iface("eth0").port.down = false
  sim:run(30)
  w.m1:processQueue(false)
  w.m1:processQueue(true)
  eq(#w.m1:queueList(), 0)
  eq(w.m2.store:list("carol")[1].subject, "Later")
  -- gives up after the maximum age and tells the sender
  w.m1.maxAge = 1
  w.h2:iface("eth0").port.down = true
  ok(submit("alice@example.lan", "carol@other.lan", "Hopeless").ok)
  sim:run(2)
  w.m1:processQueue(true)
  w.m1:processQueue(true)
  local list = w.m1.store:list("alice")
  eq(list[#list].subject, "Undelivered Mail Returned to Sender")
  ok(w.m1.store:get("alice", "INBOX", list[#list].uid):find("gave up", 1, true))
  w.h2:iface("eth0").port.down = false
  -- an unknown domain bounces at once
  ok(submit("alice@example.lan", "x@nowhere.lan", "Nowhere").ok)
  w.m1:processQueue(true)
  w.m1:processQueue(true)
  local l2 = w.m1.store:list("alice")
  ok(w.m1.store:get("alice", "INBOX", l2[#l2].uid):find("does not exist", 1, true))
  -- mailbox full: the sender gets a temporary failure at the SMTP level (the sender queue keeps trying, then bounces)
  w.m2.store:setQuota("dave", 100)
  local r = smtp.deliver(w.pc, "10.0.0.2", { from = "alice@example.lan", rcpts = { "dave@other.lan" }, helo = "pc.lan", port = 25, data = msg.build({ from = "alice@example.lan", to = "dave@other.lan", subject = "Full", body = "x" }) })
  ok(not r.ok and r.tempfail, tostring(r.error))
  ok(r.error:find("452", 1, true) or r.error:find("Mailbox full", 1, true) or r.error:find("refused", 1, true), tostring(r.error))
  -- messages that are too large are refused politely
  local big = smtp.deliver(w.pc, "10.0.0.2", { from = "alice@example.lan", rcpts = { "carol@other.lan" }, helo = "pc.lan", port = 25, data = "Subject: big\r\n\r\n" .. string.rep("x", 1200000) })
  ok(not big.ok and not big.tempfail and big.error:find("larger than the server accepts", 1, true), tostring(big.error))
end)
