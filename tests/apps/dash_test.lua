-- SPDX-License-Identifier: AGPL-3.0-or-later
local F = dofile("/tests/lib/fakes.lua")
local hal = require("tsr.hal")
local dash = require("tsr.hal.dash")

local function cell(stored, cap)
  local c = { _type = "energy_storage", stored = stored }
  function c.getEnergy() return c.stored end
  function c.getEnergyCapacity() return cap end
  return c
end

local function tank(name, amount)
  local t = { _type = "fluid_storage", amount = amount }
  function t.tanks() return { { name = name, amount = t.amount } } end
  return t
end

local function env(devices, extra)
  hal.reset()
  dash.resetHistory()
  local e = { peripheral = F.peripheralApi(devices), redstone = F.redstone(), devicesPath = "/tmp-dash/none" }
  for k, v in pairs(extra or {}) do e[k] = v end
  return e
end

test("power rows carry fill, capacity and units", function()
  local e = env({ a = cell(250, 1000), b = cell(5000000, 10000000) })
  local rows = dash.sample("power", e, 100)
  eq(#rows, 2)
  eq({ rows[1].name, rows[1].percent, rows[1].unit }, { "a", 25, "FE" })
  eq(rows[2].percent, 50)
end)

test("trend and time to full or empty", function()
  local c = cell(500, 1000)
  local e = env({ a = c })
  eq(dash.sample("power", e, 100)[1].rate, nil, "one sample is not a trend")
  c.stored = 600
  local row = dash.sample("power", e, 110)[1]
  eq(row.rate, 10)
  eq(row.eta, 40, "400 FE missing at 10 FE/s")
  c.stored = 500
  row = dash.sample("power", e, 120)[1]
  ok(row.rate == 0, "average over the window is flat again: " .. tostring(row.rate))
  c.stored = 300
  row = dash.sample("power", e, 130)[1]
  ok(row.rate < 0)
  ok(row.eta > 0, "time to empty is positive")
end)

test("the history window is bounded", function()
  local c = cell(0, 1000)
  local e = env({ a = c })
  for t = 1, 40 do
    c.stored = t
    dash.sample("power", e, t)
  end
  c.stored = 41
  eq(dash.sample("power", e, 41)[1].rate, 1)
end)

test("tanks list fluid amounts and names", function()
  local e = env({ t1 = tank("minecraft:water", 4000), t2 = tank("minecraft:lava", 0) })
  local rows = dash.sample("tanks", e, 0)
  eq(#rows, 2)
  eq({ rows[1].value, rows[1].fluid, rows[1].unit }, { 4000, "minecraft:water", "mB" })
  eq(rows[2].fluid, "empty")
  ok(dash.line(rows[1], 60):find("water", 1, true))
end)

test("unreadable devices are shown, not fatal", function()
  local broken = { _type = "energy_storage", getEnergy = function() error("gone", 0) end, getEnergyCapacity = function() return 1 end }
  local rows = dash.sample("power", env({ b = broken }), 0)
  eq(rows[1].error, true)
  ok(dash.line(rows[1], 40):find("unreadable", 1, true))
end)

test("formatting helpers", function()
  eq(dash.fmt(950), "950")
  eq(dash.fmt(12500), "12.5k")
  eq(dash.fmt(2500000), "2.50M")
  eq(dash.fmt(3e9), "3.00G")
  eq(dash.fmt(1.25), "1.2")
  eq(dash.duration(45), "45s")
  eq(dash.duration(125), "2m05s")
  eq(dash.duration(7500), "2h05m")
  eq(dash.duration(1e7), ">2d")
  eq(dash.bar(10, 50), "#####-----")
  eq(dash.bar(4, 0), "----")
  eq(dash.bar(4, 150), "####")
end)

test("lines fit the width", function()
  local row = { name = "a-very-long-device-name", value = 123456, capacity = 1000000, percent = 12.3456, unit = "FE", rate = 12.5, eta = 5000 }
  for _, w in ipairs({ 30, 51, 80 }) do
    ok(#dash.line(row, w) <= w, w)
  end
  ok(dash.line(row, 80):find("12%%"))
  ok(dash.line(row, 80):find("full", 1, true))
end)

test("rendering to a monitor and the commands", function()
  local mon = F.monitor(60, 6)
  local e = env({ a = cell(100, 1000), screen = mon, t1 = tank("minecraft:water", 500) })
  local io = { said = {}, errs = {} }
  function io.say(t) io.said[#io.said + 1] = t end
  function io.err(t) io.errs[#io.errs + 1] = t end
  ok(dash.run("power", { "--monitor", "screen" }, io, e))
  local text = mon.text()
  ok(text:find("POWER", 1, true) and text:find("a ", 1, true) and text:find("10%%"), text)
  ok(dash.run("tanks", { "--monitor", "screen" }, io, e))
  ok(mon.text():find("TANKS", 1, true) and mon.text():find("water", 1, true))
  -- plain output on the terminal
  ok(dash.run("power", {}, io, e))
  ok(io.said[1]:find("a ", 1, true), io.said[1])
  -- errors
  eq(dash.run("power", { "--monitor", "ghost" }, io, e), false)
  eq(dash.run("power", { "sideways" }, io, e), false)
  -- nothing to show
  local empty = env({})
  local io2 = { said = {}, errs = {} }
  function io2.say(t) io2.said[#io2.said + 1] = t end
  function io2.err(t) io2.errs[#io2.errs + 1] = t end
  ok(dash.run("power", {}, io2, empty))
  eq(io2.said[1], "No energy storage found.")
end)

test("watch mode refreshes until a key is pressed", function()
  local mon = F.monitor(40, 4)
  local c = cell(100, 1000)
  local e = env({ a = c, screen = mon }, { maxRounds = 2 })
  local io = { said = {}, errs = {} }
  function io.say(t) io.said[#io.said + 1] = t end
  function io.err(t) io.errs[#io.errs + 1] = t end
  local done
  parallel.waitForAll(
    function() done = dash.run("power", { "watch", "--monitor", "screen" }, io, e) end,
    function() sleep(0.1) end)
  ok(done)
  -- a key press ends an unbounded watch
  local e2 = env({ a = c, screen = mon })
  local result
  parallel.waitForAll(
    function() result = dash.run("power", { "watch", "--monitor", "screen" }, io, e2) end,
    function() sleep(0.2) os.queueEvent("key", keys.q) end)
  ok(result)
end)
