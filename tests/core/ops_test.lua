-- SPDX-License-Identifier: AGPL-3.0-or-later
local cron = require("tsr.cron")
local metrics = require("tsr.metrics")
local logship = require("tsr.logship")
local net = require("tsr.net")
local logmod = require("tsr.log")
local netbus = dofile("/tests/lib/netbus.lua")

local DIR = "/tmp-ops"

local function fresh()
  if fs.exists(DIR) then fs.delete(DIR) end
  fs.makeDir(DIR)
  cron.TAB_PATH = DIR .. "/cron.tab"
  cron.LOG_PATH = DIR .. "/cron.log"
  logship.DIR = DIR .. "/remote"
end

local function slurp(path)
  local h = fs.open(path, "r")
  if not h then return nil end
  local s = h.readAll()
  h.close()
  return s
end

test("cron lines parse", function()
  local j = cron.parseLine("every 10m rs set top on")
  eq({ j.kind, j.seconds, j.command }, { "every", 600, "rs set top on" })
  j = cron.parseLine("every 2h echo hi")
  eq(j.seconds, 7200)
  j = cron.parseLine("at 06:30 backup now")
  eq({ j.kind, j.hour, j.command }, { "at", 6.5, "backup now" })
  j = cron.parseLine("boot svc start netd")
  eq({ j.kind, j.command }, { "boot", "svc start netd" })
  eq(cron.parseLine("# comment"), false)
  eq(cron.parseLine("   "), false)
  for _, bad in ipairs({ "every 0s x", "every 5 x", "every 5m", "at 25:00 x", "at 6:5 x", "daily x", "boot" }) do
    local job, err = cron.parseLine(bad)
    ok(job == nil and err, bad)
  end
end)

test("the table can be edited and listed", function()
  fresh()
  ok(cron.add("every 5m echo a"))
  ok(cron.add("# keep me"))
  ok(cron.add("at 06:00 echo b"))
  local bad, err = cron.add("every nonsense")
  ok(bad == nil and err)
  local jobs, problems = cron.load()
  eq(#jobs, 2)
  eq(#problems, 0)
  ok(cron.remove(1))
  jobs = cron.load()
  eq(jobs[1].command, "echo b")
  ok(slurp(cron.TAB_PATH):find("# keep me", 1, true), "comments survive")
  local r, e = cron.remove(9)
  ok(r == nil and e:find("no job"))
  -- problems are reported with line numbers
  local h = fs.open(cron.TAB_PATH, "w")
  h.write("every 1m ok\nnonsense line\n")
  h.close()
  jobs, problems = cron.load()
  eq(#jobs, 1)
  ok(problems[1]:find("line 2", 1, true))
end)

test("interval jobs fire after each interval", function()
  local job, st = cron.parseLine("every 10s x"), {}
  ok(not cron.due(job, { seconds = 100, hour = 0, day = 1 }, st), "first sight only starts the clock")
  ok(not cron.due(job, { seconds = 105, hour = 0, day = 1 }, st))
  ok(cron.due(job, { seconds = 110, hour = 0, day = 1 }, st))
  ok(not cron.due(job, { seconds = 115, hour = 0, day = 1 }, st))
  ok(cron.due(job, { seconds = 121, hour = 0, day = 1 }, st))
end)

test("daily jobs fire once per in-game day, not for times long past", function()
  local job = cron.parseLine("at 06:00 x")
  local st = {}
  ok(not cron.due(job, { seconds = 0, hour = 5.9, day = 3 }, st))
  ok(cron.due(job, { seconds = 0, hour = 6.01, day = 3 }, st))
  ok(not cron.due(job, { seconds = 0, hour = 6.5, day = 3 }, st), "only once a day")
  ok(cron.due(job, { seconds = 0, hour = 6.0, day = 4 }, st), "again the next day")
  -- scheduler started at 22:00: the 06:00 job of "today" is not run retroactively
  local late = {}
  ok(not cron.due(job, { seconds = 0, hour = 22, day = 9 }, late))
  ok(cron.due(job, { seconds = 0, hour = 6, day = 10 }, late))
end)

test("boot jobs run once", function()
  local job, st = cron.parseLine("boot x"), {}
  ok(cron.due(job, { seconds = 0, hour = 0, day = 1 }, st))
  ok(not cron.due(job, { seconds = 1, hour = 0, day = 1 }, st))
end)

test("tick runs due jobs and logs their output", function()
  fresh()
  local jobs = { cron.parseLine("boot echo from-cron"), cron.parseLine("boot nosuchcmd-xyz") }
  local states = {}
  eq(cron.tick(jobs, states, { seconds = 0, hour = 0, day = 1 }), 2)
  eq(cron.tick(jobs, states, { seconds = 1, hour = 0, day = 1 }), 0)
  local text = slurp(cron.LOG_PATH)
  ok(text:find("echo from-cron -> 0", 1, true) and text:find("from-cron\n", 1, true), text)
  ok(text:find("nosuchcmd%-xyz %-> 127"), text)
  local status, out = cron.run("echo direct")
  eq(status, 0)
  eq(out, "direct\n")
end)

test("the cron log stays small", function()
  fresh()
  cron.LOG_MAX = 500
  local jobs, states = { cron.parseLine("boot echo " .. string.rep("x", 100)) }, {}
  for _ = 1, 20 do
    states = {}
    cron.tick(jobs, states, { seconds = 0, hour = 0, day = 1 })
  end
  ok(#slurp(cron.LOG_PATH) <= 500)
  cron.LOG_MAX = 20000
end)

test("crontab command", function()
  fresh()
  local function run(...)
    local io = { said = {}, errs = {} }
    function io.say(t) io.said[#io.said + 1] = t end
    function io.err(t) io.errs[#io.errs + 1] = t end
    local r = cron.crontab({ ... }, io)
    return r, table.concat(io.said, " / "), table.concat(io.errs, " / ")
  end
  local r, text = run("list")
  ok(r and text:find("No jobs", 1, true))
  r = run("add", "every", "1m", "echo", "tick")
  ok(r)
  r, text = run("list")
  ok(text:find("1. every 1m echo tick", 1, true), text)
  r, text = run("run", "1")
  ok(r and text:find("tick", 1, true), text)
  eq(run("add", "bogus"), false)
  ok(run("remove", "1"))
  eq(run("run", "5"), false)
  eq(run("whatever"), false)
end)

test("metrics collect and extend", function()
  local g = metrics.collect({ custom = 7 })
  eq(g.custom, 7)
  ok(type(g.uptime) == "number" and g.uptime >= 0)
  ok(type(g.memory_kb) == "number" and g.memory_kb > 0)
  ok(g.id == os.getComputerID())
  ok(type(g.host) == "string")
  local before = g.log_warn
  metrics.hookLog()
  logmod.get("ops-test").warn("counted")
  logmod.get("ops-test").error("counted too")
  local after = metrics.collect()
  eq(after.log_warn, before + 1)
  ok(after.log_error >= 1)
end)

test("metrics are readable over the network by paired peers only", function()
  fresh()
  local bus = netbus.new()
  local a = net.node({ id = 11, hostname = "alpha", transport = bus:transport(11), peersPath = DIR .. "/a.peers" })
  local b = net.node({ id = 22, hostname = "beta", transport = bus:transport(22), peersPath = DIR .. "/b.peers" })
  local c = net.node({ id = 33, hostname = "gamma", transport = bus:transport(33), peersPath = DIR .. "/c.peers" })
  local failure
  parallel.waitForAny(
    function() a:run() end,
    function() b:run() end,
    function()
      local okRun, err = pcall(function()
        parallel.waitForAll(
          function() ok(a:pairListen({ code = "ABCDE-FGHJK", timeout = 10 })) end,
          function() sleep(0.2) ok(b:pairConnect(11, "ABCDE-FGHJK", 5)) end)
        metrics.serve(a)
        local io = { said = {}, errs = {} }
        function io.say(t) io.said[#io.said + 1] = t end
        function io.err(t) io.errs[#io.errs + 1] = t end
        ok(metrics.run({ "alpha" }, io, b))
        local text = table.concat(io.said, "\n")
        ok(text:find("host", 1, true) and text:find("uptime", 1, true), text)
        -- an unpaired computer gets nothing
        local io2 = { said = {}, errs = {} }
        function io2.say(t) io2.said[#io2.said + 1] = t end
        function io2.err(t) io2.errs[#io2.errs + 1] = t end
        eq(metrics.run({ "alpha" }, io2, c), false)
      end)
      if not okRun then failure = err end
    end)
  if failure then error(failure, 0) end
end)

test("log shipping delivers warnings to the collector and keeps them if it is away", function()
  fresh()
  logship.reset()
  logship.hook("warn")
  local bus = netbus.new()
  local collector = net.node({ id = 11, hostname = "hub", transport = bus:transport(11), peersPath = DIR .. "/hub.peers" })
  local worker = net.node({ id = 22, hostname = "worker 1", transport = bus:transport(22), peersPath = DIR .. "/w.peers" })
  local failure
  parallel.waitForAny(
    function() collector:run() end,
    function() worker:run() end,
    function()
      local okRun, err = pcall(function()
        parallel.waitForAll(
          function() ok(collector:pairListen({ code = "ABCDE-FGHJK", timeout = 10 })) end,
          function() sleep(0.2) ok(worker:pairConnect(11, "ABCDE-FGHJK", 5)) end)
        local l = logmod.get("shipper")
        l.info("not shipped")
        l.warn("disk %d almost full", 95)
        l.error("reactor offline")
        eq(logship.pending(), 2)
        -- the collector is not serving yet: nothing is lost
        local n, e = logship.flush(worker, "hub")
        ok(n == nil, tostring(e))
        eq(logship.pending(), 2)
        logship.serve(collector)
        eq(logship.flush(worker, "hub"), 2)
        eq(logship.pending(), 0)
        local lines = logship.tail("worker 1")
        eq(#lines, 2)
        ok(lines[1]:find("disk 95 almost full", 1, true) and lines[2]:find("reactor offline", 1, true))
        ok(fs.exists(DIR .. "/remote/worker_1.log"), "file name is sanitised")
        ok(logship.tail("nobody") == nil)
      end)
      if not okRun then failure = err end
    end)
  logship.reset()
  if failure then error(failure, 0) end
end)

test("the collector limits what a peer can write", function()
  fresh()
  local bus = netbus.new()
  local collector = net.node({ id = 11, hostname = "hub", transport = bus:transport(11), peersPath = DIR .. "/hub.peers" })
  local worker = net.node({ id = 22, hostname = "w", transport = bus:transport(22), peersPath = DIR .. "/w.peers" })
  local failure
  parallel.waitForAny(
    function() collector:run() end,
    function() worker:run() end,
    function()
      local okRun, err = pcall(function()
        parallel.waitForAll(
          function() ok(collector:pairListen({ code = "ABCDE-FGHJK", timeout = 10 })) end,
          function() sleep(0.2) ok(worker:pairConnect(11, "ABCDE-FGHJK", 5)) end)
        logship.serve(collector)
        local lines = {}
        for i = 1, 150 do lines[i] = "line " .. i .. string.rep("y", 400) .. "\nsecond physical line" end
        eq(worker:call("hub", "log", "write", { lines = lines }), 100)
        local stored = logship.tail("w", 200)
        eq(#stored, 100, "newlines inside a line cannot fake extra entries")
        ok(#stored[1] <= 300)
        local r, e = worker:call("hub", "log", "write", { lines = "nope" })
        ok(r == nil and e:find("bad request"))
      end)
      if not okRun then failure = err end
    end)
  if failure then error(failure, 0) end
end)
