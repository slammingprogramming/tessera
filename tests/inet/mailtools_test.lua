-- SPDX-License-Identifier: AGPL-3.0-or-later
local msg = require("tsr.mail.message")
local storeMod = require("tsr.mail.store")
local mailMod = require("tsr.mail")
local smtpd = require("tsr.mail.smtpd")
local pop3d = require("tsr.mail.pop3d")
local client = require("tsr.mail.client")
local cli = require("tsr.mail.cli")
local ctl = require("tsr.mail.ctl")
local config = require("tsr.mail.config")
local vfs = require("tsr.vfs")
local Sim = dofile("/tests/lib/inetsim.lua")

local ROOT = "/tmp/mailtools-test"

local function clean()
  if vfs.fs.exists(ROOT) then vfs.fs.delete(ROOT) end
  vfs.fs.makeDir(ROOT)
end

local function world()
  clean()
  local sim = Sim.new()
  local seg = sim:segment("lan")
  local function server(name, ip, cfg, users)
    local h = sim:host(name)
    sim:plug(h, "eth0", seg, ip .. "/24")
    cfg.hostname = name .. ".lan"
    cfg.root, cfg.users, cfg.queueDir = ROOT .. "/" .. name .. "/mb", ROOT .. "/" .. name .. "/users.db", ROOT .. "/" .. name .. "/queue"
    cfg.allowPlainAuth = true
    cfg.retryDelays = { 5, 10, 20 }
    cfg.now = function() return 1000000 + sim.now end
    local st = storeMod.new({ root = cfg.root, users = cfg.users, iterations = 3 })
    for _, u in ipairs(users) do assert(st:addUser(u, "password-" .. u)) end
    local m = mailMod.new(h, cfg, st)
    m.resolveMx = function(d) if d == "example.lan" then return { "10.0.0.1" } elseif d == "other.lan" then return { "10.0.0.2" } end return nil, "no such domain" end
    for _, job in ipairs(assert(smtpd.workers(m, 2))) do local t = sim:spawn(job) t.daemon = true end
    for _, job in ipairs(assert(pop3d.workers(m, 2))) do local t = sim:spawn(job) t.daemon = true end
    return h, m
  end
  local _, m1 = server("mx1", "10.0.0.1", { domains = { "example.lan" } }, { "alice", "bob" })
  local _, m2 = server("mx2", "10.0.0.2", { domains = { "other.lan" } }, { "carol" })
  local pc = sim:host("pc")
  sim:plug(pc, "eth0", seg, "10.0.0.9/24")
  sim:run(0.2)
  return sim, m1, m2, pc
end

local function account()
  return { address = "alice@example.lan", name = "Alice", server = "10.0.0.1", user = "alice", pass = "password-alice", tls = "none" }
end

test("the mail engine: fetch by POP3, read, reply, send, folders", function()
  local sim, m1, m2, pc = world()
  m1:deliverLocal("alice", msg.build({ from = "Bob <bob@other.lan>", to = "alice@example.lan", subject = "Plans", body = "Dinner at eight?\nBring snacks.", host = "other.lan", messageId = "<p1@other.lan>" }), "INBOX", "bob@other.lan")
  m1:deliverLocal("alice", msg.build({ from = "bob@other.lan", to = "alice@example.lan", subject = "Second", body = "again", host = "other.lan" }), "INBOX", "bob@other.lan")
  local c = client.open({ home = ROOT .. "/home/.mail", stack = pc, account = account() })
  eq(c:fetch(), 2)
  eq(c:fetch(), 0, "already fetched mail is not fetched again")
  eq(#m1.store:list("alice"), 2, "the server keeps its copy by default")
  local list = c:list("INBOX")
  eq(#list, 2) eq(list[1].subject, "Plans") eq(list[1].n, 1) eq(list[1].flags, "")
  local raw = assert(c:read("INBOX", 1))
  ok(raw:find("Dinner at eight?", 1, true))
  eq(c:list("INBOX")[1].flags, "S", "reading marks the message")
  -- a reply quotes the message and keeps the thread
  local r = c:replyTo(raw)
  eq(r.to, "bob@other.lan") eq(r.subject, "Re: Plans")
  ok(r.body:find("> Dinner at eight?", 1, true) and r.body:find("> Bring snacks.", 1, true), r.body)
  eq(r.headers["In-Reply-To"], "<p1@other.lan>")
  r.body = "Yes, see you.\n\n" .. r.body
  local sent, n = c:send(r)
  ok(sent, tostring(n))
  sim:run(1)
  local got = m2.store:list("bob")
  eq(#got, 0, "bob has no mailbox on the other server, carol does")
  -- the reply went to bob@other.lan, which does not exist there: the server of alice gets a bounce later; send to carol for a real delivery
  local ok2, why = c:send({ to = { "carol@other.lan" }, subject = "Hello Carol", body = "Greetings", attachments = { { name = "note.txt", data = "attached text", type = "text/plain" } } })
  ok(ok2, tostring(why))
  sim:run(1)
  local carol = m2.store:list("carol")
  eq(#carol, 1) eq(carol[1].subject, "Hello Carol")
  local parsed = msg.parse(m2.store:get("carol", "INBOX", carol[1].uid))
  eq(parsed:from().name, "Alice") eq(parsed:attachments()[1].data, "attached text")
  -- the sent mail is kept
  eq(#c:list("Sent"), 2)
  -- delete -> Trash -> gone
  ok(c:delete("INBOX", 2))
  eq(#c:list("INBOX"), 1) eq(#c:list("Trash"), 1)
  ok(c:delete("Trash", 1))
  eq(#c:list("Trash"), 0)
  ok(c:move("INBOX", 1, "Spam"))
  eq(#c:list("Spam"), 1)
  ok(not c:read("INBOX", 5))
  -- wrong password and missing settings
  local bad = client.open({ home = ROOT .. "/home2/.mail", stack = pc, account = { server = "10.0.0.1", user = "alice", pass = "nope", tls = "none" } })
  local nn, err = bad:fetch()
  ok(nn == nil and err:find("login refused", 1, true), tostring(err))
  local none = client.open({ home = ROOT .. "/home3/.mail", stack = pc, account = {} })
  ok(select(2, none:fetch()):find("no mail server", 1, true))
  ok(select(2, none:send({ to = "x@y.lan" })):find("no sender address", 1, true))
  -- leave = false removes the mail from the server after fetching
  local c2 = client.open({ home = ROOT .. "/home4/.mail", stack = pc, account = { address = "alice@example.lan", server = "10.0.0.1", user = "alice", pass = "password-alice", tls = "none", leave = false } })
  eq(c2:fetch(), 3, "the two messages and the bounce for the reply to a user who does not exist")
  eq(#m1.store:list("alice"), 0)
end)

local function script(lines)
  local out = { lines = {}, errors = {} }
  local i = 0
  out.ctx = {
    say = function(t) out.lines[#out.lines + 1] = t end,
    err = function(t) out.errors[#out.errors + 1] = t end,
    readLine = function() i = i + 1 return lines[i] end,
    readPassword = function() i = i + 1 return lines[i] end,
  }
  function out.text() return table.concat(out.lines, "\n") end
  return out
end

test("the mail program: account, fetch, list, read, send, reply, spam", function()
  local sim, m1, m2, pc = world()
  m1:deliverLocal("alice", msg.build({ from = "Bob <bob@other.lan>", to = "alice@example.lan", subject = "Plans", body = "Dinner at eight?", host = "other.lan" }), "INBOX", "bob@other.lan")
  m1:deliverLocal("alice", msg.build({ from = "prize@lottery.lan", to = "alice@example.lan", subject = "YOU WON", body = "click", host = "lottery.lan", headers = { ["X-Spam-Status"] = "Yes, score=9" } }), "INBOX", "x")
  local home = ROOT .. "/cli/.mail"
  local function run(args, lines, extra)
    local s = script(lines or {})
    s.ctx.home, s.ctx.stack = home, pc
    for k, v in pairs(extra or {}) do s.ctx[k] = v end
    local ok = cli.run(args, s.ctx)
    return ok, s
  end
  local _, s = run({ "account" })
  ok(s.text():find("no account yet", 1, true))
  ok(run({ "account", "set", "address=alice@example.lan", "server=10.0.0.1", "user=alice", "pass=password-alice", "tls=none", "name=Alice" }))
  _, s = run({ "account" })
  ok(s.text():find("address    alice@example.lan", 1, true) and s.text():find("pass       (saved)", 1, true) and not s.text():find("password-alice", 1, true), s.text())
  local bad = select(2, run({ "account", "set", "colour=blue" }))
  ok(bad.errors[1]:find("unknown setting colour", 1, true))
  _, s = run({ "fetch" })
  eq(s.lines[1], "2 new message(s)")
  _, s = run({ "fetch" })
  eq(s.lines[1], "no new mail")
  _, s = run({ "folders" })
  ok(s.text():find("INBOX%s+2 message%(s%), 2 unread"), s.text())
  _, s = run({ "list" })
  ok(s.text():find("1 N Bob", 1, true) and s.text():find("Plans", 1, true) and s.text():find("YOU WON", 1, true), s.text())
  _, s = run({ "read", "1" })
  ok(s.text():find("From:    Bob <bob@other.lan>", 1, true) and s.text():find("Subject: Plans", 1, true) and s.text():find("Dinner at eight?", 1, true), s.text())
  _, s = run({ "read", "2" })
  ok(s.text():find("marked this message as spam", 1, true), s.text())
  _, s = run({ "list" })
  ok(not s.text():find(" N ", 1, true), "both are read now")
  -- sending asks for the text, the end is a lone dot
  ok(run({ "send", "carol@other.lan", "-s", "From the CLI" }, { "first line", "second line", "." }))
  sim:run(1)
  local got = m2.store:list("carol")
  eq(#got, 1) eq(got[1].subject, "From the CLI")
  eq(msg.parse(m2.store:get("carol", "INBOX", got[1].uid)):text(), "first line\nsecond line\n")
  -- -m gives the text at once, -a attaches a file
  vfs.writeFile(ROOT .. "/report.txt", "the report", true)
  ok(run({ "send", "carol@other.lan", "-s", "With file", "-m", "see attached", "-a", ROOT .. "/report.txt" }))
  sim:run(1)
  local two = m2.store:list("carol")
  eq(#two, 2)
  eq(msg.parse(m2.store:get("carol", "INBOX", two[2].uid)):attachments()[1].name, "report.txt")
  -- reply
  ok(run({ "reply", "1" }, { "I will bring cake.", "." }))
  _, s = run({ "list", "Sent" })
  ok(s.text():find("Re: Plans", 1, true), s.text())
  -- moving and spam
  ok(run({ "spam", "2" }))
  _, s = run({ "list", "Spam" })
  ok(s.text():find("YOU WON", 1, true))
  ok(run({ "ham", "1" }))
  _, s = run({ "list" })
  ok(s.text():find("YOU WON", 1, true))
  ok(run({ "delete", "1" }))
  _, s = run({ "list", "Trash" })
  ok(s.text():find("Plans", 1, true))
  -- problems are reported, not thrown
  local fail, s2 = run({ "read", "9" })
  ok(not fail and s2.errors[1] == "no such message")
  fail, s2 = run({ "frobnicate" })
  ok(not fail and s2.errors[1]:find("unknown command", 1, true))
  fail, s2 = run({ "send" })
  ok(not fail and s2.errors[1]:find("usage: mail send", 1, true))
  -- interactive mode
  ok(run({}, { "help", "list", "bogus", "quit" }))
  _, s = run({}, { "list", "quit" })
  ok(s.text():find("Tessera mail", 1, true) and s.text():find("YOU WON", 1, true))
  eq(cli.words('send "a b" -s hello'), { "send", "a b", "-s", "hello" })
end)

test("mailctl: users, domains, relays, aliases, spam lists, DKIM, queue", function()
  clean()
  local savedRouting, savedFlush, savedDkim = config.ROUTING, config.FLUSH, config.DKIM_DIR
  config.ROUTING, config.FLUSH, config.DKIM_DIR = ROOT .. "/routing.db", ROOT .. "/flush", ROOT .. "/dkim"
  local store = storeMod.new({ root = ROOT .. "/mb", users = ROOT .. "/users.db", iterations = 2 })
  local cfg = { hostname = "mail.example.lan", domains = { "example.lan" }, queueDir = ROOT .. "/queue", spam = { bayes = ROOT .. "/bayes.lua" } }
  local function run(args, lines)
    local s = script(lines or {})
    s.ctx.store, s.ctx.config = store, cfg
    local okRun, result = pcall(ctl.run, args, s.ctx)
    config.ROUTING, config.FLUSH, config.DKIM_DIR = ROOT .. "/routing.db", ROOT .. "/flush", ROOT .. "/dkim"
    assert(okRun, result)
    return result, s
  end
  local good, s = run({ "user", "list" })
  ok(good and s.text():find("no mailboxes yet", 1, true))
  ok(run({ "user", "add", "alice", "secret-pass", "--quota", "50000" }))
  ok(run({ "user", "add", "bob" }, { "bob-secret", "bob-secret" }))
  good, s = run({ "user", "add", "carol" }, { "one-secret", "another" })
  ok(not good and s.errors[1] == "the passwords differ")
  good, s = run({ "user", "add", "alice", "again-123" })
  ok(not good and s.errors[1] == "that mailbox exists already")
  good, s = run({ "user", "add", "x", "123" })
  ok(not good and s.errors[1]:find("at least 6", 1, true))
  eq(store:authenticate("bob", "bob-secret"), "bob")
  _, s = run({ "user", "list" })
  ok(s.text():find("alice%s+0 B used of%s+48.8 KB") and s.text():find("bob", 1, true), s.text())
  ok(run({ "user", "passwd", "bob", "new-secret" }))
  eq(store:authenticate("bob", "new-secret"), "bob")
  ok(run({ "user", "quota", "bob", "999" }))
  eq(store:users().bob.quota, 999)
  ok(run({ "user", "del", "bob" }))
  ok(not store:exists("bob"))
  good, s = run({ "user", "del", "ghost" })
  ok(not good and s.errors[1] == "no such mailbox")
  -- domains, relays, aliases
  ok(run({ "domain", "add", "Mail.Example.lan" }))
  _, s = run({ "domain", "list" })
  eq(s.lines, { "mail.example.lan" })
  good, s = run({ "domain", "add", "bad name" })
  ok(not good and s.errors[1] == "that is not a domain name")
  ok(run({ "relay", "add", "10.0.0.0/24" }))
  good, s = run({ "relay", "add", "nonsense" })
  ok(not good and s.errors[1]:find("not a network", 1, true))
  ok(run({ "alias", "add", "Postmaster", "alice" }))
  ok(run({ "alias", "add", "team@example.lan", "alice", "carol@other.lan" }))
  _, s = run({ "alias", "list" })
  eq(s.lines, { "postmaster                   -> alice", "team@example.lan             -> alice, carol@other.lan" })
  ok(run({ "alias", "del", "postmaster" }))
  ok(not run({ "alias", "del", "postmaster" }))
  -- the merged settings the server runs with
  local routing = config.routing()
  eq(routing.domains, { "mail.example.lan" }) eq(routing.relay, { "10.0.0.0/24" })
  -- spam lists
  ok(run({ "spam", "deny", "add", "Spammer.lan" }))
  ok(run({ "spam", "allow", "add", "friend@x.lan" }))
  _, s = run({ "spam", "deny", "list" })
  eq(s.lines, { "spammer.lan" })
  ok(run({ "spam", "deny", "del", "spammer.lan" }))
  ok(not run({ "spam", "deny", "del", "spammer.lan" }))
  -- learning from files
  vfs.writeFile(ROOT .. "/s1.eml", msg.build({ from = "a@b.lan", to = "c@d.lan", subject = "cheap pills", body = "viagra cheap winner", host = "b.lan" }), true)
  vfs.writeFile(ROOT .. "/h1.eml", msg.build({ from = "e@f.lan", to = "c@d.lan", subject = "meeting", body = "redstone review tomorrow", host = "f.lan" }), true)
  _, s = run({ "spam", "stats" })
  ok(s.text():find("learned from 0 spam and 0 good", 1, true) and s.text():find("needs at least 3", 1, true), s.text())
  ok(run({ "spam", "learn", "spam", ROOT .. "/s1.eml", ROOT .. "/s1.eml" }))
  ok(run({ "spam", "learn", "ham", ROOT .. "/h1.eml" }))
  _, s = run({ "spam", "stats" })
  ok(s.text():find("learned from 2 spam and 1 good", 1, true), s.text())
  good, s = run({ "spam", "learn", "maybe", ROOT .. "/h1.eml" })
  ok(not good)
  -- DKIM
  _, s = run({ "dkim", "key", "mail1", "example.lan" })
  ok(s.text():find("mail1._domainkey.example.lan  TXT  \"v=DKIM1; k=ed25519; p=", 1, true) and s.text():find("keyFile", 1, true), s.text())
  local first = s.lines[3]
  good, s = run({ "dkim", "key", "mail1" })
  ok(not good and s.errors[1]:find("exists already", 1, true))
  _, s = run({ "dkim", "record", "mail1" })
  ok(first:find(s.lines[1], 1, true), first)
  -- DNS help and status
  _, s = run({ "dns" })
  ok(s.text():find("MX    10 mail.example.lan.", 1, true) and s.text():find("v=spf1 mx -all", 1, true) and s.text():find("_dmarc.example.lan.", 1, true), s.text())
  _, s = run({ "status" })
  ok(s.text():find("mailboxes:   1", 1, true) and s.text():find("queue:       0 message(s) waiting", 1, true), s.text())
  -- the queue
  vfs.mkdirp(ROOT .. "/queue")
  vfs.writeTable(ROOT .. "/queue/abc123.meta", { id = "abc123", sender = "a@example.lan", rcpts = { { addr = "x@y.lan", tries = 1 } }, created = 5, tries = 1, last = "451 try later" })
  vfs.writeFile(ROOT .. "/queue/abc123.eml", "Subject: q\r\n\r\nbody", true)
  _, s = run({ "queue" })
  ok(s.text():find("abc123", 1, true) and s.text():find("x@y.lan", 1, true) and s.text():find("451 try later", 1, true), s.text())
  _, s = run({ "queue", "show", "abc123" })
  ok(s.text():find("Subject: q", 1, true))
  ok(run({ "queue", "flush" }))
  ok(vfs.fs.exists(ROOT .. "/flush"))
  ok(run({ "queue", "delete", "abc123" }))
  _, s = run({ "queue" })
  eq(s.lines, { "the queue is empty" })
  good, s = run({ "queue", "delete", "abc123" })
  ok(not good)
  good, s = run({ "wat" })
  ok(not good and s.errors[1]:find("usage: mailctl", 1, true))
  config.ROUTING, config.FLUSH, config.DKIM_DIR = savedRouting, savedFlush, savedDkim
end)

test("settings files: the template is valid and merges with the routing data", function()
  clean()
  local saved = { config.STATIC, config.ROUTING }
  config.STATIC, config.ROUTING = ROOT .. "/mail.lua", ROOT .. "/routing.db"
  ok(config.writeTemplate("mail.example.lan", nil))
  ok(not config.writeTemplate("other.lan", "x.lan"), "an existing file is not overwritten")
  ok(config.writeTemplate("mail.example.lan", "example.lan", true))
  local cfg = assert(config.load())
  eq(cfg.hostname, "mail.example.lan") eq(cfg.domains, { "example.lan" })
  eq(cfg.spam.spamAt, 5) eq(cfg.pop3, true) eq(cfg.allowPlainAuth, false)
  ok(cfg.tls == nil, "TLS stays off until the player makes a certificate")
  config.saveRouting({ domains = { "Second.lan", "example.lan" }, relay = { "10.0.0.0/24" }, aliases = { postmaster = { "alice" } }, allow = { "friend.lan" }, deny = { "bad.lan" } })
  cfg = assert(config.load())
  eq(cfg.domains, { "example.lan", "Second.lan" }, "no duplicates, file first")
  eq(cfg.relayNetworks, { "10.0.0.0/24" }) eq(cfg.aliases.postmaster, { "alice" })
  eq(cfg.spam.allow, { "friend.lan" }) eq(cfg.spam.deny, { "bad.lan" })
  local d, r, a = config.liveRouting()
  eq(#d, 2) eq(#r, 1) ok(a.postmaster)
  -- a broken settings file is reported
  vfs.writeFile(config.STATIC, "return {")
  local none, err = config.load()
  ok(none == nil and err:find("mail.lua", 1, true), tostring(err))
  vfs.writeFile(config.STATIC, "return 5")
  ok(select(2, config.load()):find("must return a table", 1, true))
  config.STATIC, config.ROUTING = saved[1], saved[2]
  -- the server module loads
  ok(require("tsr.mail.daemon").main)
end)
