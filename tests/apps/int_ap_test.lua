-- SPDX-License-Identifier: AGPL-3.0-or-later
local F = dofile("/tests/lib/fakes.lua")
local hal = require("tsr.hal")
local me = require("tsr.hal.me")

--- A fake ME bridge holding `items` = { name = count }.
local function bridge(typeName, items, opts)
  opts = opts or {}
  local b = { _type = typeName, crafted = {} }
  function b.getEnergyStorage() return 4000 end
  function b.getMaxEnergyStorage() return 10000 end
  function b.getEnergyUsage() return 12.5 end
  function b.listItems()
    local out = {}
    for name, count in pairs(items) do out[#out + 1] = { name = name, count = count } end
    return out
  end
  function b.getItem(filter)
    local c = items[filter.name]
    if not c then return { name = filter.name, count = 0 } end
    return { name = filter.name, count = c }
  end
  function b.isItemCraftable(filter) return filter.name == "minecraft:stick" end
  function b.isItemCrafting(filter) return false end
  function b.craftItem(filter)
    if filter.name ~= "minecraft:stick" then return false, "no pattern" end
    b.crafted[#b.crafted + 1] = filter
    return true
  end
  if not opts.noTotals then
    function b.getTotalItemStorage() return 1000 end
    function b.getUsedItemStorage() return 250 end
    function b.getAvailableItemStorage() return 750 end
  end
  return b
end

local function env(devices)
  hal.reset()
  return { peripheral = F.peripheralApi(devices), redstone = F.redstone(), devicesPath = "/tmp-int-ap/none" }
end

test("both naming eras of the bridge are recognised", function()
  local e = env({ new = bridge("me_bridge", {}), old = bridge("meBridge", {}), rs = bridge("rs_bridge", {}), oldrs = bridge("rsBridge", {}) })
  hal.loadDrivers()
  local found = hal.find("storage_network", e)
  eq(#found, 4)
  for _, d in ipairs(found) do ok(d:has("energy")) end
end)

test("bridge readings", function()
  local e = env({ me = bridge("me_bridge", { ["minecraft:iron_ingot"] = 300, ["minecraft:coal"] = 12 }) })
  local d = hal.get("me", e)
  eq({ d:get("energy.percent") }, { 40, "%" })
  eq({ d:get("energy.usage") }, { 12.5, "AE/t" })
  eq({ d:get("network.count", "minecraft:iron_ingot") }, { 300, "items" })
  eq(d:get("network.count", "minecraft:gold_ingot"), 0)
  eq(d:get("network.items"), 312)
  eq(d:get("network.types"), 2)
  eq({ d:get("storage.percent") }, { 25, "%" })
  eq(d:get("network.craftable", "minecraft:stick"), true)
  eq(d:get("network.craftable", "minecraft:diamond"), false)
end)

test("a bridge without storage totals simply has no storage readings", function()
  local d = hal.get("me", env({ me = bridge("rs_bridge", {}, { noTotals = true }) }))
  local v, why = d:get("storage.total")
  ok(v == nil and why == "no such reading")
  ok(d:get("network.items") == 0)
end)

test("crafting goes through the bridge", function()
  local b = bridge("me_bridge", {})
  local d = hal.get("me", env({ me = b }))
  ok(d:act("network.craft", "minecraft:stick", 16))
  eq(b.crafted[1], { name = "minecraft:stick", count = 16 })
  local r, why = d:act("network.craft", "minecraft:bedrock", 1)
  ok(r == nil and why:find("no pattern"), tostring(why))
end)

test("environment, energy and player detectors", function()
  local envd = { _type = "environment_detector", getTime = function() return 6000 end, isRaining = function() return true end,
                 isThunder = function() return false end, getDimension = function() return "minecraft:overworld" end,
                 getBiome = function() return "minecraft:plains" end, isSlimeChunk = function() return false end }
  local limit = 500
  local energy = { _type = "energyDetector", getTransferRate = function() return 120 end, getTransferRateLimit = function() return limit end,
                   setTransferRateLimit = function(n) limit = n end }
  local players = { _type = "player_detector", getOnlinePlayers = function() return { "A", "B", "C" } end,
                    getPlayersInRange = function(r) if r >= 10 then return { "A" } else return {} end end }
  local e = env({ weather = envd, meter = energy, radar = players })
  eq(hal.get("weather", e):get("env.raining"), true)
  eq(hal.get("weather", e):get("env.dimension"), "minecraft:overworld")
  local m = hal.get("meter", e)
  eq({ m:get("energy.transfer") }, { 120, "FE/t" })
  ok(m:act("energy.set_limit", 250.7))
  eq(limit, 250)
  local p = hal.get("radar", e)
  eq(p:get("players.online"), 3)
  eq(p:get("players.in_range", 16), 1)
  eq(p:get("players.present", 5), false)
  eq(p:get("players.names"), { "A", "B", "C" })
end)

test("the me command", function()
  local b = bridge("me_bridge", { ["minecraft:iron_ingot"] = 300, ["minecraft:coal"] = 12, ["create:cogwheel"] = 40000 })
  b.listItems = (function(orig) return orig end)(b.listItems)
  local e = env({ me = b })
  local function run(...)
    local io = { said = {}, errs = {} }
    function io.say(t) io.said[#io.said + 1] = t end
    function io.err(t) io.errs[#io.errs + 1] = t end
    local r = me.run({ ... }, io, e)
    return r, table.concat(io.said, "\n"), table.concat(io.errs, "\n")
  end
  local r, text = run("storage")
  ok(r and text:find("40%%") and text:find("250 of 1000", 1, true), text)
  r, text = run("items")
  ok(text:find("create:cogwheel", 1, true), text)
  ok(text:find("40.0k", 1, true), text)
  r, text = run("items", "coal")
  ok(text:find("minecraft:coal", 1, true) and not text:find("cogwheel", 1, true), text)
  r, text = run("count", "minecraft:iron_ingot")
  ok(text:find("300", 1, true))
  r, text = run("craft", "minecraft:stick", "8")
  ok(r and text:find("8 x minecraft:stick", 1, true), text)
  local bad, _, err = run("craft", "minecraft:bedrock")
  ok(bad == false and err:find("no pattern"), err)
  eq(run("count"), false)
  eq(run("--device", "ghost", "storage"), false)
  eq(run("explode"), false)
  -- no bridge at all
  e = env({})
  local none, _, err2 = run("storage")
  ok(none == false and err2:find("no ME or RS bridge"))
end)

--- A bridge as Advanced Peripherals 0.8 names things (checked against the mod's source).
local function bridge08(items)
  local b = { _type = "me_bridge" }
  function b.getStoredEnergy() return 3000 end
  function b.getEnergyCapacity() return 12000 end
  function b.getEnergyUsage() return 7 end
  function b.getItems() local out = {} for name, count in pairs(items) do out[#out + 1] = { name = name, count = count } end return out end
  function b.getItem(filter) return { name = filter.name, count = items[filter.name] or 0 } end
  function b.isCraftable(filter) return filter.name == "minecraft:stick" end
  function b.isCrafting(filter) return filter.name == "minecraft:torch" end
  function b.craftItem(filter) return filter.name == "minecraft:stick" end
  function b.getTotalItemStorage() return 400 end
  function b.getUsedItemStorage() return 100 end
  function b.getAvailableItemStorage() return 300 end
  return b
end

test("Advanced Peripherals 0.8 method names work as well as the 0.7 ones", function()
  local e = env({ me = bridge08({ ["minecraft:iron_ingot"] = 50, ["minecraft:coal"] = 5 }) })
  hal.loadDrivers()
  local d = hal.get("me", e)
  eq({ d:get("energy.percent") }, { 25, "%" })
  eq({ d:get("energy.stored") }, { 3000, "AE" })
  eq({ d:get("energy.capacity") }, { 12000, "AE" })
  eq(d:get("network.items"), 55)
  eq(d:get("network.types"), 2)
  eq(d:get("network.count", "minecraft:iron_ingot"), 50)
  ok(d:get("network.craftable", "minecraft:stick"))
  ok(not d:get("network.craftable", "minecraft:dirt"))
  ok(d:get("network.crafting", "minecraft:torch"))
  ok(d:act("network.craft", "minecraft:stick", 4))
  -- the me command lists with getItems too
  local lines = {}
  local io = { say = function(t) lines[#lines + 1] = t end, err = function(t) lines[#lines + 1] = "ERR " .. t end }
  ok(me.run({ "items" }, io, e))
  local text = table.concat(lines, " | ")
  ok(text:find("minecraft:iron_ingot", 1, true), text)
end)
