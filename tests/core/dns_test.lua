-- SPDX-License-Identifier: AGPL-3.0-or-later
local net = require("tsr.net")
local zone = require("tsr.dns.zone")
local resolver = require("tsr.dns.resolver")
local server = require("tsr.dns.server")
local cli = require("tsr.dns.cli")
local vfs = require("tsr.vfs")
local netbus = dofile("/tests/lib/netbus.lua")

local DIR = "/tmp-dns"

local function reset()
  if fs.exists(DIR) then fs.delete(DIR) end
  fs.makeDir(DIR)
  resolver.HOSTS = DIR .. "/hosts"
  resolver.CONFIG = DIR .. "/dns.cfg"
  server.ZONES = DIR .. "/zones"
  resolver.flush()
end

test("names are normalised, zone files parse, mistakes are reported with their line", function()
  eq(zone.normalize("Farm1."), "farm1")
  eq(zone.normalize("farm1", "base"), "farm1.base")
  eq(zone.normalize("a.b.c", "base"), "a.b.c.base")
  eq(zone.normalize("a.b.c.", "base"), "a.b.c", "a trailing dot makes a name absolute")
  eq(zone.normalize("x.base", "base"), "x.base")
  eq(zone.normalize("@", "base"), "base")
  ok(zone.normalize("bad name") == nil)
  ok(zone.normalize("a..b") == nil)
  ok(zone.normalize(".x") == nil)
  local z, problems = zone.parse([[
; a zone
$origin Base
$ttl 120
farm1    A      14
gate     A      9 30
www      CNAME  farm1
note.farm1 TXT  "main entrance"
@        NS     3
bad      A      xyz
what     MX     5
$weird   x
]])
  eq(z.origin, "base")
  eq(#z.records, 5)
  eq(z.records[1], { name = "farm1.base", type = "A", value = 14, ttl = 120 })
  eq(z.records[2].ttl, 30, "an explicit time to live")
  eq(z.records[3], { name = "www.base", type = "CNAME", value = "farm1.base", ttl = 120 })
  eq(z.records[4].value, "main entrance")
  eq(z.records[5], { name = "base", type = "NS", value = 3, ttl = 120 })
  eq(#problems, 3)
  ok(problems[1]:find("line 9", 1, true), problems[1])
  ok(zone.format({ z.records[1], z.records[4] }):find('farm1.base A 14\nnote.farm1.base TXT "main entrance"', 1, true))
end)

test("the hosts file always wins and needs no network", function()
  reset()
  vfs.writeFile(resolver.HOSTS, "# my machines\n7 alpha a\n8 Beta\n")
  local bus = netbus.new()
  local node = net.node({ id = 1, hostname = "me", transport = bus:transport(1), peersPath = DIR .. "/p" })
  local answers = resolver.query(node, "alpha", "A")
  eq(answers[1].value, 7)
  eq(answers.source, "hosts")
  eq(resolver.lookup(node, "a"), 7)
  eq(resolver.lookup(node, "beta"), 8)
  eq(resolver.lookup(node, "nowhere"), nil)
  -- the net layer finds hosts too
  eq(node:resolve("alpha", 0.1), 7)
end)

local function withServer(zoneText, fn, cfgExtra)
  reset()
  fs.makeDir(server.ZONES)
  vfs.writeFile(server.ZONES .. "/base.zone", zoneText)
  local bus = netbus.new()
  local ns = net.node({ id = 3, hostname = "ns1", transport = bus:transport(3), peersPath = DIR .. "/ns.peers" })
  local client = net.node({ id = 22, hostname = "client", transport = bus:transport(22), peersPath = DIR .. "/c.peers" })
  local cfg = { serve = true, dynamic = { "base" }, ttl = 600 }
  for k, v in pairs(cfgExtra or {}) do cfg[k] = v end
  vfs.writeTable(resolver.CONFIG, { servers = { 3 }, search = { "base" }, timeout = 1 })
  local db = server.serve(ns, server.new():load(), cfg)
  local failure
  parallel.waitForAny(
    function() ns:run() end, function() client:run() end,
    function()
      local okRun, err = pcall(fn, ns, client, db, bus)
      if not okRun then failure = err end
    end)
  if failure then error(failure, 0) end
end

test("a name server answers questions; search suffixes, aliases, caching and negative answers work", function()
  withServer("$origin base\nfarm1 A 14\ngate A 9\nwww CNAME farm1\nnote.farm1 TXT \"hello\"\n", function(ns, client, db, bus)
    local answers, err = resolver.query(client, "farm1.base", "A")
    ok(answers, err)
    eq(answers[1].value, 14)
    eq(answers.source, "3")
    eq(resolver.lookup(client, "farm1"), 14, "the search suffix is added")
    eq(resolver.lookup(client, "www"), 14, "an alias is followed")
    local txt = resolver.query(client, "note.farm1.base", "TXT")
    eq(txt[1].value, "hello")
    -- cached: the second answer needs no packet
    local before = #bus.log
    resolver.query(client, "farm1.base", "A")
    eq(#bus.log, before, "answered from the cache")
    eq(resolver.query(client, "farm1.base", "A").source, "cache")
    -- unknown names: none, remembered for a short while
    local none = resolver.query(client, "ghost.base", "A")
    ok(none == nil or #none == 0)
    before = #bus.log
    resolver.query(client, "ghost.base", "A")
    eq(#bus.log, before, "a negative answer is cached too")
    -- the node's own resolve() uses the name service
    eq(client:resolve("gate", 0.5), 9)
    -- nobody home: a dead name server does not hang the lookup
    vfs.writeTable(resolver.CONFIG, { servers = { 99 }, timeout = 0.3 })
    resolver.flush()
    local dead, derr = resolver.query(client, "farm1.base", "A")
    ok(dead == nil and derr:find("name server", 1, true), tostring(derr))
  end)
end)

test("computers register themselves; only paired ones, only for themselves, only in allowed zones; records expire", function()
  withServer("$origin base\nfixed A 1\n", function(ns, client, db, bus)
    parallel.waitForAll(
      function() ok(ns:pairListen({ code = "ABCDE-FGHJK", timeout = 10 })) end,
      function() sleep(0.2) ok(client:pairConnect(3, "ABCDE-FGHJK", 5)) end)
    local res, err = client:call(3, "dns", "register", { name = "mine.base" })
    ok(res, err)
    eq(res.id, 22)
    eq(resolver.lookup(client, "mine"), 22)
    local refused, rerr = client:call(3, "dns", "register", { name = "mine.elsewhere" })
    ok(refused == nil and rerr:find("does not accept", 1, true), tostring(rerr))
    ok(select(2, client:call(3, "dns", "register", { name = "bad name" })))
    -- a static name cannot be taken over, and a dynamic one belongs to its registrant
    local answers = db:answer("mine.base", "A")
    eq(answers[1].value, 22)
    local t = 1000
    db.clock = function() return t end
    ok(db:register("temp.base", 22, 100))
    eq(#db:answer("temp.base", "A"), 1)
    t = 1200
    eq(#db:answer("temp.base", "A"), 0, "the registration expired")
    local removed = client:call(3, "dns", "unregister", { name = "mine.base" })
    eq(removed.removed, 1)
  end)
end)

local function io()
  local t = { lines = {}, errs = {} }
  function t.say(s) t.lines[#t.lines + 1] = s end
  function t.err(s) t.errs[#t.errs + 1] = s end
  function t.text() return table.concat(t.lines, "\n") end
  return t
end

test("the host, dig and dns commands", function()
  withServer("$origin base\nfarm1 A 14\nwww CNAME farm1\n", function(ns, client, db, bus)
    local o = io()
    ok(cli.host({ "farm1" }, o, client), table.concat(o.errs, "|"))
    ok(o.text():find("farm1.base has address (computer) 14", 1, true), o.text())
    o = io()
    ok(cli.dig({ "www.base" }, o, client))
    ok(o.text():find("CNAME", 1, true) == nil and o.text():find("farm1.base", 1, true), "an alias is followed to its address: " .. o.text())
    o = io()
    ok(not cli.host({ "ghost" }, o, client))
    -- administration
    o = io()
    ok(cli.dns({ "hosts", "add", "5", "printer" }, o, client))
    ok(o.text():find("5 printer", 1, true))
    eq(resolver.lookup(client, "printer"), 5)
    ok(cli.dns({ "hosts", "del", "printer" }, io(), client))
    eq(resolver.lookup(client, "printer"), nil)
    ok(cli.dns({ "zone", "add", "newhost", "A", "77" }, io(), client))
    o = io()
    cli.dns({ "zone" }, o, client)
    ok(o.text():find("newhost", 1, true) and o.text():find("77", 1, true), o.text())
    ok(not cli.dns({ "zone", "add", "bad name", "A", "1" }, io(), client))
    ok(cli.dns({ "zone", "del", "newhost" }, io(), client))
    ok(cli.dns({ "servers", "add", "8" }, io(), client))
    o = io()
    cli.dns({ "servers" }, o, client)
    ok(o.text():find("8", 1, true))
    ok(cli.dns({ "servers", "del", "8" }, io(), client))
    ok(cli.dns({ "register", "me.base", "3" }, io(), client))
    eq(resolver.config().register, { name = "me.base", server = 3 })
    ok(cli.dns({ "serve", "on" }, io(), client))
    ok(resolver.config().serve)
    o = io()
    ok(cli.dns({ "status" }, o, client))
    ok(o.text():find("name servers:", 1, true))
    ok(cli.dns({ "flush" }, io(), client))
  end)
end)
