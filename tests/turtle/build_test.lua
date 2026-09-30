-- SPDX-License-Identifier: AGPL-3.0-or-later
local Sim = dofile("/tests/lib/turtlesim.lua")
local T = require("tsr.turtle")
local build = require("tsrapps.build")

local DIR = "/tmp-build"

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
  function io.prompt(_, d) return d end
  function io.ask() return true end
  function io.waitInventory() if hooks and hooks.wait then hooks.wait() end end
  return io
end

test("shapes produce the right cells", function()
  eq(#build.floor(3, 4, "x"), 12)
  eq(#build.wall(5, 3, "x"), 15)
  eq(#build.box(3, 3, 3, "x"), 26, "a 3x3x3 hollow box has 26 shell blocks")
  eq(#build.box(5, 4, 3, "x"), 5 * 4 * 3 - 3 * 2 * 1)
  local cells = build.floor(2, 2, "x")
  eq(cells[1], { f = 1, r = 0, u = 0, block = "x" })
end)

test("block names are normalised", function()
  eq(build.normalize("stone"), "minecraft:stone")
  eq(build.normalize("create:andesite_casing"), "create:andesite_casing")
end)

test("blueprints parse with a legend, layers and skipped cells", function()
  local text = table.concat({
    "# a tiny house",
    "legend",
    "# = stone_bricks",
    "g = minecraft:glass",
    ". = air",
    "layer",
    "###",
    "#.#",
    "layer",
    "#g#",
    "",
  }, "\n")
  local cells, err = build.parseBlueprint(text)
  ok(cells, tostring(err))
  eq(#cells, 8)
  local need = build.materials(cells)
  eq(need["minecraft:stone_bricks"], 7)
  eq(need["minecraft:glass"], 1)
  local found
  for _, c in ipairs(cells) do if c.u == 1 and c.r == 1 then found = c end end
  eq(found, { f = 1, r = 1, u = 1, block = "minecraft:glass" })
end)

test("blueprint errors name the line", function()
  local cells, err = build.parseBlueprint("legend\n# = stone\nlayer\n#x#\n")
  ok(cells == nil and err:find("line 4") and err:find("'x'"))
  cells, err = build.parseBlueprint("nonsense here\nlayer\n#\n")
  ok(cells == nil and err:find("line 1"))
  cells, err = build.parseBlueprint("legend\n# = stone\n")
  ok(cells == nil and err:find("no blocks"))
end)

test("ordering goes layer by layer and snakes the rows", function()
  local cells = build.order(build.floor(2, 3, "x"))
  local seq = {}
  for _, c in ipairs(cells) do seq[#seq + 1] = c.f .. ":" .. c.r end
  eq(seq, { "1:0", "1:1", "1:2", "2:2", "2:1", "2:0" })
  local two = build.order({ { f = 1, r = 0, u = 1, block = "x" }, { f = 1, r = 0, u = 0, block = "x" } })
  eq(two[1].u, 0)
end)

test("build floor places every block from above", function()
  local sim = fresh()
  sim:give("minecraft:stone", 20)
  local io = testIo()
  local ctx = assert(build.build({ "floor", "3", "3", "stone", "--yes" }, io))
  eq(build.run(ctx), true)
  eq(sim:countBlocks("minecraft:stone", 0, 0, -3, 2, 0, -1), 9)
  eq(sim:itemCount("minecraft:stone"), 11)
  eq({ sim:where() }, { 0, 0, 0, 0 })
  eq(T.job.get(), nil)
  done(sim)
end)

test("build box makes a hollow shell with an empty inside", function()
  local sim = fresh()
  sim:give("minecraft:cobblestone", 64)
  local ctx = assert(build.build({ "box", "3", "3", "3", "--yes" }, testIo()))
  eq(build.run(ctx), true)
  eq(sim:countBlocks("minecraft:cobblestone", 0, 0, -3, 2, 2, -1), 26)
  eq(sim:get(1, 1, -2), nil, "the middle stays empty")
  done(sim)
end)

test("build wall runs to the right of the turtle", function()
  local sim = fresh()
  sim:give("minecraft:stone", 30)
  local ctx = assert(build.build({ "wall", "4", "2", "stone", "--yes" }, testIo()))
  eq(build.run(ctx), true)
  eq(sim:countBlocks("minecraft:stone", 0, 0, -1, 3, 1, -1), 8)
  done(sim)
end)

test("build waits for missing materials, then carries on", function()
  local sim = fresh()
  sim:give("minecraft:stone", 3)
  local gave = false
  local io = testIo({ wait = function() if not gave then gave = true sim:give("minecraft:stone", 10) end end })
  local ctx = assert(build.build({ "floor", "3", "3", "stone", "--yes" }, io))
  eq(build.run(ctx), true)
  ok(gave and #io.warned == 1 and io.warned[1]:find("6 x minecraft:stone"), tostring(io.warned[1]))
  eq(sim:countBlocks("minecraft:stone", 0, 0, -3, 2, 0, -1), 9)
  done(sim)
end)

test("--nowait stops with a materials list instead", function()
  local sim = fresh()
  sim:give("minecraft:stone", 2)
  local ctx = assert(build.build({ "floor", "3", "3", "stone", "--nowait" }, testIo()))
  local ok2, why = build.run(ctx)
  eq(ok2, false)
  ok(why:find("missing materials") and why:find("7 x minecraft:stone"))
  eq(sim:countBlocks(nil, -5, -5, -5, 5, 5, 5), 0, "nothing was placed")
  done(sim)
end)

test("existing blocks are kept unless --replace", function()
  local sim = fresh()
  sim:give("minecraft:stone", 20)
  sim:set(0, 0, -1, "minecraft:dirt")
  local ctx = assert(build.build({ "floor", "2", "1", "stone", "--yes" }, testIo()))
  eq(build.run(ctx), true)
  eq(sim:get(0, 0, -1), "minecraft:dirt")
  eq(sim:get(0, 0, -2), "minecraft:stone")
  local sim2 = fresh()
  sim2:give("minecraft:stone", 20)
  sim2:set(0, 0, -1, "minecraft:dirt")
  ctx = assert(build.build({ "floor", "2", "1", "stone", "--yes", "--replace" }, testIo()))
  eq(build.run(ctx), true)
  eq(sim2:get(0, 0, -1), "minecraft:stone")
  done(sim2)
end)

test("a build resumes after a restart", function()
  local sim = fresh()
  sim:give("minecraft:stone", 40)
  local io = testIo()
  local ctx = assert(build.build({ "floor", "4", "4", "stone", "--yes" }, io))
  ctx.stopAfter = 6
  eq(build.run(ctx), "paused")
  eq(sim:countBlocks("minecraft:stone", 0, 0, -4, 3, 0, -1), 6)
  T.unloadForTest()
  local ctx2 = assert(build.build({ "floor", "4", "4", "stone", "--yes" }, io))
  eq(build.run(ctx2), true)
  eq(sim:countBlocks("minecraft:stone", 0, 0, -4, 3, 0, -1), 16)
  eq(sim:itemCount("minecraft:stone"), 24, "no block was placed twice")
  done(sim)
end)

test("build from a blueprint file", function()
  local sim = fresh()
  sim:give("minecraft:stone_bricks", 20)
  sim:give("minecraft:glass", 4)
  local text = "legend\n# = stone_bricks\ng = glass\nlayer\n###\n#g#\n"
  local ctx = assert(build.build({ "file", "plan.txt", "--yes" }, testIo(), function(path) return path == "plan.txt" and text or nil end))
  eq(build.run(ctx), true)
  eq(sim:get(1, 0, -2), "minecraft:glass")
  eq(sim:get(0, 0, -1), "minecraft:stone_bricks")
  eq(sim:countBlocks(nil, 0, 0, -2, 2, 0, -1), 6)
  done(sim)
end)

test("bad build commands explain the usage", function()
  local io = testIo()
  local bad, err = build.build({ "floor", "3" }, io)
  ok(bad == nil and err:find("usage"))
  bad, err = build.build({ "pyramid", "3", "3" }, io)
  ok(bad == nil and err:find("usage"))
  bad, err = build.build({ "file", "missing.txt" }, io, function() return nil end)
  ok(bad == nil and err:find("cannot read"))
end)
