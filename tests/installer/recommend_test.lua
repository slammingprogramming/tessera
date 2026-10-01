-- SPDX-License-Identifier: AGPL-3.0-or-later
local recommend = require("tsr.setup.recommend")

--- Build a fake probe result. spec: kind, advanced, http, peripherals = { {type, wireless=, color=}... }
local function fake(spec)
  local ps = {}
  for i, p in ipairs(spec.peripherals or {}) do
    ps[i] = { name = p.name or (p.type .. i), types = { p.type }, isType = { [p.type] = true },
              wireless = p.wireless, color = p.color }
  end
  local function n(pred) local c = 0 for _, p in ipairs(ps) do if pred(p) then c = c + 1 end end return c end
  local counts = {
    monitors = n(function(p) return p.isType.monitor end),
    advancedMonitors = n(function(p) return p.isType.monitor and p.color end),
    speakers = n(function(p) return p.isType.speaker end),
    wirelessModems = n(function(p) return p.isType.modem and p.wireless end),
    wiredModems = n(function(p) return p.isType.modem and not p.wireless end),
    drives = n(function(p) return p.isType.drive end),
    printers = n(function(p) return p.isType.printer end),
    redstoneRelays = n(function(p) return p.isType.redstone_relay end),
    inventories = n(function(p) return p.isType.inventory end),
    energy = n(function(p) return p.isType.energy_storage end),
    fluid = n(function(p) return p.isType.fluid_storage end),
  }
  return {
    computer = { id = 1, kind = spec.kind or "computer", advanced = spec.advanced ~= false },
    screen = { width = 51, height = 19 },
    http = { enabled = spec.http ~= false },
    storage = { free = 900000 },
    peripherals = ps, counts = counts,
    hasModem = counts.wirelessModems + counts.wiredModems > 0,
  }
end

local function pkgs(items)
  local t = {}
  for _, it in ipairs(items) do t[it.pkg] = it end
  return t
end

local function profileNamed(list, name)
  for _, p in ipairs(list) do if p.name == name then return p end end
end

test("profile follows the computer kind and screen", function()
  eq(recommend.recommend(fake({ advanced = true })).default, "client")
  eq(recommend.recommend(fake({ advanced = false })).default, "client-lite")
  eq(recommend.recommend(fake({ kind = "turtle" })).default, "turtle")
  eq(recommend.recommend(fake({ kind = "pocket" })).default, "pocket")
  eq(recommend.recommend(fake({ kind = "command" })).default, "command")
end)

test("profile list marks impossible choices as blocked with a reason", function()
  local r = recommend.recommend(fake({ advanced = false }))
  ok(profileNamed(r.profiles, "client").blocked:find("advanced"))
  ok(profileNamed(r.profiles, "turtle").blocked)
  ok(profileNamed(r.profiles, "tv").blocked:find("monitor"))
  ok(profileNamed(r.profiles, "client-lite").recommended)
  ok(profileNamed(r.profiles, "client-lite").reason)
end)

test("a monitor unlocks the TV profile and a modem hints at server", function()
  local r = recommend.recommend(fake({ peripherals = { { type = "monitor", color = true }, { type = "speaker" },
                                                        { type = "modem", wireless = true } } }))
  ok(profileNamed(r.profiles, "tv").blocked == nil)
  ok(profileNamed(r.profiles, "tv").reason:find("monitor"))
  ok(profileNamed(r.profiles, "server").reason:find("modem"))
  ok(profileNamed(r.profiles, "server").blocked == nil)
end)

test("turtles and pockets can only choose their own profile", function()
  local r = recommend.recommend(fake({ kind = "turtle" }))
  ok(profileNamed(r.profiles, "client").blocked)
  ok(profileNamed(r.profiles, "server").blocked)
  ok(profileNamed(r.profiles, "turtle").blocked == nil)
end)

test("packages carry reasons and tiers", function()
  local r = recommend.recommend(fake({ peripherals = { { type = "modem", wireless = true }, { type = "speaker" },
                                                        { type = "monitor", color = true }, { type = "drive" } } }))
  local p = pkgs(r.items)
  eq(p["ui-tui"].tier, "recommended")
  eq(p["ui-gui"].tier, "optional")
  eq(p["net"].tier, "recommended")
  ok(p["net"].reason:find("modem"))
  ok(p["audio"] and p["display"] and p["disk-tools"])
  for _, it in ipairs(r.items) do ok(it.reason and it.reason ~= "", it.pkg .. " has no reason") end
end)

test("basic computers are not offered the GUI", function()
  local r = recommend.recommend(fake({ advanced = false }))
  ok(pkgs(r.items)["ui-gui"] == nil)
  ok(pkgs(r.items)["ui-tui"])
end)

test("turtle recommendations", function()
  local r = recommend.recommend(fake({ kind = "turtle", peripherals = { { type = "modem", wireless = true } } }))
  local p = pkgs(r.items)
  eq(p["turtle-core"].tier, "recommended")
  ok(p["turtle-jobs"] and p["gps"])
  ok(p["ui-gui"] == nil)
end)

test("server recommendations include the package mirror when HTTP exists", function()
  local probe = fake({ peripherals = { { type = "modem", wireless = false }, { type = "inventory" }, { type = "inventory" } } })
  local p = pkgs(recommend.packages(probe, "server"))
  eq(p["pkg-mirror"].tier, "recommended")
  eq(p["svc-storage"].tier, "recommended")
  local noHttp = pkgs(recommend.packages(fake({ http = false, peripherals = { { type = "modem" } } }), "server"))
  ok(noHttp["pkg-mirror"] == nil, "no HTTP, nothing to mirror")
end)

test("mod integrations are recommended only when their peripherals exist", function()
  local r = recommend.recommend(fake({ peripherals = { { type = "meBridge" }, { type = "chatBox" } } }))
  local p = pkgs(r.items)
  eq(p["int-ap"].tier, "recommended")
  eq(p["chatbot"].tier, "optional")
  eq(p["hal"].tier, "recommended")
  ok(p["int-mekanism"] == nil and p["int-create"] == nil)
  eq(#r.mods, 1)
  eq(r.mods[1].id, "advancedperipherals")
  local none = recommend.recommend(fake({}))
  eq(#none.mods, 0)
end)

test("generic peripherals map to capability packages", function()
  local r = recommend.recommend(fake({ peripherals = { { type = "energy_storage" }, { type = "fluid_storage" },
                                                        { type = "redstone_relay" } } }))
  local p = pkgs(r.items)
  ok(p["power"] and p["fluids"])
  eq(p["redstone"].tier, "recommended")
end)

test("each recommendation lists a package once (recommended wins over optional)", function()
  local r = recommend.recommend(fake({ peripherals = { { type = "modem" }, { type = "inventory" }, { type = "inventory" } } }))
  local seen = {}
  for _, it in ipairs(r.items) do
    ok(not seen[it.pkg], "duplicate " .. it.pkg)
    seen[it.pkg] = true
  end
end)
