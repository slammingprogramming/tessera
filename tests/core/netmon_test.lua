-- SPDX-License-Identifier: AGPL-3.0-or-later
local net = require("tsr.net")
local fw = require("tsr.fw")
local netmon = require("tsr.netmon")
local cli = require("tsr.netmon.cli")
local vfs = require("tsr.vfs")
local netbus = dofile("/tests/lib/netbus.lua")

local DIR = "/tmp/netmon-test"

local function reset()
  if fs.exists(DIR) then fs.delete(DIR) end
  vfs.mkdirp(DIR)
end

local function withNodes(fn, rules)
  local bus = netbus.new()
  local a = net.node({ id = 11, hostname = "alpha", transport = bus:transport(11), peersPath = DIR .. "/a.peers" })
  local b = net.node({ id = 22, hostname = "beta", transport = bus:transport(22), peersPath = DIR .. "/b.peers" })
  if rules then fw.install(a, (fw.parse(rules)), {}) end
  local failure
  parallel.waitForAny(function() a:run() end, function() b:run() end, function()
    local ok_, err = pcall(fn, a, b)
    if not ok_ then failure = err end
  end)
  if failure then error(failure, 0) end
end

test("classify: kind and protection of every message family", function()
  eq({ netmon.classify({ t = "ping" }) }, { "ping", "plain" })
  eq({ netmon.classify({ t = "ssh", k = "hello" }) }, { "ssh/hello", "public handshake" })
  eq({ netmon.classify({ t = "ssh", k = "rec" }) }, { "ssh/rec", "encrypted" })
  eq({ netmon.classify({ t = "rpc", enc = true }) }, { "rpc", "encrypted" })
  eq({ netmon.classify({ t = "rpc", enc = false }) }, { "rpc", "signed" })
  eq({ netmon.classify({ t = "p2p", k = "find" }) }, { "p2p/find", "plain (hash-checked)" })
  eq({ netmon.classify({ t = "pair.1" }) }, { "pair.1", "code-protected" })
  eq({ netmon.classify("hello") }, { "text", "plain" })
  eq({ netmon.classify({}) }, { "other", "plain" })
end)

test("a monitor on a node sees what is sent, what arrives and what the firewall refuses", function()
  reset()
  withNodes(function(a, b)
    local mon = netmon.attach(a, { limit = 50 })
    ok(b:ping(11, 1), "alpha answers beta's ping")
    ok(a:ping(22, 1), "and beta answers alpha")
    ok(b:time(11, 0.3) == nil, "time queries are refused by alpha's firewall")
    mon:stop()
    local seen = {}
    for _, r in ipairs(mon.records) do seen[#seen + 1] = r.dir .. ":" .. r.kind end
    local function has(x) for _, s in ipairs(seen) do if s == x then return true end end return false end
    ok(has("in:ping") and has("out:ping.r") and has("out:ping") and has("in:ping.r"), table.concat(seen, " "))
    ok(has("drop:time.q"), table.concat(seen, " "))
    eq(mon.dropped, 1)
    ok(mon.kinds.ping.packets >= 2)
    eq(mon.peers[22].drops, 1)
    local n = #mon.records
    b:ping(11, 1)
    eq(#mon.records, n, "a stopped monitor records nothing")
  end, "default deny\nallow type ping from any\n")
end)

test("filters: by type, peer, direction, only refused; the ring buffer keeps the newest", function()
  local mon = netmon.new({ limit = 3, filter = { types = { ssh = true } } })
  mon:record("in", 5, 11, { t = "ssh", k = "rec" })
  mon:record("in", 5, 11, { t = "ping" })
  mon:record("in", 6, 11, { t = "ssh", k = "hello" })
  eq(#mon.records, 2, "ping filtered out; the type filter takes the part before the slash")
  eq(mon.total, 3, "but the totals count everything")
  local m2 = netmon.new({ limit = 2 })
  for i = 1, 5 do m2:record("in", i, 11, { t = "ping" }) end
  eq(#m2.records, 2) eq(m2.records[1].peer, 4)
  local m3 = netmon.new({ filter = { dropsOnly = true } })
  m3:record("in", 1, 2, { t = "x" }) m3:record("drop", 1, 2, { t = "x" })
  eq(#m3.records, 1)
  local m4 = netmon.new({ filter = { peers = { [9] = true } } })
  m4:record("in", 1, 2, { t = "x" }) m4:record("in", 9, 2, { t = "x" })
  eq(#m4.records, 1)
end)

test("sniffer decoding: rednet envelopes of our protocol and others; non-modem events ignored", function()
  local mon = netmon.new({})
  local r = mon:event({ "modem_message", "top", 22, 11, { nMessageID = 1, nRecipient = 22, sProtocol = "tsr.net", message = { t = "ssh", k = "rec", d = "xxxx" } }, 5 })
  eq(r.kind, "ssh/rec") eq(r.protection, "encrypted") eq(r.peer, 11) eq(r.to, 22) eq(r.dir, "sniff")
  local r2 = mon:event({ "modem_message", "top", 22, 11, { nMessageID = 2, nRecipient = 22, sProtocol = "chat", message = "secret text" }, 5 })
  eq(r2.kind, "rednet:chat")
  local r3 = mon:event({ "modem_message", "top", 7, 8, "just a string", 1 })
  eq(r3.kind, "text")
  eq(mon:event({ "timer", 4 }), nil)
  eq(mon.total, 3)
  ok(netmon.format(r, 0):find("11->22", 1, true))
end)

test("save and load a capture; the summary lists kinds and computers", function()
  reset()
  local mon = netmon.new({ clock = function() return 1.5 end })
  mon:record("out", 11, 22, { t = "ping" })
  mon:record("drop", 33, 11, { t = "time.q" })
  mon:record("in", 22, 11, { t = "rpc", enc = true })
  ok(mon:save(DIR .. "/cap.txt"))
  local back = assert(netmon.load(DIR .. "/cap.txt"))
  eq(#back.records, 3)
  eq(back.records[2].dir, "drop") eq(back.records[2].peer, 33) eq(back.records[3].protection, "encrypted")
  local text = table.concat(mon:summary(), "\n")
  ok(text:find("3 message(s) seen, 1 refused", 1, true) and text:find("computer 22", 1, true), text)
  ok(netmon.load(DIR .. "/missing") == nil)
  vfs.writeFile(DIR .. "/bad.txt", "not a capture\n")
  ok(netmon.load(DIR .. "/bad.txt") == nil)
end)

test("the command: watch a node for a while, save, read back, refuse bad options", function()
  reset()
  local said, errs = {}, {}
  local script = {}
  local io = {
    say = function(t) said[#said + 1] = t end, err = function(t) errs[#errs + 1] = t end,
    pull = function(timeout)
      local step = table.remove(script, 1)
      if step then step() end
      return nil
    end,
  }
  withNodes(function(a, b)
    script = { function() b:ping(11, 1) end }
    ok(cli.run({ "--count", "1", "--save", DIR .. "/run.txt" }, io, a), table.concat(errs, "|"))
    local all = table.concat(said, "\n")
    ok(all:find("ping", 1, true) and all:find("message(s) seen", 1, true) and all:find("Capture saved", 1, true), all)
  end)
  said = {}
  ok(cli.run({ "read", DIR .. "/run.txt" }, io))
  ok(table.concat(said, "\n"):find("ping", 1, true))
  ok(not cli.run({ "--wrong" }, io))
  ok(not cli.run({ "read" }, io))
  ok(not cli.run({ "sniff", "5-500" }, io))
  ok(not cli.run({ "sniff", "abc" }, io))
end)
