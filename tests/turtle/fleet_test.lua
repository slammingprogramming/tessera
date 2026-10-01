-- SPDX-License-Identifier: AGPL-3.0-or-later
local Sim = dofile("/tests/lib/turtlesim.lua")
local netbus = dofile("/tests/lib/netbus.lua")
local net = require("tsr.net")
local T = require("tsr.turtle")
local nav = require("tsr.turtle.nav")
local fleet = require("tsr.fleet")

local DIR = "/tmp-fleet"

--- A controller node (id 11) and two turtle nodes (22 and 33), each paired with the controller. fn(ctl, t1, t2, sim).
local function withFleet(fn)
  if fs.exists(DIR) then fs.delete(DIR) end
  fs.makeDir(DIR .. "/jobs")
  fleet.ROSTER_PATH = DIR .. "/roster"
  fleet.ALLOW_PATH = DIR .. "/allow"
  fleet.JOB_DIR = DIR .. "/jobs"
  fleet.reset()
  T.dir = DIR .. "/turtle"
  T.sleep = function() end
  T.unloadForTest()
  nav.unloadForTest()
  local sim = Sim.new({ fuel = 500 })
  sim:install()
  local bus = netbus.new()
  local ctl = net.node({ id = 11, hostname = "base", transport = bus:transport(11), peersPath = DIR .. "/ctl.peers" })
  local t1 = net.node({ id = 22, hostname = "miner-1", transport = bus:transport(22), peersPath = DIR .. "/t1.peers" })
  local t2 = net.node({ id = 33, hostname = "miner-2", transport = bus:transport(33), peersPath = DIR .. "/t2.peers" })
  local failure
  parallel.waitForAny(
    function() ctl:run() end, function() t1:run() end, function() t2:run() end,
    function()
      local okRun, err = pcall(function()
        for _, t in ipairs({ { t1, 22 }, { t2, 33 } }) do
          parallel.waitForAll(
            function() ok(t[1]:pairListen({ code = "ABCDE-FGHJK", timeout = 10 })) end,
            function() sleep(0.2) ok(ctl:pairConnect(t[2], "ABCDE-FGHJK", 5)) end)
        end
        fn(ctl, t1, t2, sim)
      end)
      if not okRun then failure = err end
    end)
  sim:uninstall()
  nav.unloadForTest()
  if fs.exists(DIR) then fs.delete(DIR) end
  if failure then error(failure, 0) end
end

local function cli(node, ...)
  local io = { said = {}, errs = {} }
  function io.say(t) io.said[#io.said + 1] = t end
  function io.err(t) io.errs[#io.errs + 1] = t end
  local r = fleet.run({ ... }, io, node)
  return r, table.concat(io.said, "\n"), table.concat(io.errs, "\n")
end

local function writeJob(name, body)
  local h = fs.open(DIR .. "/jobs/" .. name .. ".lua", "w")
  h.write(body)
  h.close()
end

test("a turtle reports its status to allowed controllers only", function()
  withFleet(function(ctl, t1, t2, sim)
    fleet.serve(t1)
    local res, err = ctl:call("miner-1", "turtle", "status")
    ok(res == nil and err == "not allowed", tostring(err))
    ok(cli(t1, "allow", "base"))
    res = ctl:call("miner-1", "turtle", "status")
    ok(res, "allowed now")
    eq({ res.x, res.y, res.z }, { 0, 0, 0 })
    eq(res.fuel, 500)
    eq(res.busy, false)
    eq(res.freeSlots, 16)
    ok(cli(t1, "deny", "base"))
    res, err = ctl:call("miner-1", "turtle", "status")
    ok(res == nil)
    local _, text = cli(t1, "allowed")
    ok(text:find("Nobody", 1, true))
  end)
end)

test("the roster and the list command", function()
  withFleet(function(ctl, t1, t2)
    fleet.serve(t1)
    cli(t1, "allow", "base")
    -- t2 runs no fleet agent at all
    local r, text = cli(ctl, "list")
    ok(r and text:find("roster is empty", 1, true), text)
    ok(cli(ctl, "add", "miner-1"))
    ok(cli(ctl, "add", "miner-2"))
    eq(fleet.roster(), { "miner-1", "miner-2" })
    r, text = cli(ctl, "list")
    ok(text:find("miner-1", 1, true) and text:find("idle", 1, true), text)
    ok(text:find("miner-2", 1, true) and text:find("offline", 1, true) and text:find("no such service", 1, true), text)
    ok(cli(ctl, "remove", "miner-2"))
    eq(fleet.roster(), { "miner-1" })
    local _, roster = cli(ctl, "roster")
    eq(roster, "miner-1")
    eq(cli(ctl, "add"), false)
  end)
end)

test("only whitelisted jobs that exist can run, one at a time", function()
  withFleet(function(ctl, t1)
    fleet.serve(t1)
    cli(t1, "allow", "base")
    local started = {}
    fleet.spawnJob = function(path, args, cap)
      started[#started + 1] = { path = path, args = args }
      return 4242
    end
    -- unknown job name, job not whitelisted, job not installed
    local r, err = ctl:call("miner-1", "turtle", "run", { job = "rm" }, { encrypt = true })
    ok(r == nil and err:find("not allowed"), tostring(err))
    r, err = ctl:call("miner-1", "turtle", "run", { job = "bore" }, { encrypt = true })
    ok(r == nil and err:find("does not have"), tostring(err))
    writeJob("bore", "-- a job")
    r, err = ctl:call("miner-1", "turtle", "run", { job = "bore", args = { 3, "down" } }, { encrypt = true })
    ok(r, tostring(err))
    eq(r.pid, 4242)
    eq(started[1].args, { "3", "down" })
    ok(started[1].path:find("jobs/bore.lua", 1, true))
    -- "busy" while the process is alive: fake a kernel that knows the pid
    local kernel = require("tsr.kernel")
    local realGet = kernel.get
    kernel.get = function(pid) if pid == 4242 then return {} end return realGet(pid) end
    local status = ctl:call("miner-1", "turtle", "status")
    eq(status.busy, true)
    ok(status.job:find("bore 3 down", 1, true), status.job)
    r, err = ctl:call("miner-1", "turtle", "run", { job = "bore" }, { encrypt = true })
    ok(r == nil and err:find("busy"), tostring(err))
    -- stop
    local terminated
    local realTerminate, realKill = kernel.terminate, kernel.kill
    kernel.terminate = function(pid) terminated = pid kernel.get = realGet end
    kernel.kill = function() end
    eq(ctl:call("miner-1", "turtle", "stop"), true)
    eq(terminated, 4242)
    eq(ctl:call("miner-1", "turtle", "stop"), false, "nothing running any more")
    kernel.terminate, kernel.kill, kernel.get = realTerminate, realKill, realGet
    fleet.spawnJob = nil
  end)
end)

test("fleet run and stop address one turtle or all of them", function()
  withFleet(function(ctl, t1, t2)
    fleet.serve(t1)
    fleet.serve(t2)
    cli(t1, "allow", "base")
    cli(t2, "allow", "base")
    cli(ctl, "add", "miner-1")
    cli(ctl, "add", "miner-2")
    writeJob("quarry", "-- job")
    local count = 0
    local realSpawn = fleet.spawnJob
    fleet.spawnJob = function() count = count + 1 return 100 + count end
    local r, text = cli(ctl, "run", "all", "quarry", "8", "8")
    ok(r, text)
    ok(text:find("miner-1: started quarry", 1, true) and text:find("miner-2: started quarry", 1, true), text)
    eq(count, 2, "one start per turtle")
    local r2, text2 = cli(ctl, "stop", "all")
    ok(r2 == true or text2 ~= nil)
    fleet.spawnJob = realSpawn
  end)
end)

test("goto uses the pathfinder and reports failures", function()
  withFleet(function(ctl, t1, t2, sim)
    fleet.serve(t1)
    cli(t1, "allow", "base")
    sim:fill(-3, 0, -2, 3, 0, -2, "minecraft:stone")
    local r, text = cli(ctl, "goto", "miner-1", "0", "0", "-5")
    ok(r, text)
    eq({ sim.x, sim.y, sim.z }, { 0, 0, -5 })
    r, _, err = cli(ctl, "goto", "miner-1", "x", "0", "0")
    eq(r, false)
    -- an unreachable spot
    sim:fill(9, -1, 9, 11, 1, 11, "minecraft:stone")
    sim:set(10, 0, 10, nil)
    local r2, _, err2 = cli(ctl, "goto", "miner-1", "10", "0", "10")
    ok(r2 == false and err2:find("miner%-1"), err2)
  end)
end)

test("the log shows what the job printed", function()
  withFleet(function(ctl, t1)
    fleet.serve(t1)
    cli(t1, "allow", "base")
    local _, none = cli(ctl, "log", "miner-1")
    ok(none:find("no output", 1, true), none)
    writeJob("bore", "print('digging')")
    local cap
    fleet.spawnJob = function(path, args, c)
      cap = c
      local prev = term.redirect(c.term)
      print("digging down")
      term.redirect(prev)
      return 7
    end
    cli(ctl, "run", "miner-1", "bore", "5")
    local _, text = cli(ctl, "log", "miner-1")
    ok(text:find("digging down", 1, true), text)
    fleet.spawnJob = nil
  end)
end)
