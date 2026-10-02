-- SPDX-License-Identifier: AGPL-3.0-or-later
local F = dofile("/tests/lib/fakes.lua")
local hal = require("tsr.hal")

local function env(devices)
  hal.reset()
  return { peripheral = F.peripheralApi(devices), redstone = F.redstone(), devicesPath = "/tmp-hal-toms/none" }
end

local function rsPort()
  local p = { _type = "tm_rsPort", out = {}, bundled = {}, inputs = { north = 7, up = 15 } }
  function p.getSides() return { "down", "up", "north", "south", "west", "east" } end
  function p.getAnalogInput(side) return p.inputs[side] or 0 end
  function p.getAnalogOutput(side) return p.out[side] or 0 end
  function p.getBundledInput(side) return side == "up" and 5 or 0 end
  function p.getBundledOutput(side) return p.bundled[side] or 0 end
  function p.testBundledInput(side, mask) return side == "up" and bit32.band(5, mask) == mask end
  function p.setOutput(side, v) p.out[side] = v and 15 or 0 end
  function p.setAnalogOutput(side, n) p.out[side] = n end
  function p.setBundledOutput(side, mask) p.bundled[side] = mask end
  return p
end

local function gpu()
  local g = { _type = "tm_gpu", calls = {} }
  local function rec(name) return function(...) g.calls[#g.calls + 1] = { name, ... } end end
  function g.getSize() return 320, 192, 5, 3, 2 end
  function g.getUsedMemory() return 2048 end
  function g.getMaxMemory() return 8192 end
  for _, n in ipairs({ "fill", "filledRectangle", "rectangle", "line", "drawText", "sync", "setSize", "refreshSize" }) do g[n] = rec(n) end
  return g
end

test("the redstone port: both naming styles of sides, analog, bundled", function()
  local e = env({ port = rsPort() })
  hal.loadDrivers()
  local d = hal.get("port", e)
  ok(d:has("redstone") and d:has("bundled_redstone"))
  eq(d:get("redstone.sides"), { "down", "up", "north", "south", "west", "east" })
  eq({ d:get("redstone.input", "north") }, { 7, "level" })
  eq({ d:get("redstone.input", "top") }, { 15, "level" }, "top means up")
  eq(d:get("redstone.input", "south"), 0)
  eq(d:get("redstone.bundled_input", "up"), 5)
  ok(d:get("redstone.bundled_test", "up", 4))
  ok(not d:get("redstone.bundled_test", "up", 2))
  ok(d:act("redstone.set", "east", true))
  eq(d:get("redstone.output", "east"), 15)
  ok(d:act("redstone.set", "bottom", 9))
  eq(d:get("redstone.output", "down"), 9)
  ok(d:act("redstone.set", "west", 99))
  eq(d:get("redstone.output", "west"), 15, "levels are clamped")
  ok(d:act("redstone.bundled", "up", 1 + 8))
  eq(d:get("redstone.bundled_output", "up"), 9)
end)

test("the GPU draws and shows what was drawn", function()
  local g = gpu()
  local e = env({ gpu = g })
  hal.loadDrivers()
  local d = hal.get("gpu", e)
  ok(d:has("display") and d:has("gpu"))
  eq(d:get("display.size"), "320x192")
  eq({ d:get("gpu.memory_percent") }, { 25, "%" })
  ok(d:act("display.clear"))
  eq(g.calls[1][1], "fill")
  eq(g.calls[2][1], "sync")
  g.calls = {}
  ok(d:act("display.text", 4, 8, "hi", 0xFF0000))
  eq(g.calls[1], { "drawText", 4, 8, "hi", 0xFF0000, 0 })
  eq(g.calls[2][1], "sync")
  g.calls = {}
  ok(d:act("display.rect", 1, 2, 30, 20, 0x00FF00))
  eq(g.calls[1], { "filledRectangle", 1, 2, 30, 20, 0x00FF00 })
  g.calls = {}
  ok(d:act("display.rect", 1, 2, 30, 20, 0x00FF00, true))
  eq(g.calls[1][1], "rectangle")
  g.calls = {}
  ok(d:act("display.resolution", 2))
  eq(g.calls[1], { "setSize", 2 })
  ok(d:act("display.refresh"))
  eq(g.calls[2], { "refreshSize" })
end)

test("the watch dog timer and the keyboard", function()
  local wdt = { _type = "tm_wdt", enabled = false, timeout = 100, resets = 0 }
  function wdt.isEnabled() return wdt.enabled end
  function wdt.getTimeout() return wdt.timeout end
  function wdt.setEnabled(v) wdt.enabled = v end
  function wdt.setTimeout(n) wdt.timeout = n end
  function wdt.reset() wdt.resets = wdt.resets + 1 end
  local kb = { _type = "tm_keyboard" }
  function kb.setFireNativeEvents(v) kb.native = v end
  local e = env({ dog = wdt, kb = kb, other = { _type = "monitor", getSize = function() return 1, 1 end } })
  hal.loadDrivers()
  local d = hal.get("dog", e)
  ok(d:has("watchdog"))
  eq(d:get("watchdog.enabled"), false)
  ok(d:act("watchdog.enable"))
  ok(wdt.enabled)
  ok(d:act("watchdog.timeout", 600))
  eq(d:get("watchdog.timeout"), 600)
  ok(d:act("watchdog.feed"))
  ok(d:act("watchdog.reset"))
  eq(wdt.resets, 2)
  ok(d:act("watchdog.enable", false))
  ok(not wdt.enabled)
  local k = hal.get("kb", e)
  ok(k:has("input"))
  ok(k:act("input.native_events", true))
  eq(kb.native, true)
  ok(k:act("input.native_events", false))
  eq(kb.native, false)
  eq(#hal.find("watchdog", e), 1)
  eq(#hal.find("gpu", e), 0)
end)
