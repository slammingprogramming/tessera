-- SPDX-License-Identifier: AGPL-3.0-or-later
local F = dofile("/tests/lib/fakes.lua")
local hal = require("tsr.hal")
local scada = require("tsr.scada")

local DIR = "/tmp-mek"

local function env(devices, rs)
  if fs.exists(DIR) then fs.delete(DIR) end
  fs.makeDir(DIR)
  hal.reset()
  scada.clearAll()
  scada.CFG_PATH = DIR .. "/scada.cfg"
  return { peripheral = F.peripheralApi(devices), redstone = rs or F.redstone(), devicesPath = DIR .. "/none" }
end

local function fission(state)
  state = state or {}
  local r = { _type = "fissionReactor", running = state.running ~= false, temp = state.temp or 600, damage = state.damage or 0,
              coolant = state.coolant or 1, waste = state.waste or 0, scrams = 0 }
  function r.getStatus() return r.running end
  function r.getTemperature() if r.broken then error("chunk is not loaded", 0) end return r.temp end
  function r.getDamagePercent() return r.damage end
  function r.getCoolantFilledPercentage() return r.coolant end
  function r.getWasteFilledPercentage() return r.waste end
  function r.getBurnRate() return 5.5 end
  function r.activate() r.running = true end
  function r.scram() r.running = false r.scrams = r.scrams + 1 end
  function r.setBurnRate(n) r.rate = n end
  return r
end

test("energy cubes and matrices report power", function()
  local cube = { _type = "energyCube", getEnergy = function() return 2500 end, getMaxEnergy = function() return 10000 end }
  local matrix = { _type = "inductionPort", getEnergy = function() return 0 end, getMaxEnergy = function() return 0 end }
  local e = env({ cube = cube, port = matrix })
  local d = hal.get("cube", e)
  ok(d:has("energy"))
  eq({ d:get("energy.stored") }, { 2500, "J" })
  eq({ d:get("energy.percent") }, { 25, "%" })
  eq(hal.get("port", e):get("energy.percent"), 0)
end)

test("a fission reactor is a reactor and a machine", function()
  local r = fission({ temp = 650, damage = 0.5 })
  local e = env({ reactor_0 = r })
  local d = hal.get("reactor_0", e)
  ok(d:has("reactor") and d:has("machine"))
  eq(d:get("reactor.running"), true)
  eq({ d:get("reactor.temperature") }, { 650, "K" })
  eq({ d:get("reactor.damage") }, { 50, "%" }, "fractions are shown as percent")
  eq({ d:get("reactor.coolant") }, { 100, "%" })
  eq({ d:get("reactor.burn_rate") }, { 5.5, "mB/t" })
  ok(d:act("reactor.scram"))
  eq(r.running, false)
  ok(d:act("machine.start"))
  eq(r.running, true)
  ok(d:act("reactor.set_burn_rate", "7.5"))
  eq(r.rate, 7.5)
  local v, why = d:get("reactor.max_burn_rate")
  ok(v == nil and why == "no such reading", "readings the machine lacks are not offered")
end)

test("readings are only offered for methods the machine has", function()
  local bare = { _type = "fissionReactor", getStatus = function() return true end, scram = function() end }
  local d = hal.get("bare", env({ bare = bare }))
  eq(d:metrics(), { "machine.running", "reactor.running" })
  eq(d:actionNames(), { "machine.stop", "reactor.scram" })
end)

test("fusion, turbine and digital miner", function()
  local fusion
  fusion = { _type = "fusionReactor", getTemperature = function() return 1e8 end, isIgnited = function() return true end,
                   getProductionRate = function() return 99 end, setInjectionRate = function(n) fusion.rate = n end }
  local turbine = { _type = "industrialTurbine", getFlowRate = function() return 100 end, getProductionRate = function() return 7 end }
  local miner
  miner = { _type = "digitalMiner", running = false, isRunning = function() return miner.running end,
                  start = function() miner.running = true end, stop = function() miner.running = false end,
                  getState = function() return "IDLE" end }
  local e = env({ f = fusion, t = turbine, m = miner })
  local f = hal.get("f", e)
  eq(f:get("reactor.running"), true)
  ok(f:act("reactor.set_injection", 4.9))
  eq(fusion.rate, 4)
  eq({ hal.get("t", e):get("turbine.flow") }, { 100, "mB/t" })
  local m = hal.get("m", e)
  eq(m:get("machine.running"), false)
  ok(m:act("machine.start"))
  eq(miner.running, true)
  eq(m:get("machine.state"), "IDLE")
end)

test("SCADA leaves a healthy reactor alone", function()
  local r = fission({ temp = 700, damage = 2, coolant = 0.9, waste = 10 })
  local e = env({ reactor_0 = r })
  local report = scada.check(e)
  eq(#report, 1)
  eq(report[1].ok, true)
  eq(r.scrams, 0)
end)

test("SCADA scrams on each kind of unsafe reading, once, and latches", function()
  for _, case in ipairs({
    { { temp = 1500 }, "temperature" },
    { { damage = 50 }, "damage" },
    { { coolant = 5 }, "coolant" },
    { { waste = 99 }, "waste" },
  }) do
    local r = fission(case[1])
    local e = env({ reactor_0 = r })
    local report = scada.check(e)
    ok(report[1].ok == false and report[1].reason:find(case[2], 1, true), case[2])
    eq(report[1].scrammed, true)
    eq(r.scrams, 1)
    eq(r.running, false)
    scada.check(e)
    eq(r.scrams, 1, "latched: not scrammed again")
    -- even if somebody restarts it, the latch only reports; clearing needs a person
    ok(scada.latched().reactor_0)
  end
end)

test("an unreadable reactor is treated as unsafe", function()
  local r = fission()
  r.broken = true
  local e = env({ reactor_0 = r })
  r.getStatus = function() error("peripheral detached", 0) end
  local report = scada.check(e)
  ok(report[1].ok == false and report[1].reason:find("cannot read"), tostring(report[1].reason))
  eq(r.scrams, 1)
end)

test("the latch is cleared deliberately and the alarm output follows it", function()
  local rs = F.redstone()
  local r = fission({ temp = 5000 })
  local e = env({ reactor_0 = r }, rs)
  local cfg = scada.config()
  cfg.alarm = "top"
  scada.check(e, cfg)
  eq(rs.out.top, 15, "alarm on")
  local bad, why = scada.reset("nothing")
  ok(bad == nil and why == "not latched")
  r.temp = 600
  scada.check(e, cfg)
  eq(rs.out.top, 15, "still latched although the reading recovered")
  ok(scada.reset("reactor_0"))
  scada.check(e, cfg)
  eq(rs.out.top, 0, "alarm off after the reset")
  eq(r.scrams, 1)
end)

test("thresholds come from the configuration", function()
  local r = fission({ temp = 900 })
  local e = env({ reactor_0 = r })
  local h = fs.open(scada.CFG_PATH, "w")
  h.write(textutils.serialize({ max_temperature = 800 }))
  h.close()
  eq(scada.config().max_temperature, 800)
  eq(scada.config().max_damage, scada.DEFAULTS.max_damage)
  local report = scada.check(e)
  ok(report[1].reason:find("800 K", 1, true), tostring(report[1].reason))
end)

test("the scada command", function()
  local r = fission({ temp = 5000 })
  local e = env({ reactor_0 = r })
  local function run(...)
    local io = { said = {}, errs = {} }
    function io.say(t) io.said[#io.said + 1] = t end
    function io.err(t) io.errs[#io.errs + 1] = t end
    local ok1 = scada.cli({ ... }, io, e)
    return ok1, table.concat(io.said, "\n"), table.concat(io.errs, "\n")
  end
  local ok1, text = run("status")
  ok(ok1 and text:find("reactor_0", 1, true) and text:find("5000K", 1, true), text)
  scada.check(e)
  ok1, text = run("status")
  ok(text:find("LATCHED", 1, true), text)
  eq(run("reset", "reactor_0"), true)
  eq(run("reset", "reactor_0"), false)
  ok1, text = run("config")
  ok(text:find("max_temperature = 1000", 1, true))
  eq(run("bogus"), false)
end)
