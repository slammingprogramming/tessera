-- SPDX-License-Identifier: AGPL-3.0-or-later
local net = require("tsr.net")
local fw = require("tsr.fw")
local fwcli = require("tsr.fwcli")
local vfs = require("tsr.vfs")
local netbus = dofile("/tests/lib/netbus.lua")

local DIR = "/tmp-fw"

local function reset()
  if fs.exists(DIR) then fs.delete(DIR) end
  fs.makeDir(DIR)
  fw.RULES = DIR .. "/rules"
end

test("rules parse: allow, deny, limit, default, lists, comments, mistakes", function()
  local set, problems = fw.parse("# comment\ndefault deny\nallow type ping,disco.q from any\ndeny from 15\n" ..
    "limit 20/min type p2p from paired\nallow type ssh from 11,alpha\nbogus rule\nlimit lots type x\nallow type\n")
  eq(set.default, "deny")
  eq(#set.list, 4)
  eq(set.list[1].types, { "ping", "disco.q" })
  eq(set.list[2].from, { "15" })
  eq({ set.list[3].rate, set.list[3].period }, { 20, 60 })
  eq(set.list[4].from, { "11", "alpha" })
  eq(#problems, 3)
  ok(problems[1]:find("line 7", 1, true) and problems[1]:find("unknown rule", 1, true), problems[1])
  eq(fw.parseLine("   # nothing"), false)
  eq(fw.parseLine("default maybe"), nil)
end)

local function withNodes(rulesText, fn)
  local bus = netbus.new()
  local s = net.node({ id = 11, hostname = "alpha", transport = bus:transport(11), peersPath = DIR .. "/s.peers" })
  local c = net.node({ id = 22, hostname = "beta", transport = bus:transport(22), peersPath = DIR .. "/c.peers" })
  local other = net.node({ id = 33, hostname = "gamma", transport = bus:transport(33), peersPath = DIR .. "/o.peers" })
  local clock = 0
  local state = fw.install(s, (fw.parse(rulesText)), { clock = function() return clock end })
  local failure
  parallel.waitForAny(
    function() s:run() end, function() c:run() end, function() other:run() end,
    function()
      local okRun, err = pcall(fn, s, c, other, state, function(t) clock = t end)
      if not okRun then failure = err end
    end)
  if failure then error(failure, 0) end
end

test("the filter drops by sender and type; replies to our own requests always get through", function()
  reset()
  withNodes("default deny\nallow type ping from 22\n", function(s, c, other, state)
    ok(c:ping(11, 1), "allowed sender and type")
    ok(not other:ping(11, 0.5), "another computer is not on the list")
    ok(s:ping(22, 1), "our own ping is answered: the reply is expected")
    eq(c:time(11, 0.5), nil, "time queries are not allowed")
    ok(state.denied >= 2)
    eq(state.recent[1].rule, "default")
  end)
end)

test("explicit deny wins by order, first match decides", function()
  reset()
  withNodes("deny from 33\nallow type ping from any\ndefault deny\n", function(s, c, other, state)
    ok(c:ping(11, 1))
    ok(not other:ping(11, 0.5))
    eq(state.hits[1], 1, "the deny rule caught computer 33")
    eq(state.hits[2], 1)
  end)
end)

test("rate limits count per sender and per period", function()
  reset()
  withNodes("limit 3/min type ping from any\nallow type ping from any\n", function(s, c, other, state, setClock)
    local answered = 0
    for _ = 1, 5 do
      if c:ping(11, 0.4) then answered = answered + 1 end
    end
    eq(answered, 3, "only three pings per minute")
    ok(other:ping(11, 1), "another sender has its own allowance")
    setClock(120)
    ok(c:ping(11, 1), "a new minute starts")
  end)
end)

test("responses are only exempt when something was sent to that computer", function()
  reset()
  local state = fw.new((fw.parse("default deny\n")), { clock = function() return 100 end })
  local node = { contacted = { [22] = 95 }, broadcastAt = nil }
  ok(fw.decide(state, node, 22, { t = "ping.r" }), "a reply from a computer we contacted 5 s ago")
  ok(not fw.decide(state, node, 33, { t = "ping.r" }), "an unsolicited reply from a stranger")
  ok(not fw.decide(state, node, 22, { t = "ping" }), "a REQUEST from a contacted computer is still filtered")
  node.broadcastAt = 99
  ok(fw.decide(state, node, 44, { t = "disco.r" }), "answers to our broadcast")
  node.broadcastAt = 90
  ok(not fw.decide(state, node, 44, { t = "disco.r" }), "but only for a few seconds")
  ok(fw.decide(state, { contacted = { [5] = 99 } }, 5, { t = "ssh", k = "rep" }), "ssh replies")
  ok(not fw.decide(state, { contacted = { [5] = 99 } }, 5, { t = "ssh", k = "hello" }), "an ssh hello is a request")
  ok(not fw.decide(state, node, 1, "garbage"))
  local s2 = fw.new((fw.parse("allow type p2p.find from any\ndefault deny\n")))
  ok(fw.decide(s2, {}, 1, { t = "p2p", k = "find" }))
  ok(not fw.decide(s2, {}, 1, { t = "p2p", k = "req" }))
end)

local function io()
  local t = { lines = {}, errs = {} }
  function t.say(s) t.lines[#t.lines + 1] = s end
  function t.err(s) t.errs[#t.errs + 1] = s end
  function t.text() return table.concat(t.lines, "\n") end
  return t
end

test("the fw command: add, list, del, default, preset, test, status", function()
  reset()
  local o = io()
  ok(fwcli.run({ "add", "allow", "type", "ssh", "from", "paired" }, o, {}))
  ok(fwcli.run({ "add", "deny", "from", "15" }, o, {}))
  ok(not fwcli.run({ "add", "frobnicate" }, o, {}))
  o = io()
  fwcli.run({ "list" }, o, {})
  eq(o.lines, { " 1  allow type ssh from paired", " 2  deny from 15" })
  ok(fwcli.run({ "default", "deny" }, io(), {}))
  ok(vfs.readFile(fw.RULES):find("default deny", 1, true))
  o = io()
  ok(fwcli.run({ "test", "15", "ssh" }, o, {}))
  ok(o.text():find("DROPPED", 1, true), o.text())
  o = io()
  ok(fwcli.run({ "test", "99", "p2p.find" }, o, {}))
  ok(o.text():find("DROPPED", 1, true) and o.text():find("default", 1, true), o.text())
  ok(fwcli.run({ "del", "2" }, io(), {}))
  o = io()
  fwcli.run({ "list" }, o, {})
  eq(#o.lines, 1)
  ok(not fwcli.run({ "del", "9" }, io(), {}))
  ok(fwcli.run({ "preset", "lockdown" }, io(), {}))
  ok(vfs.readFile(fw.RULES):find("allow from paired", 1, true))
  ok(not fwcli.run({ "preset", "nonsense" }, io(), {}))
  o = io()
  ok(fwcli.run({ "status" }, o, {}))
  ok(o.text():find("firewall: off", 1, true) and o.text():find("default policy: deny", 1, true), o.text())
  local bus = netbus.new()
  local node = net.node({ id = 1, hostname = "n", transport = bus:transport(1), peersPath = DIR .. "/n.peers" })
  fw.install(node)
  node.firewall(node, 7, { t = "ssh" })
  o = io()
  ok(fwcli.run({ "status" }, o, node))
  ok(o.text():find("firewall: ON", 1, true) and o.text():find("dropped 1", 1, true), o.text())
  o = io()
  fwcli.run({ "log" }, o, node)
  ok(o.text():find("computer 7", 1, true), o.text())
end)
