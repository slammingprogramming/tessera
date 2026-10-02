-- SPDX-License-Identifier: AGPL-3.0-or-later
local net = require("tsr.net")
local ntp = require("tsr.ntp")
local proto = require("tsr.ntp.proto")
local web = require("tsr.ntp.web")
local time = require("tsr.time")
local cli = require("tsr.ntp.cli")
local vfs = require("tsr.vfs")
local netbus = dofile("/tests/lib/netbus.lua")

local DIR = "/tmp-ntp"

local function reset()
  if fs.exists(DIR) then fs.delete(DIR) end
  fs.makeDir(DIR)
  time.statePath = DIR .. "/time.json"
  ntp.CONFIG = DIR .. "/ntp.cfg"
  time.reload()
  web.reset()
  time.clock = function() return os.epoch("utc") end
end

--- Server and client nodes on an in-memory network. skew = how many ms the server's clock is ahead of the client's.
local function withNodes(skew, fn, opts)
  opts = opts or {}
  local bus = netbus.new()
  local s = net.node({ id = 11, hostname = "ntp1", transport = bus:transport(11), peersPath = DIR .. "/s.peers" })
  local c = net.node({ id = 22, hostname = "client", transport = bus:transport(22), peersPath = DIR .. "/c.peers" })
  local base = os.epoch("utc")
  local serverClock = function() return os.epoch("utc") + skew end
  proto.serve(s, { clock = serverClock, stratum = opts.stratum, refid = opts.refid, open = opts.open })
  local failure
  parallel.waitForAny(
    function() s:run() end,
    function() c:run() end,
    function()
      local okRun, err = pcall(function()
        if opts.paired then
          parallel.waitForAll(
            function() ok(s:pairListen({ code = "ABCDE-FGHJK", timeout = 10 })) end,
            function() sleep(0.2) ok(c:pairConnect(11, "ABCDE-FGHJK", 5)) end)
        end
        fn(s, c, bus)
      end)
      if not okRun then failure = err end
    end)
  if failure then error(failure, 0) end
end

test("the four timestamps give offset and delay", function()
  local s = proto.sample(1000, 6100, 6110, 1200)
  eq(s.offset, ((6100 - 1000) + (6110 - 1200)) / 2)
  eq(s.delay, (1200 - 1000) - (6110 - 6100))
  local sym = proto.sample(0, 105, 105, 10)           -- 10 ms round trip, server 100 ms ahead
  eq(sym.offset, 100)
  eq(sym.delay, 10)
end)

test("plain query: the offset to a server whose clock is 5 seconds ahead", function()
  reset()
  withNodes(5000, function(s, c)
    local r, err = proto.query(c, 11, { auth = false })
    ok(r, err)
    ok(math.abs(r.offset - 5000) < 400, "offset " .. tostring(r.offset))
    ok(r.delay >= 0 and r.delay < 1000)
    eq(r.stratum, 1)
    eq(r.authenticated, false)
    eq(r.host, "ntp1")
    local m = proto.measure(c, 11, { auth = false, samples = 3, spacing = 0.1 })
    ok(math.abs(m.offset - 5000) < 400)
  end)
end)

test("authenticated query needs pairing; the paired way is used automatically", function()
  reset()
  withNodes(-2500, function(s, c)
    local r, err = proto.query(c, 11, { auth = true })
    ok(r == nil and err:find("not paired", 1, true), tostring(err))
  end)
  withNodes(-2500, function(s, c)
    local r, err = proto.query(c, "ntp1", { })
    ok(r, err)
    eq(r.authenticated, true)
    ok(math.abs(r.offset + 2500) < 400, tostring(r.offset))
    eq(c:peer(11) ~= nil, true)
  end, { paired = true })
end)

test("a server can refuse plain queries; unsynchronised servers are rejected; floods are ignored", function()
  reset()
  withNodes(0, function(s, c)
    local r = proto.query(c, 11, { auth = false, timeout = 1 })
    eq(r, nil, "plain queries are closed")
    local r2, err = proto.query(c, 11, { auth = true })
    ok(r2, err)
  end, { paired = true, open = false })
  reset()
  withNodes(0, function(s, c)
    local m, err = proto.measure(c, 11, { auth = false, samples = 1 })
    ok(m == nil and err:find("not synchronised", 1, true), tostring(err))
  end, { stratum = function() return 16 end })
  reset()
  withNodes(0, function(s, c)
    local first = proto.query(c, 11, { auth = false })
    ok(first)
    local second = proto.query(c, 11, { auth = false, timeout = 0.4 })
    eq(second, nil, "a second query inside the minimum interval is not answered")
  end)
end)

test("web time: JSON with fractions, JSON with whole seconds, Date headers, errors", function()
  reset()
  local now = 1700000000000
  local clock = function() return now end
  -- the page answers 3 seconds ahead of our clock, after a 200 ms round trip
  local function getter(body, headers)
    return function(url)
      now = now + 200
      return body, headers
    end
  end
  local serverMs = 1700000003000
  local iso = time.iso(serverMs):gsub("Z$", ".250000+00:00")
  local s = assert(web.sample({ url = "https://example.test/a", kind = "json" }, { clock = clock, get = getter(textutils.serializeJSON({ utc_datetime = iso })) }))
  -- offset = server + delay/2 - t4 = (1700000003250) + 100 - 1700000000200
  eq(s.offset, 3150)
  eq(s.delay, 200)
  eq(s.stratum, 2)
  eq(s.host, "example.test")
  now = 1700000000000
  s = assert(web.sample({ url = "https://example.test/b", kind = "json" }, { clock = clock, get = getter(textutils.serializeJSON({ unixtime = 1700000003 })) }))
  eq(s.offset, 3400, "whole seconds count as the middle of the second")
  now = 1700000000000
  s = assert(web.sample({ url = "https://example.test/c", kind = "header" }, { clock = clock, get = getter("", { Date = "Tue, 14 Nov 2023 22:13:23 GMT" }) }))
  eq(s.offset, 3400, "Date header: whole seconds again")
  now = 1700000000000
  s = assert(web.sample({ url = "https://example.test/d", kind = "header" }, { clock = clock, get = getter("", { date = "Tue, 14 Nov 2023 22:13:23 GMT" }) }))
  ok(s)
  -- errors
  local bad, err = web.sample({ url = "https://example.test/e", kind = "json" }, { clock = clock, get = getter("not json") })
  ok(bad == nil and err:find("not JSON", 1, true), tostring(err))
  bad, err = web.sample({ url = "https://example.test/f", kind = "header" }, { clock = clock, get = getter("", {}) })
  ok(bad == nil and err:find("could not read", 1, true), tostring(err))
  bad, err = web.sample({ url = "https://example.test/g", kind = "header" }, { clock = clock, get = function() return nil, nil, "HTTP 503" end })
  ok(bad == nil and err:find("503", 1, true), tostring(err))
  -- politeness: the same URL again within ten minutes is refused
  bad, err = web.sample({ url = "https://example.test/c", kind = "header" }, { clock = clock, get = getter("", { Date = "Tue, 14 Nov 2023 22:13:23 GMT" }) })
  ok(bad == nil and err:find("polite", 1, true), tostring(err))
  ok(web.sample({ url = "https://example.test/c", kind = "header" }, { clock = clock, force = true, get = getter("", { Date = "Tue, 14 Nov 2023 22:13:23 GMT" }) }))
  eq(web.parseHttpDate("Tue, 14 Nov 2023 22:13:20 GMT"), 1700000000000)
  eq(web.parseHttpDate("garbage"), nil)
  eq(web.parseIso("2023-11-14T22:13:20Z"), 1700000000000)
  eq(web.parseIso("2023-11-14T23:13:20+01:00"), 1700000000000)
  eq(web.parseIso("2023-11-14T22:13:20.5-00:00"), 1700000000500)
end)

test("sync policy: first sync steps, small corrections slew halfway, huge ones are refused, manual mode blocks", function()
  reset()
  local host = 1000000000000
  time.clock = function() return host end
  local function setSource(offset, stratum)
    return { type = "peer", host = "x", _offset = offset, _stratum = stratum }
  end
  local originalSample = ntp.sampleSource
  ntp.sampleSource = function(src) return { offset = src._offset, delay = 20, stratum = src._stratum or 1, refid = "T" } end
  vfs.writeTable(ntp.CONFIG, { servers = { setSource(7000) } })
  local r = ntp.sync({})
  ok(r.ok, r.error)
  eq(r.how, "step")
  eq(time.offset(), 7000)
  eq(time.state().source, "x")
  -- a small difference (100 ms) is slewed by half
  vfs.writeTable(ntp.CONFIG, { servers = { setSource(7100) } })
  r = ntp.sync({})
  eq(r.how, "slew")
  eq(time.offset(), 7050)
  -- a correction of more than the panic limit is refused unless forced
  vfs.writeTable(ntp.CONFIG, { servers = { setSource(7050 + 4000000) } })
  r = ntp.sync({})
  ok(not r.ok and r.error:find("panic limit", 1, true), tostring(r.error))
  eq(time.offset(), 7050)
  r = ntp.sync({ force = true })
  ok(r.ok)
  eq(time.offset(), 7050 + 4000000)
  -- manual mode: nothing happens until auto
  time.setNow(1234567890000)
  r = ntp.sync({})
  ok(not r.ok and r.error:find("manual", 1, true))
  time.auto()
  eq(time.state().mode, "auto")
  ntp.sampleSource = originalSample
  time.reload()
end)

test("sources are tried in order: a dead peer falls back to the next one", function()
  reset()
  time.clock = function() return 2000000000000 end
  local ntp2 = dofile("/sys/lib/tsr/ntp/init.lua")
  ntp2.CONFIG = ntp.CONFIG
  local calls = {}
  ntp2.sampleSource = function(src)
    calls[#calls + 1] = src.type
    if src.type == "peer" then return nil, "no answer" end
    if src.type == "http" then return { offset = 1500, delay = 80, stratum = 2, refid = "WEB" } end
    return { offset = 0, delay = 0, stratum = 1, refid = "LOCL" }
  end
  vfs.writeTable(ntp2.CONFIG, { servers = { { type = "peer", host = "dead" }, { type = "http", url = "https://example.test", kind = "header" }, { type = "local" } } })
  local r = ntp2.sync({})
  ok(r.ok, r.error)
  eq(calls, { "peer", "http" })
  eq(r.stratum, 2)
  eq(time.offset(), 1500)
  -- when everything fails the error says why
  ntp2.sampleSource = function(src) return nil, "down" end
  r = ntp2.sync({})
  ok(not r.ok and r.error:find("dead: down", 1, true), tostring(r.error))
end)

test("sampleSource: local source and peer source over the network", function()
  reset()
  local r = ntp.sampleSource({ type = "local" })
  eq(r.offset, 0)
  eq(r.stratum, 1)
  local bad, err = ntp.sampleSource({ type = "carrier-pigeon" })
  ok(bad == nil and err:find("unknown source", 1, true))
  withNodes(1800, function(s, c)
    local got = ntp.sampleSource({ type = "peer", host = "ntp1", auth = false, samples = 2 }, { node = c })
    ok(got, "peer sample")
    ok(math.abs(got.offset - 1800) < 400, tostring(got.offset))
    eq(got.stratum, 2, "a client of a stratum 1 server is stratum 2")
  end)
end)

test("an in-game time server hands out its manual time", function()
  reset()
  withNodes(0, function(s, c)
    local fakeNow = time.timegm(1243, 5, 17, 9, 0, 0) * 1000       -- a role-play calendar
    -- the server's clock IS the manual clock; the client follows it
    local r = proto.measure(c, 11, { auth = false, samples = 1 })
    ok(r)
  end, { stratum = function() return 1 end, refid = function() return "MANU" end })
  reset()
  time.clock = function() return os.epoch("utc") end
  time.setNow(time.timegm(2031, 1, 1) * 1000)
  local stratum, refid = ntp.identity()
  eq(stratum, 1)
  eq(refid, "MANU")
  time.auto()
  time.setOffset(0, { source = "web", stratum = 2, refid = "WEB" })
  stratum, refid = ntp.identity()
  eq(stratum, 2)
  eq(refid, "WEB")
end)

local function io()
  local t = { lines = {}, errs = {} }
  function t.say(s) t.lines[#t.lines + 1] = s end
  function t.err(s) t.errs[#t.errs + 1] = s end
  function t.text() return table.concat(t.lines, "\n") end
  return t
end

test("date command: formats, UTC, manual set, in-game time", function()
  reset()
  time.clock = function() return time.timegm(2026, 10, 2, 12, 30, 5) * 1000 end
  local o = io()
  ok(cli.date({ "+%Y-%m-%d %H:%M:%S", "-u" }, o))
  eq(o.lines[1], "2026-10-02 12:30:05")
  time.setZone("Europe/Berlin")
  o = io()
  cli.date({ "+%H:%M %Z" }, o)
  eq(o.lines[1], "14:30 CEST")
  o = io()
  ok(cli.date({ "--ingame" }, o))
  ok(o.lines[1]:match("^Day %d+"))
  o = io()
  ok(cli.date({ "-s", "2027-01-01", "00:00:00" }, o))
  eq(time.state().mode, "manual")
  eq(time.format("%F %T", time.now(), "UTC"), "2026-12-31 23:00:00", "the date was read in the system zone (Berlin)")
  o = io()
  ok(not cli.date({ "-s", "next tuesday" }, o))
  ok(o.errs[1]:find("cannot read", 1, true))
end)

test("ntp command: status, tz, servers, add/remove/up, serve, set/auto", function()
  reset()
  time.clock = function() return time.timegm(2026, 10, 2, 12, 30, 5) * 1000 end
  local o = io()
  ok(cli.ntp({ "status" }, o))
  ok(o.text():find("Local time:", 1, true) and o.text():find("Sources:         1", 1, true), o.text())
  o = io()
  ok(cli.ntp({ "tz", "America/New_York" }, o))
  ok(o.lines[1]:find("EDT", 1, true), o.lines[1])
  o = io()
  ok(not cli.ntp({ "tz", "Atlantis" }, o))
  ok(cli.ntp({ "add", "peer", "ntp1" }, io()))
  ok(cli.ntp({ "add", "http", "https://example.test/time", "json" }, io()))
  ok(cli.ntp({ "add", "http" }, io()))
  o = io()
  cli.ntp({ "servers" }, o)
  eq(#o.lines, 1 + 1 + 1 + #web.DEFAULTS)
  ok(o.lines[2]:find("peer ntp1", 1, true))
  ok(cli.ntp({ "up", "2" }, io()))
  o = io()
  cli.ntp({ "servers" }, o)
  ok(o.lines[1]:find("peer ntp1", 1, true))
  ok(cli.ntp({ "remove", "1" }, io()))
  o = io()
  ok(not cli.ntp({ "remove", "99" }, o))
  ok(cli.ntp({ "serve", "on", "--closed" }, io()))
  local c = ntp.config()
  ok(c.serve and not c.open)
  ok(cli.ntp({ "serve", "off" }, io()))
  ok(not ntp.config().serve)
  o = io()
  ok(cli.ntp({ "set", "2030-06-01 08:00:00" }, o))
  o = io()
  cli.ntp({ "status" }, o)
  ok(o.text():find("MANUAL", 1, true), o.text())
  ok(cli.ntp({ "auto" }, io()))
  eq(time.state().mode, "auto")
  ok(not cli.ntp({ "frobnicate" }, io()))
end)

test("ntp sync and ntpdate commands over the network", function()
  reset()
  withNodes(3000, function(s, c)
    vfs.writeTable(ntp.CONFIG, { servers = { { type = "peer", host = "ntp1", auth = false, samples = 2 } } })
    local o = io()
    ok(cli.ntp({ "sync" }, o, c), table.concat(o.errs, "|"))
    ok(o.text():find("Synchronised to ntp1", 1, true), o.text())
    ok(math.abs(time.offset() - 3000) < 400, tostring(time.offset()))
    o = io()
    ok(cli.ntpdate({ "ntp1" }, o, c), table.concat(o.errs, "|"))
    ok(o.text():find("stratum 1", 1, true) and o.text():find("NOT authenticated", 1, true), o.text())
    o = io()
    ok(not cli.ntpdate({ "nobody" }, o, c))
  end)
end)
