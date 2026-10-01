-- SPDX-License-Identifier: AGPL-3.0-or-later
local F = dofile("/tests/lib/fakes.lua")
local hal = require("tsr.hal")
local cli = require("tsr.hal.cli")

local DIR = "/tmp-hal"

local function env(devices, extra)
  if fs.exists(DIR) then fs.delete(DIR) end
  fs.makeDir(DIR)
  hal.reset()
  local e = { peripheral = F.peripheralApi(devices or {}), devicesPath = DIR .. "/devices", redstone = F.redstone() }
  for k, v in pairs(extra or {}) do e[k] = v end
  return e
end

local function energyCell(stored, cap)
  return { _type = "energy_storage", getEnergy = function() return stored end, getEnergyCapacity = function() return cap end }
end

local function tank(list)
  return { _type = "fluid_storage", tanks = function() return list end }
end

test("drivers load and match peripherals to capabilities", function()
  local inv = F.inventories({ chest_1 = 9 })
  local e = env({ chest_1 = inv.chest_1, cell = energyCell(500, 2000), tank_1 = tank({ { name = "minecraft:water", amount = 750 } }),
                  mon = F.monitor(), relay = (function() local r = F.redstone() r._type = "redstone_relay" return r end)() })
  eq(hal.loadDrivers() >= 7, true)
  local devices = hal.scan(e)
  local names = {}
  for _, d in ipairs(devices) do names[#names + 1] = d.name end
  eq(names, { "cell", "chest_1", "mon", "relay", "tank_1" })
  ok(hal.byName(devices, "cell"):has("energy"))
  ok(hal.byName(devices, "chest_1"):has("inventory"))
  ok(hal.byName(devices, "tank_1"):has("fluid"))
  ok(hal.byName(devices, "mon"):has("display"))
  ok(hal.byName(devices, "relay"):has("redstone"))
  eq(#hal.withCap(devices, "energy"), 1)
end)

test("unknown peripherals are skipped unless asked for", function()
  local e = env({ mystery = { _type = "weird_thing" } })
  eq(#hal.scan(e), 0)
  e.all = true
  eq(#hal.scan(e), 1)
end)

test("energy readings", function()
  local e = env({ cell = energyCell(500, 2000) })
  local d = hal.get("cell", e)
  eq({ d:get("energy.stored") }, { 500, "FE" })
  eq({ d:get("energy.capacity") }, { 2000, "FE" })
  eq({ d:get("energy.percent") }, { 25, "%" })
  local v, why = d:get("energy.flow")
  ok(v == nil and why == "no such reading")
  local empty = hal.get("cell", env({ cell = energyCell(0, 0) }))
  eq(empty:get("energy.percent"), 0)
end)

test("fluid and inventory readings", function()
  local inv = F.inventories({ chest_1 = 9 })
  inv.chest_1.put("minecraft:coal", 100)
  inv.chest_1.put("minecraft:iron_ingot", 5)
  local e = env({ chest_1 = inv.chest_1, tank_1 = tank({ { name = "minecraft:water", amount = 750 }, { name = "minecraft:lava", amount = 250 } }) })
  local chest = hal.get("chest_1", e)
  eq(chest:get("inventory.size"), 9)
  eq(chest:get("inventory.used"), 3)
  eq(chest:get("inventory.items"), 105)
  eq(chest:get("inventory.count", "minecraft:coal"), 100)
  eq(chest:get("inventory.count", "minecraft:gold_ingot"), 0)
  ok(math.abs(chest:get("inventory.percent") - 100 / 3) < 0.01)
  local t = hal.get("tank_1", e)
  eq({ t:get("fluid.amount") }, { 1000, "mB" })
  eq(t:get("fluid.name"), "minecraft:water")
  eq(#t:get("fluid.tanks"), 2)
end)

test("a device that errors gives an error value, not an exception", function()
  local broken = { _type = "energy_storage", getEnergy = function() error("chunk unloaded", 0) end, getEnergyCapacity = function() return 1 end }
  local d = hal.get("b", env({ b = broken }))
  local v, err = d:get("energy.stored")
  ok(v == nil and err:find("chunk unloaded"))
end)

test("redstone relays and monitors can be driven", function()
  local relay = F.redstone()
  relay._type = "redstone_relay"
  local mon = F.monitor()
  local e = env({ relay = relay, mon = mon })
  local r = hal.get("relay", e)
  relay.inp.top = 7
  eq(r:get("redstone.input", "top"), 7)
  ok(r:act("redstone.set", "left", true))
  eq(r:get("redstone.output", "left"), 15)
  ok(r:act("redstone.set", "left", 4))
  eq(r:get("redstone.output", "left"), 4)
  ok(r:act("redstone.set", "left", 99))
  eq(r:get("redstone.output", "left"), 15, "levels are clamped")
  local m = hal.get("mon", e)
  eq(m:get("display.size"), "20x6")
  ok(m:act("display.write", "hello", 2, 3))
  ok(mon.lines()[3]:find("hello", 1, true))
  ok(m:act("display.clear"))
  eq(mon.text():gsub("%s", ""), "")
  local bad, why = m:act("display.explode")
  ok(bad == nil and why == "no such action")
end)

test("virtual switches and sensors work through redstone only", function()
  local rs = F.redstone()
  local e = env({}, { redstone = rs })
  local out = {}
  local function run(...)
    local io = { said = {}, errs = {} }
    function io.say(t) io.said[#io.said + 1] = t end
    function io.err(t) io.errs[#io.errs + 1] = t end
    local r = cli.run({ ... }, io, e)
    return r, table.concat(io.said, " / "), table.concat(io.errs, " / ")
  end
  ok(run("virtual", "add", "switch", "smelter", "back"))
  ok(run("virtual", "add", "switch", "lamp", "front", "--invert"))
  ok(run("virtual", "add", "sensor", "gauge", "left", "--scale", "6.6667", "--unit", "%"))
  local smelter = hal.get("smelter", e)
  ok(smelter:has("machine"))
  eq(smelter:get("machine.running"), false)
  ok(smelter:act("machine.start"))
  eq(smelter:get("machine.running"), true)
  eq(rs.out.back, 15)
  ok(smelter:act("machine.toggle"))
  eq(smelter:get("machine.running"), false)
  -- an inverted switch is "running" while its output is low
  local lamp = hal.get("lamp", e)
  ok(lamp:act("machine.start"))
  eq(rs.out.front, 0)
  eq(lamp:get("machine.running"), true)
  -- sensor
  rs.inp.left = 15
  local gauge = hal.get("gauge", e)
  eq(gauge:get("sensor.level"), 15)
  eq(gauge:get("sensor.active"), true)
  local v, unit = gauge:get("sensor.value")
  ok(math.abs(v - 100) < 0.01 and unit == "%")
  rs.inp.left = 0
  eq(gauge:get("sensor.active"), false)
  -- listing and removing
  local r, text = run("virtual", "list")
  ok(text:find("smelter", 1, true) and text:find("gauge", 1, true), text)
  ok(run("virtual", "remove", "lamp"))
  eq(hal.get("lamp", e), nil)
  eq(run("virtual", "add", "switch", "bad name", "top"), false)
  eq(run("virtual", "add", "switch", "x", "sideways"), false)
  eq(run("virtual", "remove", "ghost"), false)
end)

test("the hal command lists, shows, reads and acts", function()
  local inv = F.inventories({ chest_1 = 9 })
  inv.chest_1.put("minecraft:coal", 10)
  local rs = F.redstone()
  local e = env({ cell = energyCell(1000, 4000), chest_1 = inv.chest_1 }, { redstone = rs })
  local function run(...)
    local io = { said = {}, errs = {} }
    function io.say(t) io.said[#io.said + 1] = t end
    function io.err(t) io.errs[#io.errs + 1] = t end
    local r = cli.run({ ... }, io, e)
    return r, table.concat(io.said, "\n"), table.concat(io.errs, "\n")
  end
  local r, text = run("list")
  ok(r and text:find("cell", 1, true) and text:find("chest_1", 1, true), text)
  r, text = run("list", "energy")
  ok(text:find("cell", 1, true) and not text:find("chest_1", 1, true))
  r, text = run("show", "cell")
  ok(r and text:find("energy.percent", 1, true) and text:find("25 %", 1, true), text)
  r, text = run("get", "cell", "energy.stored")
  eq(text, "1000 FE")
  r, text = run("get", "chest_1", "inventory.count", "minecraft:coal")
  eq(text, "10 items")
  local bad, _, err = run("get", "cell", "nothing")
  ok(bad == false and err:find("no such reading"))
  eq(run("get", "ghost", "x"), false)
  ok(run("virtual", "add", "switch", "m1", "top"))
  r, text = run("do", "m1", "machine.start")
  ok(r and text == "ok")
  eq(rs.out.top, 15)
  eq(run("do", "m1", "machine.explode"), false)
  eq(run("bogus"), false)
end)

test("shipped drivers all load", function()
  hal.reset()
  ok(hal.loadDrivers() >= 8)
  local ids = {}
  for _, d in ipairs(hal.drivers()) do ids[d.id] = true end
  ok(ids["generic.energy"] and ids["virtual"])
end)
