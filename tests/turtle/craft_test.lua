-- SPDX-License-Identifier: AGPL-3.0-or-later
local Sim = dofile("/tests/lib/turtlesim.lua")
local craft = require("tsr.craft")
local cli = require("tsr.craftcli")
local vfs = require("tsr.vfs")

local STASH = "0,-1,0"

--- A turtle with a stash chest below it holding `items` ({ {name, count}, ... }) and the given crafting recipes (exact names).
local function setup(items, recipes)
  local sim = Sim.new({ unlimited = true })
  sim:set(0, -1, 0, "minecraft:chest")
  sim.chests[STASH] = items or {}
  for _, r in ipairs(recipes or {}) do sim:addRecipe(r) end
  return sim
end

local function stashCounts(sim)
  local out = {}
  for _, it in ipairs(sim.chests[STASH]) do out[it.name] = (out[it.name] or 0) + it.count end
  return out
end

local function carried(sim)
  local out = {}
  for _, it in pairs(sim.inv) do out[it.name] = (out[it.name] or 0) + it.count end
  return out
end

local SIM_RECIPES = {
  { out = "minecraft:stick", count = 4, shape = { "P", "P" }, key = { P = "minecraft:oak_planks" } },
  { out = "minecraft:oak_planks", count = 4, shapeless = { "minecraft:oak_log" } },
  { out = "minecraft:torch", count = 4, shape = { "C", "S" }, key = { C = "minecraft:coal", S = "minecraft:stick" } },
  { out = "minecraft:furnace", count = 1, shape = { "CCC", "C C", "CCC" }, key = { C = "minecraft:cobblestone" } },
  { out = "minecraft:crafting_table", count = 1, shape = { "PP", "PP" }, key = { P = "minecraft:oak_planks" } },
  { out = "minecraft:stone_pickaxe", count = 1, shape = { "MMM", " S ", " S " }, key = { M = "minecraft:cobblestone", S = "minecraft:stick" } },
}

local db = craft.load()

test("the shipped vanilla recipes load and parse", function()
  ok(#db.problems == 0, table.concat(db.problems, "; "))
  local n = 0
  for _ in pairs(db.recipes) do n = n + 1 end
  ok(n > 150, "recipes: " .. n)
  eq(db.recipes["minecraft:stick"][1].count, 4)
  eq(db.recipes["minecraft:furnace"][1].cells[5], nil, "the middle of a furnace is empty")
  eq(db.recipes["minecraft:furnace"][1].cells[1], "#cobble")
  ok(craft.matches(db, "#planks", "minecraft:spruce_planks"))
  ok(not craft.matches(db, "#planks", "minecraft:spruce_log"))
  ok(craft.matches(db, "#cobble", "minecraft:blackstone"))
  ok(craft.matches(db, { any = { "a", "#coals" } }, "minecraft:charcoal"))
  ok(not craft.matches(db, "#nonsense", "x"))
  ok(select(2, craft.normalize({ out = "x", shape = { "AB" }, key = { A = "a" } })), "an ingredient without a key is refused")
  ok(select(2, craft.normalize({ out = "x", shape = { "ABCD" }, key = {} })))
  ok(select(2, craft.normalize({ out = "x", shapeless = {} })))
end)

test("planning: simple, chained, tags, surplus reuse, alternatives, missing materials", function()
  -- sticks from any planks
  local steps, missing = craft.plan(db, "minecraft:stick", 8, { ["minecraft:spruce_planks"] = 4 })
  ok(not missing)
  eq(#steps, 1)
  eq(steps[1].times, 2)
  eq(steps[1].picks["#planks"], "minecraft:spruce_planks")
  -- torches need coal and a stick; the stick comes from planks which come from logs
  steps, missing = craft.plan(db, "minecraft:torch", 4, { ["minecraft:coal"] = 1, ["minecraft:oak_log"] = 1 })
  ok(not missing, missing and next(missing))
  local outs = {}
  for _, s in ipairs(steps) do outs[#outs + 1] = s.out end
  eq(outs, { "minecraft:oak_planks", "minecraft:stick", "minecraft:torch" })
  -- sticks are made 4 at a time: planning 3 torch batches (12 torches) needs 3 sticks, from ONE stick craft
  steps, missing = craft.plan(db, "minecraft:torch", 12, { ["minecraft:coal"] = 3, ["minecraft:oak_planks"] = 2 })
  ok(not missing)
  local stickCrafts = 0
  for _, s in ipairs(steps) do if s.out == "minecraft:stick" then stickCrafts = stickCrafts + s.times end end
  eq(stickCrafts, 1)
  -- a furnace from cobblestone of any kind
  steps, missing = craft.plan(db, "minecraft:furnace", 1, { ["minecraft:cobbled_deepslate"] = 8 })
  ok(not missing)
  eq(steps[1].picks["#cobble"], "minecraft:cobbled_deepslate")
  -- not enough: the missing amount is reported, nothing half-planned
  steps, missing = craft.plan(db, "minecraft:furnace", 1, { ["minecraft:cobblestone"] = 5 })
  ok(missing and missing["#cobble"] == 3 or missing["minecraft:cobblestone"] == 3, missing and (next(missing)))
  steps, missing = craft.plan(db, "mod:unobtainium", 1, {})
  ok(missing and missing["mod:unobtainium"] == 1)
  -- a pickaxe: stone and sticks, sticks from logs via planks
  steps, missing = craft.plan(db, "minecraft:stone_pickaxe", 1, { ["minecraft:cobblestone"] = 3, ["minecraft:birch_log"] = 1 })
  ok(not missing, missing and next(missing))
  eq(steps[#steps].out, "minecraft:stone_pickaxe")
  -- a recipe cycle (blocks <-> ingots) does not loop forever
  steps, missing = craft.plan(db, "minecraft:iron_ingot", 3, {})
  ok(missing ~= nil)
end)

test("crafting with a stash: sticks from planks, the leftovers stay in the stash", function()
  local sim = setup({ { name = "minecraft:oak_planks", count = 10 }, { name = "minecraft:dirt", count = 5 } }, SIM_RECIPES)
  sim.selected = 1
  local ok1, err = craft.make("minecraft:stick", 8, { turtle = sim.turtle, db = db })
  ok(ok1, err)
  local stash = stashCounts(sim)
  eq(stash["minecraft:stick"], 8)
  eq(stash["minecraft:oak_planks"], 6, "each stick craft uses two planks (one per cell): 2 crafts = 4")
  eq(stash["minecraft:dirt"], 5, "unrelated items are untouched")
  eq(next(carried(sim)), nil, "the turtle ends up empty")
end)

test("crafting chains: torches from coal, logs and nothing else", function()
  local sim = setup({ { name = "minecraft:oak_log", count = 3 }, { name = "minecraft:coal", count = 2 } }, SIM_RECIPES)
  local logs = {}
  local ok1, err = craft.make("minecraft:torch", 8, { turtle = sim.turtle, db = db, log = function(t) logs[#logs + 1] = t end })
  ok(ok1, err)
  local stash = stashCounts(sim)
  eq(stash["minecraft:torch"], 8)
  eq(stash["minecraft:coal"], nil, "both coal were used")
  eq(#logs, 3, "planks, sticks, torches")
  ok(logs[1]:find("oak_planks", 1, true) and logs[3]:find("torch", 1, true))
  eq(stash["minecraft:stick"], 2, "a craft makes 4 sticks, 2 were needed")
  eq(stash["minecraft:oak_log"], 2)
end)

test("the ingredient hides behind other items in the stash and in the way", function()
  local items = {}
  for i = 1, 5 do items[#items + 1] = { name = "minecraft:junk" .. i, count = 3 } end
  items[#items + 1] = { name = "minecraft:cobblestone", count = 64 }
  items[#items + 1] = { name = "minecraft:cobblestone", count = 20 }
  local sim = setup(items, SIM_RECIPES)
  local ok1, err = craft.make("minecraft:furnace", 3, { turtle = sim.turtle, db = db })
  ok(ok1, err)
  local stash = stashCounts(sim)
  eq(stash["minecraft:furnace"], 3)
  eq(stash["minecraft:cobblestone"], 84 - 24)
  for i = 1, 5 do eq(stash["minecraft:junk" .. i], 3) end
  eq(next(carried(sim)), nil)
end)

test("large orders are crafted in several batches", function()
  local sim = setup({ { name = "minecraft:oak_planks", count = 64 }, { name = "minecraft:oak_planks", count = 64 } }, SIM_RECIPES)
  local ok1, err = craft.make("minecraft:stick", 200, { turtle = sim.turtle, db = db })
  ok(ok1, err)
  eq(stashCounts(sim)["minecraft:stick"], 200)
  eq(stashCounts(sim)["minecraft:oak_planks"], 128 - 100)
end)

test("missing materials are reported and nothing is lost", function()
  local sim = setup({ { name = "minecraft:cobblestone", count = 5 }, { name = "minecraft:dirt", count = 1 } }, SIM_RECIPES)
  local ok1, err = craft.make("minecraft:furnace", 1, { turtle = sim.turtle, db = db })
  ok(ok1 == nil and err:find("missing:", 1, true), tostring(err))
  eq(stashCounts(sim)["minecraft:cobblestone"], 5)
  eq(next(carried(sim)), nil)
  -- a turtle without a crafting table says so
  local sim2 = setup({ { name = "minecraft:oak_planks", count = 4 } }, SIM_RECIPES)
  local t2 = {}
  for k, v in pairs(sim2.turtle) do if k ~= "craft" then t2[k] = v end end
  local ok2, err2 = craft.make("minecraft:stick", 4, { turtle = t2, db = db })
  ok(ok2 == nil and err2:find("crafting table", 1, true), tostring(err2))
  -- a full or missing stash
  local sim3 = Sim.new({ unlimited = true })
  sim3:addRecipe(SIM_RECIPES[1])
  sim3:give("minecraft:oak_planks", 4)
  local ok3, err3 = craft.make("minecraft:stick", 4, { turtle = sim3.turtle, db = db })
  ok(ok3 == nil, "no stash chest: " .. tostring(err3))
end)

test("a source chest is emptied into the stash first", function()
  local sim = setup({}, SIM_RECIPES)
  sim:set(0, 1, 0, "minecraft:chest")
  sim.chests["0,1,0"] = { { name = "minecraft:oak_planks", count = 6 } }
  local ok1, err = craft.make("minecraft:crafting_table", 1, { turtle = sim.turtle, db = db, source = "up" })
  ok(ok1, err)
  eq(stashCounts(sim)["minecraft:crafting_table"], 1)
  eq(#sim.chests["0,1,0"], 0, "the source chest is empty now")
end)

test("learning a recipe from the grid, shaped and shapeless; the learned file feeds the database", function()
  local sim = setup({}, {
    { out = "mod:gizmo", count = 2, shape = { "AB", "B " }, key = { A = "mod:cog", B = "mod:plate" } },
    { out = "mod:dust", count = 3, shapeless = { "mod:ore", "mod:hammer" } },
  })
  -- gizmo placed in the middle of the grid: the layout is trimmed to its bounding box
  sim:give("mod:cog", 1, 6) sim:give("mod:plate", 1, 7) sim:give("mod:plate", 1, 10)
  local doc, err = craft.learn({ turtle = sim.turtle }, {})
  ok(doc, err)
  local r = doc.recipes[1]
  eq(r.out, "mod:gizmo")
  eq(r.count, 2)
  eq(r.shape, { "AB", "B " })
  eq(r.key, { A = "mod:cog", B = "mod:plate" })
  -- the learned recipe is usable by the planner
  local own = craft.load({})
  craft.add(own, doc, "learned")
  local steps, missing = craft.plan(own, "mod:gizmo", 4, { ["mod:cog"] = 2, ["mod:plate"] = 4 })
  ok(not missing)
  eq(steps[1].times, 2)
  -- shapeless
  local sim2 = setup({}, { { out = "mod:dust", count = 3, shapeless = { "mod:ore", "mod:hammer" } } })
  sim2:give("mod:ore", 1, 1) sim2:give("mod:hammer", 1, 11)
  local d2 = assert(craft.learn({ turtle = sim2.turtle }, { shapeless = true }))
  eq(d2.recipes[1].shapeless, { "mod:ore", "mod:hammer" })
  -- errors
  local sim3 = setup({}, SIM_RECIPES)
  ok(select(2, craft.learn({ turtle = sim3.turtle }, {})):find("grid", 1, true))
  sim3:give("minecraft:dirt", 1, 1)
  ok(select(2, craft.learn({ turtle = sim3.turtle }, {})):find("does not craft", 1, true))
  -- serialising gives a loadable file
  local text = craft.serialize(doc)
  local back = assert(load(text, "learned", "t", {}))()
  eq(back.recipes[1].out, "mod:gizmo")
end)

local function io()
  local t = { lines = {}, errs = {} }
  function t.say(s) t.lines[#t.lines + 1] = s end
  function t.err(s) t.errs[#t.errs + 1] = s end
  function t.text() return table.concat(t.lines, "\n") end
  return t
end

test("the craft command: list, plan, make, learn, forget", function()
  cli.LEARNED = "/tmp-craft-learned"
  if fs.exists(cli.LEARNED) then fs.delete(cli.LEARNED) end
  local sim = setup({ { name = "minecraft:cobblestone", count = 16 } }, SIM_RECIPES)
  local o = io()
  ok(cli.run({ "list", "furnace" }, o, { turtle = sim.turtle }))
  ok(o.text():find("minecraft:furnace", 1, true) and o.text():find("blast_furnace", 1, true), o.text())
  o = io()
  ok(cli.run({ "plan", "furnace", "2" }, o, { turtle = sim.turtle }), table.concat(o.errs, "|"))
  ok(o.text():find("craft 2 x minecraft:furnace", 1, true), o.text())
  o = io()
  ok(not cli.run({ "plan", "furnace", "3" }, o, { turtle = sim.turtle }))
  ok(o.text():find("missing", 1, true), o.text())
  o = io()
  ok(cli.run({ "furnace", "2" }, o, { turtle = sim.turtle }), table.concat(o.errs, "|"))
  eq(stashCounts(sim)["minecraft:furnace"], 2)
  o = io()
  ok(not cli.run({ "unobtainium" }, o, { turtle = sim.turtle }))
  ok(o.errs[1]:find("no recipe", 1, true), o.errs[1])
  o = io()
  ok(not cli.run({ "stone" }, o, { turtle = sim.turtle }), "an ambiguous name")
  ok(o.errs[1]:find("could be", 1, true), o.errs[1])
  eq(cli.itemName(db, "pickaxe"), nil)
  eq(cli.itemName(db, "stone_pickaxe"), "minecraft:stone_pickaxe")
  -- learn then forget
  local sim2 = setup({}, { { out = "mod:gizmo", count = 1, shape = { "A" }, key = { A = "mod:cog" } } })
  sim2:give("mod:cog", 3, 1)
  o = io()
  ok(cli.run({ "learn" }, o, { turtle = sim2.turtle }), table.concat(o.errs, "|"))
  ok(o.text():find("mod:gizmo", 1, true))
  ok(fs.exists(cli.LEARNED .. "/mod_gizmo.lua"))
  local mine = craft.load({ cli.LEARNED })
  ok(mine.recipes["mod:gizmo"])
  o = io()
  ok(cli.run({ "forget", "mod:gizmo" }, o, { turtle = sim2.turtle, db = mine }), table.concat(o.errs, "|"))
  ok(not fs.exists(cli.LEARNED .. "/mod_gizmo.lua"))
  fs.delete(cli.LEARNED)
end)
