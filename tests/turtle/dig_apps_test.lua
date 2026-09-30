-- SPDX-License-Identifier: AGPL-3.0-or-later
-- bore, carve, stripmine and quarry running against the turtle simulator.
local Sim = dofile("/tests/lib/turtlesim.lua")
local T = require("tsr.turtle")
local E = require("tsrapps.excavate")
local bore = require("tsrapps.bore")
local carve = require("tsrapps.carve")
local stripmine = require("tsrapps.stripmine")
local quarry = require("tsrapps.quarry")

local DIR = "/tmp-dig"

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

local function testIo(hooks)
  local io = { said = {}, warned = {}, errs = {} }
  function io.say(t) io.said[#io.said + 1] = t end
  function io.warn(t) io.warned[#io.warned + 1] = t end
  function io.err(t) io.errs[#io.errs + 1] = t end
  function io.prompt(_, default) return default end
  function io.ask() return true end
  function io.waitInventory() if hooks and hooks.wait then hooks.wait() end end
  return io
end

local function digs(sim)
  local n = 0
  for _, l in ipairs(sim.log) do if l:find("^dig ") then n = n + 1 end end
  return n
end

test("snake order visits every cell once and always moves to a neighbour", function()
  for _, dims in ipairs({ { 1, 1, 1 }, { 3, 1, 4 }, { 4, 3, 2 }, { 5, 5, 5 }, { 2, 7, 3 } }) do
    local cells = E.snake(dims[1], dims[2], dims[3])
    eq(#cells, dims[1] * dims[2] * dims[3])
    local seen = {}
    for _, c in ipairs(cells) do
      local k = c[1] .. "," .. c[2] .. "," .. c[3]
      ok(not seen[k], "duplicate " .. k)
      seen[k] = true
    end
    for i = 2, #cells do
      local a, b = cells[i - 1], cells[i]
      eq(math.abs(a[1] - b[1]) + math.abs(a[2] - b[2]) + math.abs(a[3] - b[3]), 1, "gap at " .. i)
    end
  end
end)

test("plans are contiguous for both orders and directions", function()
  for _, order in ipairs({ "slices", "layers" }) do
    for _, udown in ipairs({ false, true }) do
      local cells = E.plan({ f0 = -1, f1 = 2, r0 = 0, r1 = 2, u0 = -3, u1 = -1, order = order, udown = udown })
      eq(#cells, 4 * 3 * 3)
      ok(E.contiguous(cells))
    end
  end
  local cells = E.plan({ f0 = 1, f1 = 3, r0 = 0, r1 = 1, u0 = 0, u1 = 1, order = "slices" })
  local last = 0
  for _, c in ipairs(cells) do if c.last then last = last + 1 end end
  eq(last, 3, "one 'last' cell per slice")
end)

test("bore digs the whole tunnel, returns home and cleans up its job", function()
  local sim = fresh()
  sim:fill(0, 0, -5, 2, 2, -1, "minecraft:stone")
  local io = testIo()
  local ctx = assert(bore.build({ "5", "3", "3", "--yes" }, io, false))
  eq(E.run(ctx), true)
  eq(sim:countBlocks(nil, 0, 0, -5, 2, 2, -1), 0, "tunnel is empty")
  eq(sim:itemCount("minecraft:cobblestone"), 45)
  eq({ sim:where() }, { 0, 0, 0, 0 })
  eq(T.job.get(), nil)
  done(sim)
end)

test("bore lights the tunnel behind itself", function()
  local sim = fresh()
  sim:fill(-1, 0, -7, 1, 2, -1, "minecraft:stone")
  sim:give("minecraft:torch", 8)
  local io = testIo()
  local ctx = assert(bore.build({ "6", "1", "2", "--torch", "2" }, io, true))
  ok(ctx.torch and ctx.torch.every == 2)
  eq(E.run(ctx), true)
  -- torches sit in alcoves in the left wall (x = -1) at head height, at slices 2, 4 and 6 -> z = -2, -4, -6
  eq(sim:get(-1, 1, -2), "minecraft:torch")
  eq(sim:get(-1, 1, -4), "minecraft:torch")
  eq(sim:get(-1, 1, -6), "minecraft:torch")
  eq(sim:itemCount("minecraft:torch"), 5)
  eq(sim:countBlocks("minecraft:torch", -5, -5, -9, 5, 5, 5), 3, "no other torches")
  eq({ sim:where() }, { 0, 0, 0, 0 }, "the way home was never blocked")
  done(sim)
end)

test("bore --no-torch and missing torches place none", function()
  local sim = fresh()
  sim:fill(0, 0, -4, 0, 1, -1, "minecraft:stone")
  sim:give("minecraft:torch", 4)
  local io = testIo()
  local ctx = assert(bore.build({ "4", "1", "2", "--no-torch" }, io, true))
  eq(ctx.torch, nil)
  eq(E.run(ctx), true)
  eq(sim:itemCount("minecraft:torch"), 4)
  done(sim)
end)

test("bore --stay leaves the turtle at the far end", function()
  local sim = fresh()
  sim:fill(0, 0, -3, 0, 1, -1, "minecraft:stone")
  local ctx = assert(bore.build({ "3", "1", "2", "--stay" }, testIo(), false))
  eq(E.run(ctx), true)
  local x, y, z = sim:where()
  eq(z, -3)
  done(sim)
end)

test("bore asks for missing sizes and validates input", function()
  local io = testIo()
  local ctx = assert(bore.build({}, io, false))
  eq(ctx.params, { length = 10, width = 3, height = 3 })
  local bad, err = bore.build({ "0", "3", "3" }, io, false)
  ok(bad == nil and err:find("whole numbers"))
  bad, err = bore.build({ "5", "--dump", "left" }, io, false)
  ok(bad == nil and err:find("--dump"))
  bad, err = bore.build({ "5", "--nope" }, io, false)
  ok(bad == nil and err:find("unknown option"))
  bad, err = bore.build({ "x" }, io, false)
  ok(bad == nil)
end)

test("carve digs a corner room and a centred room", function()
  local sim = fresh()
  sim:fill(-3, -1, -4, 6, 4, 3, "minecraft:stone")
  sim:set(0, 0, 0, nil)
  local ctx = assert(carve.build({ "3", "4", "2", "--yes" }, testIo()))
  eq(E.run(ctx), true)
  -- forward = -z (f 0..2 -> z 0..-2), right = +x (r 0..3), up (u 0..1)
  eq(sim:countBlocks(nil, 0, 0, -2, 3, 1, 0), 0, "room dug")
  ok(sim:get(4, 0, 0) ~= nil and sim:get(0, 2, 0) ~= nil, "walls stay")
  eq({ sim:where() }, { 0, 0, 0, 0 })

  local sim2 = fresh()
  sim2:fill(-3, -1, -3, 3, 3, 3, "minecraft:stone")
  sim2:set(0, 0, 0, nil)
  ctx = assert(carve.build({ "3", "3", "2", "--center" }, testIo()))
  eq(E.run(ctx), true)
  eq(sim2:countBlocks(nil, -1, 0, -1, 1, 1, 1), 0, "centred room dug around the turtle")
  ok(sim2:get(2, 0, 0) ~= nil, "wall stays")
  done(sim2)
end)

test("carve bounds and offsets", function()
  local f0, f1, r0, r1, u0, u1 = carve.bounds(5, 5, 3, true, 0, 0, 0)
  eq({ f0, f1, r0, r1, u0, u1 }, { -2, 2, -2, 2, 0, 2 })
  f0, f1, r0, r1, u0, u1 = carve.bounds(4, 2, 2, false, 3, -1, 1)
  eq({ f0, f1, r0, r1, u0, u1 }, { 3, 6, -1, 0, 1, 2 })
  local bad, err = carve.build({ "3", "3", "3", "--offset", "1,2" }, testIo())
  ok(bad == nil and err:find("--offset"))
end)

test("quarry digs a pit downwards and comes back up", function()
  local sim = fresh()
  sim:fill(0, -3, -2, 2, -1, 0, "minecraft:stone")
  local ctx = assert(quarry.build({ "3", "3", "3", "--yes" }, testIo()))
  eq(E.run(ctx), true)
  eq(sim:countBlocks(nil, 0, -3, -2, 2, -1, 0), 0, "pit dug")
  eq({ sim:where() }, { 0, 0, 0, 0 })
  eq(sim:itemCount("minecraft:cobblestone"), 27)
  done(sim)
end)

test("stripmine plan is contiguous and shaped as documented", function()
  local cells = stripmine.plan(6, 3, 2)
  ok(E.contiguous(cells))
  local seen = {}
  for _, c in ipairs(cells) do seen[c.f .. "," .. c.r .. "," .. c.u] = true end
  for f = 1, 6 do for u = 0, 1 do ok(seen[f .. ",0," .. u], "main shaft " .. f .. " " .. u) end end
  for _, r in ipairs({ -2, -1, 1, 2 }) do
    for u = 0, 1 do
      ok(seen["3," .. r .. "," .. u], "branch at 3 " .. r .. " " .. u)
      ok(seen["6," .. r .. "," .. u], "branch at 6 " .. r .. " " .. u)
    end
  end
  ok(not seen["1,1,0"] and not seen["2,-1,0"], "no branches off-schedule")
end)

test("stripmine digs only the tunnels", function()
  local sim = fresh()
  sim:fill(-3, 0, -7, 3, 2, -1, "minecraft:stone")
  local ctx = assert(stripmine.build({ "6", "--spacing", "3", "--branch", "2", "--yes" }, testIo()))
  eq(E.run(ctx), true)
  eq(sim:countBlocks(nil, 0, 0, -6, 0, 1, -1), 0, "main shaft dug")
  eq(sim:countBlocks(nil, 1, 0, -3, 2, 1, -3), 0, "right branch dug")
  eq(sim:countBlocks(nil, -2, 0, -3, -1, 1, -3), 0, "left branch dug")
  ok(sim:get(1, 0, -2) ~= nil, "rock between branches stays")
  ok(sim:get(0, 2, -3) ~= nil, "ceiling stays")
  eq({ sim:where() }, { 0, 0, 0, 0 })
  done(sim)
end)

test("a paused job resumes after a restart without redoing work", function()
  local sim = fresh()
  sim:fill(0, 0, -6, 0, 1, -1, "minecraft:stone")
  local io = testIo()
  local ctx = assert(bore.build({ "6", "1", "2", "--yes" }, io, false))
  ctx.stopAfter = 5
  eq(E.run(ctx), "paused")
  local part = digs(sim)
  eq(part, 5)
  ok(T.job.get(), "job saved")
  -- reboot: fresh in-memory state, same computer
  T.unloadForTest()
  local ctx2 = assert(bore.build({ "6", "1", "2", "--yes" }, io, false))
  eq(E.run(ctx2), true)
  eq(digs(sim), 12, "each block dug exactly once")
  eq(sim:countBlocks(nil, 0, 0, -6, 0, 1, -1), 0)
  eq({ sim:where() }, { 0, 0, 0, 0 })
  ok(io.said[#io.said - 0] and true)
  local resumed = false
  for _, l in ipairs(io.said) do if l:find("Resuming") then resumed = true end end
  ok(resumed, "user is told the job resumed")
  eq(T.job.get(), nil)
  done(sim)
end)

test("a different job does not resume an old one", function()
  local sim = fresh()
  sim:fill(0, 0, -6, 0, 1, -1, "minecraft:stone")
  local io = testIo()
  local ctx = assert(bore.build({ "6", "1", "2", "--yes" }, io, false))
  ctx.stopAfter = 3
  eq(E.run(ctx), "paused")
  T.unloadForTest()
  local other = assert(bore.build({ "4", "1", "2", "--yes" }, io, false))
  eq(E.run(other), true)
  for _, l in ipairs(io.said) do ok(not l:find("Resuming")) end
  done(sim)
end)

test("a full inventory is emptied into the chest behind the start", function()
  local sim = fresh()
  sim:fill(0, 0, -5, 4, 2, -1, "minecraft:stone")
  sim:set(0, 0, 1, "minecraft:chest")
  for slot = 1, 15 do sim:give("minecraft:diamond", 64, slot) end
  local io = testIo()
  local ctx = assert(bore.build({ "5", "5", "3", "--dump", "back", "--yes", "--no-torch" }, io, false))
  eq(E.run(ctx), true)
  eq(sim:countBlocks(nil, 0, 0, -5, 4, 2, -1), 0)
  ok(sim:chestCount(0, 0, 1) > 0, "chest received items")
  eq(sim:chestCount(0, 0, 1, "minecraft:diamond"), 15 * 64)
  eq(sim:itemCount("minecraft:cobblestone") + sim:chestCount(0, 0, 1, "minecraft:cobblestone"), 75)
  eq({ sim:where() }, { 0, 0, 0, 0 })
  done(sim)
end)

test("with no chest the turtle waits for the player to empty it", function()
  local sim = fresh()
  sim:fill(0, 0, -3, 0, 1, -1, "minecraft:stone")
  for slot = 1, 16 do sim:give("minecraft:diamond", 64, slot) end
  local waited = 0
  local io = testIo({ wait = function() waited = waited + 1 sim.inv = {} end })
  local ctx = assert(bore.build({ "3", "1", "2", "--yes", "--no-torch" }, io, false))
  eq(E.run(ctx), true)
  ok(waited >= 1)
  eq(#io.warned, 1, "warns once, not on every poll")
  ok(io.warned[1]:find("full"))
  eq(sim:countBlocks(nil, 0, 0, -3, 0, 1, -1), 0)
  done(sim)
end)

test("--junk throws rubbish away instead of stopping", function()
  local sim = fresh()
  sim:fill(0, 0, -5, 0, 1, -1, "minecraft:stone")
  for slot = 1, 15 do sim:give("minecraft:diamond", 64, slot) end
  local io = testIo({ wait = function() error("should not wait") end })
  local ctx = assert(bore.build({ "5", "1", "2", "--junk", "--yes", "--no-torch" }, io, false))
  eq(E.run(ctx), true)
  eq(sim:countBlocks(nil, 0, 0, -5, 0, 1, -1), 0)
  done(sim)
end)

test("low fuel burns coal from the inventory, and waits for the player if there is none", function()
  local sim = fresh({ fuel = 5 })
  sim:fill(0, 0, -3, 0, 1, -1, "minecraft:stone")
  sim:give("minecraft:coal", 4)
  local ctx = assert(bore.build({ "3", "1", "2", "--yes", "--no-torch" }, testIo(), false))
  eq(E.run(ctx), true)
  ok(sim:itemCount("minecraft:coal") < 4)
  done(sim)

  local sim2 = fresh({ fuel = 5 })
  sim2:fill(0, 0, -3, 0, 1, -1, "minecraft:stone")
  local gave = false
  local io = testIo({ wait = function() if not gave then gave = true sim2:give("minecraft:coal", 2) end end })
  ctx = assert(bore.build({ "3", "1", "2", "--yes", "--no-torch" }, io, false))
  eq(E.run(ctx), true)
  ok(gave and #io.warned >= 1 and io.warned[1]:find("fuel"))
  done(sim2)
end)

test("an unbreakable block stops the job with a clear reason and keeps the progress", function()
  local sim = fresh()
  sim:fill(0, 0, -4, 0, 1, -1, "minecraft:stone")
  sim:set(0, 0, -3, "minecraft:bedrock")
  local ctx = assert(bore.build({ "4", "1", "2", "--yes", "--no-torch" }, testIo(), false))
  local ok2, why = E.run(ctx)
  eq(ok2, false)
  ok(why:find("blocked at step") and why:find("unbreakable"), tostring(why))
  ok(T.job.get(), "job kept so it can be retried after clearing the obstacle")
  done(sim)
end)
