-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Hardware probe against emulated peripherals (CraftOS-PC's periphemu). Skipped when the emulator API is missing;
-- monitors are unavailable in headless mode, so they are only checked when they can be created.
local hw = require("tsr.hw")

local function attach(side, kind)
  if not periphemu then skip("periphemu not available") end
  local ok = pcall(periphemu.create, side, kind)
  return ok
end

local function detach(side)
  if periphemu then pcall(periphemu.remove, side) end
end

test("probe reports the basics without any peripherals", function()
  local p = hw.probe()
  eq(p.computer.kind, "computer")
  ok(p.computer.id ~= nil)
  ok(type(p.screen.width) == "number" and p.screen.height > 0)
  ok(type(p.storage.free) == "number")
  eq(p.http.enabled, http ~= nil)
  ok(type(p.counts.monitors) == "number")
end)

test("probe finds speakers, drives, modems (and monitors when available)", function()
  local hasMonitor = attach("top", "monitor")
  ok(attach("left", "speaker"), "speaker")
  ok(attach("right", "drive"), "drive")
  ok(attach("back", "modem"), "modem")
  local p = hw.probe()
  eq(p.counts.speakers, 1)
  eq(p.counts.drives, 1)
  eq(p.counts.wirelessModems + p.counts.wiredModems, 1)
  ok(p.hasModem)
  eq(p.counts.monitors, hasMonitor and 1 or 0)
  if hasMonitor then
    local mon = hw.ofType(p, "monitor")[1]
    ok(mon.width and mon.width > 0, "monitor size should be probed")
    ok(mon.methods.getSize, "methods are recorded")
  end
  local speaker = hw.ofType(p, "speaker")[1]
  ok(speaker.methods.playNote, "speaker methods are recorded")
  ok((hw.hasTypeMatching(p, "^spea")))
  ok(not (hw.hasTypeMatching(p, "^nonexistent")))
  for _, s in ipairs({ "top", "left", "right", "back" }) do detach(s) end
  eq(hw.probe().counts.speakers, 0)
end)

test("wireless vs wired modems are told apart", function()
  ok(attach("back", "modem"))
  local p = hw.probe()
  local modem = hw.ofType(p, "modem")[1]
  ok(modem ~= nil)
  eq(type(modem.wireless), "boolean")
  detach("back")
end)

test("httpReach returns booleans per URL", function()
  if not http then skip("no http") end
  local res = hw.httpReach({ "https://pastebin.com" })
  eq(type(res["https://pastebin.com"]), "boolean")
end)
