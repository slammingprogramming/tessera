-- SPDX-License-Identifier: AGPL-3.0-or-later
local msg = require("tsr.mail.message")
local storeMod = require("tsr.mail.store")
local mailMod = require("tsr.mail")
local pop3d = require("tsr.mail.pop3d")
local pop3 = require("tsr.mail.pop3")
local vfs = require("tsr.vfs")
local Sim = dofile("/tests/lib/inetsim.lua")

local ROOT = "/tmp/pop3-test"

local function setup(cfg)
  if vfs.fs.exists(ROOT) then vfs.fs.delete(ROOT) end
  vfs.fs.makeDir(ROOT)
  local sim = Sim.new()
  local seg = sim:segment("lan")
  local h = sim:host("mx1")
  sim:plug(h, "eth0", seg, "10.0.0.1/24")
  local pc = sim:host("pc")
  sim:plug(pc, "eth0", seg, "10.0.0.9/24")
  cfg = cfg or {}
  cfg.hostname = "mx1.lan"
  cfg.root, cfg.users, cfg.queueDir = ROOT .. "/mb", ROOT .. "/users.db", ROOT .. "/queue"
  cfg.domains = { "example.lan" }
  cfg.now = function() return 1000000 + sim.now end
  if cfg.allowPlainAuth == nil then cfg.allowPlainAuth = true end
  local st = storeMod.new({ root = cfg.root, users = cfg.users, iterations = 3 })
  assert(st:addUser("alice", "password-alice"))
  assert(st:addUser("bob", "password-bob"))
  local m = mailMod.new(h, cfg, st)
  return sim, m, pc
end

local function deliver(m, to, subject, body)
  return assert(m.store:deliver(to, msg.build({ from = "bob@y.lan", to = to .. "@example.lan", subject = subject, body = body, host = "y.lan" })))
end

test("POP3 session: commands, states, deletion on QUIT, locks", function()
  local sim, m = setup()
  deliver(m, "alice", "First", "one\n.starts with a dot\nlast")
  deliver(m, "alice", "Second", "two")
  deliver(m, "alice", "Third", "three")
  local s = pop3d.session(m, "10.0.0.9")
  eq(s:greeting(), "+OK mx1.lan POP3 server ready")
  local r, a, body = s:line("CAPA")
  eq(r, "+OK Capability list follows") ok(#body >= 5 and table.concat(body, ","):find("UIDL", 1, true))
  eq((s:line("STAT")), "-ERR not allowed before login")
  eq((s:line("PASS secret")), "-ERR send USER first")
  eq((s:line("USER alice")), "+OK send PASS")
  eq((s:line("PASS wrong")), "-ERR [AUTH] Invalid user name or password")
  s:line("USER alice")
  local login = s:line("PASS password-alice")
  ok(login:find("^%+OK alice has 3 messages %(%d+ octets%)$"), login)
  eq((s:line("USER bob")), "-ERR unknown command")
  local stat = s:line("STAT")
  ok(stat:find("^%+OK 3 %d+$"), stat)
  r, _, body = s:line("LIST")
  eq(r, "+OK 3 messages") eq(#body, 3) ok(body[1]:find("^1 %d+$"))
  r = s:line("LIST 2")
  ok(r:find("^%+OK 2 %d+$"))
  eq((s:line("LIST 9")), "-ERR no such message")
  r, _, body = s:line("UIDL")
  eq(body, { "1 1", "2 2", "3 3" })
  r, _, body = s:line("RETR 1")
  ok(r:find("^%+OK %d+ octets$")) eq(body[#body], "last") ok(table.concat(body, "\n"):find("\n.starts with a dot\n", 1, true))
  -- TOP: headers and the first body lines
  r, _, body = s:line("TOP 1 1")
  eq(body[#body], "one") ok(body[1]:find("^From:") or body[1]:find("^Date:") or body[1]:find("^To:"))
  r, _, body = s:line("TOP 1 0")
  eq(body[#body], "")
  eq((s:line("TOP 1")), "-ERR syntax: TOP n lines")
  eq((s:line("RETR")), "-ERR syntax: RETR n")
  -- deleting: nothing happens until QUIT
  eq((s:line("DELE 2")), "+OK message 2 deleted")
  eq((s:line("DELE 2")), "-ERR message 2 deleted")
  eq((s:line("RETR 2")), "-ERR message 2 deleted")
  ok(s:line("STAT"):find("^%+OK 2 "))
  eq(#m.store:list("alice"), 3)
  eq((s:line("RSET")), "+OK")
  ok(s:line("STAT"):find("^%+OK 3 "))
  s:line("DELE 3")
  -- the mailbox is locked while the session is open
  local other = pop3d.session(m, "10.0.0.9")
  other:line("USER alice")
  eq((other:line("PASS password-alice")), "-ERR [IN-USE] The mailbox is in use by another session")
  local r2, act = s:line("QUIT")
  eq(r2, "+OK 1 message(s) deleted; bye") eq(act, "close")
  local left = m.store:list("alice")
  eq(#left, 2) eq(left[1].subject, "First") eq(left[2].subject, "Second")
  ok(left[1].flags:find("S", 1, true), "RETR marks the message as seen")
  -- the lock is gone
  local again = pop3d.session(m, "10.0.0.9")
  again:line("USER alice")
  ok(again:line("PASS password-alice"):find("^%+OK"))
  -- QUIT before login or without deletes changes nothing
  local q = pop3d.session(m, "10.0.0.9")
  eq((q:line("QUIT")), "+OK bye")
  again:line("QUIT")
  eq(#m.store:list("alice"), 2)
  -- unknown commands count as errors and end the session eventually
  local bad = pop3d.session(m, "10.0.0.10")
  local act2
  for _ = 1, 8 do _, act2 = bad:line("FROB") end
  eq(act2, "close")
end)

test("POP3: plain passwords need encryption, lockout after failures", function()
  local sim, m = setup({ allowPlainAuth = false })
  local s = pop3d.session(m, "10.0.0.9")
  eq((s:line("USER alice")), "-ERR [AUTH] Encryption required to log in")
  local t = pop3d.session(m, "10.0.0.9", { secure = true })
  eq((t:line("USER alice")), "+OK send PASS")
  ok(t:line("PASS password-alice"):find("^%+OK"))
  t:line("QUIT")
  m.cfg.allowPlainAuth = true
  for _ = 1, 5 do
    local u = pop3d.session(m, "10.0.0.50")
    u:line("USER alice")
    eq((u:line("PASS nope")), "-ERR [AUTH] Invalid user name or password")
  end
  local locked = pop3d.session(m, "10.0.0.50")
  locked:line("USER alice")
  local r, act = locked:line("PASS password-alice")
  eq(r, "-ERR [SYS/TEMP] Too many failed logins; try again later") eq(act, "close")
  -- another address is not affected
  local fine = pop3d.session(m, "10.0.0.51")
  fine:line("USER alice")
  ok(fine:line("PASS password-alice"):find("^%+OK"))
  fine:line("QUIT")
end)

test("POP3 over the network: the client fetches and deletes", function()
  local sim, m, pc = setup()
  local text = "first line\n.\n..two dots\n\nlast"
  deliver(m, "alice", "Hello", text)
  deliver(m, "alice", "Again", "two")
  deliver(m, "bob", "Bobs mail", "for bob")
  for _, job in ipairs(assert(pop3d.workers(m, 2))) do local t = sim:spawn(job) t.daemon = true end
  sim:run(0.2)
  -- a wrong password
  local c, err = pop3.connect(pc, "10.0.0.1", { user = "alice", pass = "nope" })
  ok(c == nil and err:find("login refused", 1, true), tostring(err))
  -- interactive use
  c = assert(pop3.connect(pc, "10.0.0.1", { user = "alice", pass = "password-alice" }))
  local n, bytes = c:stat()
  eq(n, 2) ok(bytes > 200)
  local list = c:list()
  eq(#list, 2) eq(list[1].n, 1)
  local uids = c:list(true)
  eq({ uids[1].uid, uids[2].uid }, { "1", "2" })
  local raw = assert(c:retr(1))
  eq(msg.parse(raw):subject(), "Hello")
  eq(msg.parse(raw):text(), text .. "\n", "dot-stuffing survives the trip")
  local head = assert(c:top(1, 0))
  ok(head:find("Subject: Hello", 1, true) and not head:find("first line", 1, true))
  ok(c:dele(2))
  ok(c:quit())
  eq(#m.store:list("alice"), 1)
  -- fetch everything, and remove it from the server
  deliver(m, "alice", "Third", "three")
  local all = assert(pop3.fetch(pc, "10.0.0.1", { user = "alice", pass = "password-alice", delete = true }))
  eq(#all, 2) eq(msg.parse(all[2].raw):subject(), "Third")
  eq(#m.store:list("alice"), 0)
  eq(#m.store:list("bob"), 1, "other mailboxes are untouched")
  -- an empty mailbox
  local none = assert(pop3.fetch(pc, "10.0.0.1", { user = "alice", pass = "password-alice" }))
  eq(#none, 0)
  -- skipping what was seen before (by UIDL)
  local again = assert(pop3.fetch(pc, "10.0.0.1", { user = "bob", pass = "password-bob", skip = { ["1"] = true } }))
  eq(#again, 0)
  -- the server being down
  pop3d.stop(m)
  local down, why = pop3.connect(pc, "10.0.0.7", { user = "alice", pass = "x", timeout = 2 })
  ok(down == nil and why:find("cannot connect", 1, true), tostring(why))
end)
