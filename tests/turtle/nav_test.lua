-- SPDX-License-Identifier: AGPL-3.0-or-later
local Sim = dofile("/tests/lib/turtlesim.lua")
local T = require("tsr.turtle")
local nav = require("tsr.turtle.nav")

local DIR = "/tmp-nav"

local function fresh(opts)
  if fs.exists(DIR) then fs.delete(DIR) end
  T.dir = DIR
  T.sleep = function() end
  T.unloadForTest()
  nav.unloadForTest()
  local sim = Sim.new(opts)
  sim:install()
  return sim
end

local function done(sim)
  sim:uninstall()
  nav.unloadForTest()
  if fs.exists(DIR) then fs.delete(DIR) end
end

test("planning on an empty map is the straight shortest path", function()
  local sim = fresh()
  local path = nav.plan(0, 0, 0, 3, 0, -2)
  eq(#path, 5)
  eq(path[#path], { 3, 0, -2 })
  local same = nav.plan(1, 1, 1, 1, 1, 1)
  eq(#same, 0)
  eq(#nav.plan(0, 0, 0, 0, 4, 0), 4, "vertical moves are cells too")
  done(sim)
end)

test("planning goes around known obstacles and fails when walled in", function()
  local sim = fresh()
  -- a wall across z = -2 from x = -1 to 1, at y = 0
  for x = -1, 1 do nav.markBlocked(x, 0, -2, true) end
  local path = nav.plan(0, 0, 0, 0, 0, -4, { margin = 3 })
  ok(path)
  for _, c in ipairs(path) do ok(not nav.isBlocked(c[1], c[2], c[3])) end
  ok(#path > 4, "the detour is longer: " .. #path)
  -- shortest detour goes over (up) or around: length 6 either way
  eq(#path, 6)
  -- a sealed cell cannot be reached
  for _, d in ipairs({ { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }) do
    nav.markBlocked(10 + d[1], d[2], 10 + d[3], true)
  end
  local none, why = nav.plan(0, 0, 0, 10, 0, 10, { margin = 3 })
  ok(none == nil and why == "no path", tostring(why))
  local blockedGoal, why2 = nav.plan(0, 0, 0, 1, 0, -2)
  ok(blockedGoal == nil and why2:find("destination"))
  done(sim)
end)

test("paths prefer going straight", function()
  local sim = fresh()
  local path = nav.plan(0, 0, 0, 4, 0, 4)
  local turns, last = 0, nil
  local px, pz = 0, 0
  for _, c in ipairs(path) do
    local d = (c[1] - px) .. "," .. (c[3] - pz)
    if last and d ~= last then turns = turns + 1 end
    last = d
    px, pz = c[1], c[3]
  end
  ok(turns <= 3, "turns: " .. turns)
  done(sim)
end)

test("goto walks to the destination", function()
  local sim = fresh()
  ok(nav.goto(3, 0, -4))
  eq({ sim:where() }, { 3, 0, -4, sim.dir })
  eq({ T.pos() }, { 3, 0, -4, sim.dir })
  ok(nav.goto(3, 2, -4))
  eq({ sim.x, sim.y, sim.z }, { 3, 2, -4 })
  ok(nav.goto(3, 2, -4), "already there")
  done(sim)
end)

test("goto discovers a hidden wall and walks around it", function()
  local sim = fresh()
  sim:fill(-3, 0, -3, 3, 0, -3, "minecraft:stone")       -- a wall the turtle knows nothing about
  ok(nav.goto(0, 0, -6))
  eq({ sim.x, sim.y, sim.z }, { 0, 0, -6 })
  ok(nav.blockedCount() >= 1, "it remembered what it found")
  ok(nav.isBlocked(0, 0, -3))
  -- the same trip again plans around the remembered wall from the start: no bumping, so no new marks needed
  local before = nav.blockedCount()
  ok(nav.goto(0, 0, 0))
  ok(nav.goto(0, 0, -6))
  eq(nav.blockedCount(), before)
  done(sim)
end)

test("an unreachable destination is reported, not looped on", function()
  local sim = fresh()
  -- enclose (0,0,-3) completely
  sim:fill(-1, -1, -4, 1, 1, -2, "minecraft:stone")
  sim:set(0, 0, -3, nil)
  local ok1, why = nav.goto(0, 0, -3, { maxReplans = 12 })
  ok(ok1 == false and (why == "no path" or why == "too many obstacles"), tostring(why))
  done(sim)
end)

test("with dig, a sealed destination is reached by digging", function()
  local sim = fresh()
  sim:fill(-1, -1, -4, 1, 1, -2, "minecraft:stone")
  sim:set(0, 0, -3, nil)
  ok(nav.goto(0, 0, -3, { dig = true, maxReplans = 12 }))
  eq({ sim.x, sim.y, sim.z }, { 0, 0, -3 })
  done(sim)
end)

test("mobs in the way are fought off, and cells that merely failed expire", function()
  local sim = fresh()
  sim:addMob(0, 0, -1, 1)
  ok(nav.goto(0, 0, -3))
  nav.markBlocked(5, 0, 5, false)
  ok(nav.isBlocked(5, 0, 5))
  local realNow = nav.now
  local t = os.epoch("utc") / 1000
  nav.now = function() return t + nav.FORGET_SECONDS + 1 end
  ok(not nav.isBlocked(5, 0, 5), "expired")
  nav.markBlocked(6, 0, 6, true)
  ok(nav.isBlocked(6, 0, 6), "solid cells do not expire")
  nav.now = realNow
  done(sim)
end)

test("out of fuel stops the walk", function()
  local sim = fresh({ fuel = 2 })
  local r, why = nav.goto(0, 0, -6)
  ok(r == false and why == "out of fuel", tostring(why))
  done(sim)
end)

test("the map is saved and loaded, and old entries are pruned", function()
  local sim = fresh()
  nav.markBlocked(1, 2, 3, true)
  nav.markBlocked(4, 5, 6, false)
  nav.save()
  ok(fs.exists(DIR .. "/map.json"))
  nav.unloadForTest()
  ok(nav.isBlocked(1, 2, 3))
  ok(nav.isBlocked(4, 5, 6))
  nav.markFree(1, 2, 3)
  ok(not nav.isBlocked(1, 2, 3))
  nav.MAX_CELLS = 10
  for i = 1, 30 do nav.markBlocked(100 + i, 0, 0, true) end
  ok(nav.blockedCount() <= 10)
  ok(nav.isBlocked(130, 0, 0), "the newest entries survive")
  ok(not nav.isBlocked(101, 0, 0))
  nav.MAX_CELLS = 5000
  nav.reset()
  eq(nav.blockedCount(), 0)
  ok(not fs.exists(DIR .. "/map.json"))
  done(sim)
end)
