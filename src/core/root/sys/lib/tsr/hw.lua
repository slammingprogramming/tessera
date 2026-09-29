-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Hardware detection. Uses only public CC:T APIs and never assumes a peripheral exists: every call is guarded, so the
-- probe works on basic computers, turtles, pocket computers and command computers alike.
--   local hw = require("tsr.hw").probe({ net = true })
local M = {}

local function try(fn, ...)
  local ok, a, b, c = pcall(fn, ...)
  if ok then return a, b, c end
  return nil
end

local function call(name, method, ...)
  return try(peripheral.call, name, method, ...)
end

local function methodSet(name)
  local set = {}
  for _, m in ipairs(try(peripheral.getMethods, name) or {}) do set[m] = true end
  return set
end

local function describe(name, types, remoteVia)
  local p = { name = name, types = types, remote = remoteVia ~= nil, via = remoteVia }
  local isType = {}
  for _, t in ipairs(types) do isType[t] = true end
  p.isType = isType
  if not remoteVia then p.methods = methodSet(name) end
  if isType.monitor then
    local w, h = call(name, "getSize")
    p.width, p.height = w, h
    p.color = call(name, "isColor") or false
  elseif isType.modem then
    p.wireless = call(name, "isWireless") or false
  elseif isType.drive then
    p.disk = call(name, "isDiskPresent") or false
  elseif isType.inventory then
    p.slots = call(name, "size")
  end
  return p
end

--- Every attached peripheral, including ones reachable through wired modems. Returns array of descriptors.
function M.peripherals()
  local out = {}
  local seen = {}
  for _, name in ipairs(peripheral.getNames()) do
    local types = { try(peripheral.getType, name) }
    if #types == 0 then types = { "unknown" } end
    out[#out + 1] = describe(name, types)
    seen[name] = true
  end
  -- peripherals on wired networks
  local direct = {}
  for _, p in ipairs(out) do direct[#direct + 1] = p end
  for _, p in ipairs(direct) do
    if p.isType.modem and not p.wireless and p.methods and p.methods.getNamesRemote then
      for _, rname in ipairs(call(p.name, "getNamesRemote") or {}) do
        if not seen[rname] then
          seen[rname] = true
          local rtypes = { try(peripheral.getType, rname) }
          if #rtypes == 0 then rtypes = { try(function() return peripheral.call(p.name, "getTypeRemote", rname) end) or "unknown" } end
          out[#out + 1] = describe(rname, rtypes, p.name)
        end
      end
    end
  end
  return out
end

local function countBy(list, pred)
  local n = 0
  for _, p in ipairs(list) do if pred(p) then n = n + 1 end end
  return n
end

--- Test whether the given URLs can be requested (the server's HTTP rules may block hosts). Returns { url = bool }.
function M.httpReach(urls)
  local out = {}
  if not rawget(_G, "http") then return out end
  for _, url in ipairs(urls) do
    out[url] = (try(http.checkURL, url)) == true
  end
  return out
end

--- Full probe. opts.net = true also tests HTTP reachability of opts.urls (default: GitHub Pages, Pastebin, jsDelivr).
function M.probe(opts)
  opts = opts or {}
  local hw = {}
  local kind = "computer"
  if rawget(_G, "turtle") then kind = "turtle"
  elseif rawget(_G, "pocket") then kind = "pocket"
  elseif rawget(_G, "commands") then kind = "command" end
  local w, h = term.getSize()
  hw.computer = {
    id = os.getComputerID(), label = os.getComputerLabel(), kind = kind, advanced = term.isColor(),
    host = rawget(_G, "_HOST"), version = try(os.version),
  }
  hw.screen = { width = w, height = h, color = term.isColor(), mouse = term.isColor() }
  hw.storage = {
    capacity = try(fs.getCapacity, "/"), free = try(fs.getFreeSpace, "/"),
  }
  if type(hw.storage.free) ~= "number" then hw.storage.free = math.huge end
  hw.http = { enabled = rawget(_G, "http") ~= nil, reach = {} }
  if opts.net and hw.http.enabled then
    hw.http.reach = M.httpReach(opts.urls or {
      "https://pastebin.com", "https://cdn.jsdelivr.net",
    })
  end
  if kind == "turtle" then
    hw.turtle = {
      fuel = try(turtle.getFuelLevel), fuelLimit = try(turtle.getFuelLimit),
      left = try(function() return (turtle.getEquippedLeft()) end),
      right = try(function() return (turtle.getEquippedRight()) end),
    }
  end

  hw.peripherals = M.peripherals()
  local ps = hw.peripherals
  hw.counts = {
    monitors = countBy(ps, function(p) return p.isType.monitor end),
    advancedMonitors = countBy(ps, function(p) return p.isType.monitor and p.color end),
    speakers = countBy(ps, function(p) return p.isType.speaker end),
    wirelessModems = countBy(ps, function(p) return p.isType.modem and p.wireless end),
    wiredModems = countBy(ps, function(p) return p.isType.modem and not p.wireless end),
    drives = countBy(ps, function(p) return p.isType.drive end),
    printers = countBy(ps, function(p) return p.isType.printer end),
    redstoneRelays = countBy(ps, function(p) return p.isType.redstone_relay end),
    inventories = countBy(ps, function(p) return p.isType.inventory end),
    energy = countBy(ps, function(p) return p.isType.energy_storage end),
    fluid = countBy(ps, function(p) return p.isType.fluid_storage end),
  }
  hw.hasModem = hw.counts.wirelessModems + hw.counts.wiredModems > 0
  return hw
end

--- All peripherals of a given type name.
function M.ofType(hw, typeName)
  local out = {}
  for _, p in ipairs(hw.peripherals) do
    if p.isType[typeName] then out[#out + 1] = p end
  end
  return out
end

--- Does any peripheral report a type whose name matches the Lua pattern `pat`?
function M.hasTypeMatching(hw, pat)
  for _, p in ipairs(hw.peripherals) do
    for _, t in ipairs(p.types) do
      if t:find(pat) then return true, p end
    end
  end
  return false
end

return M
