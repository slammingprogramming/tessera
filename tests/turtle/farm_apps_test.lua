-- SPDX-License-Identifier: AGPL-3.0-or-later
-- treefarm, cropfarm, cobblegen and guard against the turtle simulator.
local Sim = dofile("/tests/lib/turtlesim.lua")
local T = require("tsr.turtle")
local treefarm = require("tsrapps.treefarm")
local cropfarm = require("tsrapps.cropfarm")
local cobblegen = require("tsrapps.cobblegen")
local guard = require("tsrapps.guard")

local DIR = "/tmp-farm"

local function fresh(opts)
  if fs.exists(DIR) then fs.delete(DIR) end
  T.dir = DIR
  T.sleep = function() end
  T.unloadForTest()
  local sim = Sim.new(opts or { fuel = 5000 })
  sim:install()
  return sim
end

local function done(sim)
  sim:uninstall()
  if fs.exists(DIR) then fs.delete(DIR) end
end

local function testIo()
  local io = { said = {}, warned = {}, errs = {} }
  function io.say(t) io.said[#io.said + 1] = t end
  function io.warn(t) io.warned[#io.warned + 1] = t end
  function io.err(t) io.errs[#io.errs + 1] = t end
  function io.prompt(_, d) return d end
  function io.ask() return true end
  function io.waitInventory() end
  return io
end

test("treefarm recognises logs and saplings of any wood", function()
  ok(treefarm.isLog({ name = "minecraft:oak_log" }))
  ok(treefarm.isLog({ name = "minecraft:crimson_stem" }))
  ok(not treefarm.isLog({ name = "minecraft:oak_leaves" }))
  ok(treefarm.isSapling({ name = "minecraft:spruce_sapling" }))
  ok(not treefarm.isSapling({ name = "minecraft:stick" }))
end)

test("treefarm waits while there is no tree", function()
  local sim = fresh()
  sim:set(0, 0, -1, "minecraft:oak_sapling")
  eq(treefarm.cycle({}, testIo()), "waiting")
  eq({ sim:where() }, { 0, 0, 0, 0 })
  done(sim)
end)

test("treefarm fells the tree, replants, and empties into the chest below", function()
  local sim = fresh()
  sim:set(0, -1, 0, "minecraft:chest")
  sim:set(0, -1, -1, "minecraft:dirt")
  sim:fill(0, 0, -1, 0, 3, -1, "minecraft:oak_log")
  sim:set(0, 4, -1, "minecraft:oak_leaves")
  sim:give("minecraft:oak_sapling", 3, 1)
  local r = treefarm.cycle({ chest = "down" }, testIo())
  eq(type(r), "table")
  eq(r.logs, 4)
  ok(r.replanted)
  eq(sim:get(0, 0, -1), "minecraft:oak_sapling")
  eq(sim:chestCount(0, -1, 0, "minecraft:oak_log"), 4)
  eq(sim:itemCount("minecraft:oak_sapling"), 2, "saplings are kept")
  eq({ sim:where() }, { 0, 0, 0, 0 })
  eq(sim:get(0, 4, -1), "minecraft:oak_leaves", "leaves untouched")
  done(sim)
end)

test("treefarm can dump into a chest behind it", function()
  local sim = fresh()
  sim:set(0, 0, 1, "minecraft:chest")
  sim:set(0, -1, -1, "minecraft:dirt")
  sim:fill(0, 0, -1, 0, 2, -1, "minecraft:oak_log")
  sim:give("minecraft:oak_sapling", 1, 1)
  local r = treefarm.cycle({ chest = "back" }, testIo())
  eq(type(r), "table")
  eq(r.logs, 3)
  eq(sim:chestCount(0, 0, 1, "minecraft:oak_log"), 3)
  eq(sim.dir, 0, "faces the tree spot again")
  done(sim)
end)

test("treefarm without saplings reports it but still dumps", function()
  local sim = fresh()
  sim:set(0, -1, 0, "minecraft:chest")
  sim:fill(0, 0, -1, 0, 1, -1, "minecraft:oak_log")
  local io = testIo()
  local r = treefarm.cycle({}, io)
  eq(r.logs, 2)
  eq(r.replanted, false)
  ok(io.warned[1]:find("Replant failed"))
  done(sim)
end)

test("treefarm main loop runs the requested number of rounds", function()
  local sim = fresh()
  sim:set(0, -1, 0, "minecraft:chest")
  sim:set(0, -1, -1, "minecraft:dirt")
  sim:fill(0, 0, -1, 0, 2, -1, "minecraft:oak_log")
  sim:give("minecraft:oak_sapling", 2, 1)
  local io = testIo()
  ok(treefarm.main({ "--rounds", "2", "--wait", "0" }, io))
  local felled = 0
  for _, l in ipairs(io.said) do if l:find("Felled") then felled = felled + 1 end end
  eq(felled, 1, "the sapling has not grown, so the second round only waits")
  eq(treefarm.main({ "--chest", "sideways" }, io), false)
  done(sim)
end)

local function field(sim, ripeAge)
  -- crops at y = -1, farmland at y = -2; 3 forward (z 0..-2) x 2 right (x 0..1)
  sim:fill(0, -2, -2, 1, -2, 0, "minecraft:farmland")
  for x = 0, 1 do
    for z = -2, 0 do sim:set(x, -1, z, "minecraft:wheat", { age = ripeAge }) end
  end
end

test("cropfarm tends ripe, growing and empty patches differently", function()
  local sim = fresh()
  sim:set(0, -2, 0, "minecraft:farmland")
  sim:set(0, -1, 0, "minecraft:wheat", { age = 7 })
  sim:give("minecraft:wheat_seeds", 5, 1)
  eq(cropfarm.tend(), "harvested")
  eq(sim:get(0, -1, 0), "minecraft:wheat")
  eq(sim:block(0, -1, 0).state.age, 0, "replanted as a seedling")
  eq(cropfarm.tend(), "growing")
  sim:set(0, -1, 0, nil)
  eq(cropfarm.tend(), "empty")
  eq(cropfarm.tend("wheat"), "planted")
  sim:set(0, -1, 0, "minecraft:stone")
  eq(cropfarm.tend(), "other")
  done(sim)
end)

test("cropfarm harvests a whole field, stores the crop, keeps seeds and replants", function()
  local sim = fresh()
  field(sim, 7)
  sim:set(1, -1, -1, "minecraft:wheat", { age = 3 }) -- one patch still growing
  sim:give("minecraft:wheat_seeds", 20, 1)
  sim:set(0, 0, 1, "minecraft:chest")                -- chest behind the start
  local r = cropfarm.harvest(3, 2, { chest = "back", keep = 10 }, testIo())
  eq(r.harvested, 5)
  eq(r.growing, 1)
  eq(sim:chestCount(0, 0, 1, "minecraft:wheat"), 5)
  eq(sim:itemCount("minecraft:wheat_seeds"), 10, "exactly the kept seeds stay in the turtle")
  eq({ sim:where() }, { 0, 0, 0, 0 })
  for x = 0, 1 do
    for z = -2, 0 do eq(sim:get(x, -1, z), "minecraft:wheat", "patch " .. x .. "," .. z .. " is planted") end
  end
  done(sim)
end)

test("cropfarm validates its arguments", function()
  local sim = fresh()
  local io = testIo()
  eq(cropfarm.main({ "3", "3", "--crop", "grass" }, io), false)
  eq(cropfarm.main({ "0", "3" }, io), false)
  eq(cropfarm.main({ "3", "3", "--chest", "left" }, io), false)
  done(sim)
end)

test("cropfarm main does one pass with --once", function()
  local sim = fresh()
  field(sim, 7)
  sim:set(0, 0, 1, "minecraft:chest")
  sim:give("minecraft:wheat_seeds", 12, 1)
  local io = testIo()
  ok(cropfarm.main({ "3", "2", "--once", "--chest", "back", "--keep", "8" }, io))
  ok(io.said[#io.said]:find("Harvested 6"), io.said[#io.said])
  done(sim)
end)

test("cobblegen mines the regenerating block and empties into a chest", function()
  local sim = fresh()
  sim:regenerate(0, 0, -1, "minecraft:stone")
  sim:set(0, -1, 0, "minecraft:chest")
  for slot = 1, 13 do sim:give("minecraft:diamond", 64, slot) end   -- only 3 slots free
  local io = testIo()
  ok(cobblegen.main({ "100", "--chest", "down" }, io))
  ok(io.said[#io.said]:find("Mined 100"))
  eq(sim:itemCount("minecraft:cobblestone") + sim:chestCount(0, -1, 0, "minecraft:cobblestone"), 100)
  ok(sim:chestCount(0, -1, 0) > 0)
  done(sim)
end)

test("cobblegen stops when full with no chest", function()
  local sim = fresh()
  sim:regenerate(0, 0, -1, "minecraft:stone")
  for slot = 1, 14 do sim:give("minecraft:diamond", 64, slot) end
  local io = testIo()
  ok(cobblegen.main({}, io))
  ok(io.warned[1]:find("full"))
  done(sim)
end)

test("guard attacks the chosen sides", function()
  local sim = fresh()
  sim:addMob(0, 0, -1, 2)
  sim:addMob(0, 1, 0, 1)
  eq(guard.round({ "f", "u" }, false), 3)
  eq(sim.kills, 3)
  local sides, err = guard.parseSides("f,x")
  ok(sides == nil and err:find("unknown side"))
  eq(guard.parseSides("f,u,d"), { "f", "u", "d" })
  done(sim)
end)

test("guard main runs N rounds, turning each time", function()
  local sim = fresh()
  local io = testIo()
  ok(guard.main({ "--rounds", "4", "--turn" }, io))
  eq(sim.dir, 0, "four quarter turns")
  ok(io.said[#io.said]:find("4 rounds"))
  eq(guard.main({ "--sides", "q" }, io), false)
  done(sim)
end)
