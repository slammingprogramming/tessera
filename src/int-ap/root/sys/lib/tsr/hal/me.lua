-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The `me` command: look into an Applied Energistics 2 or Refined Storage network through an Advanced Peripherals bridge.
--   me storage                 capacity, power and item totals
--   me items [text]            the biggest stacks (filter by part of the item name)
--   me count <item>            how many of one item the network holds
--   me craft <item> [n]        ask the network to craft (default 1)
--   me [--device <name>] ...   choose a bridge when several are attached
local hal = require("tsr.hal")

local M = {}

local function defaultIO()
  local io = {}
  local function color(c) if term.isColor() then term.setTextColor(c) end end
  function io.say(t) print(t) end
  function io.err(t) color(colors.red) print(t) color(colors.white) end
  return io
end

local function fmt(n)
  if type(n) ~= "number" then return tostring(n) end
  if n >= 1e6 then return ("%.1fM"):format(n / 1e6) elseif n >= 1e4 then return ("%.1fk"):format(n / 1e3) end
  return ("%d"):format(math.floor(n))
end

function M.run(args, io, env)
  io = io or defaultIO()
  env = env or {}
  local rest, wanted = {}, nil
  local i = 1
  while i <= #args do
    if args[i] == "--device" then wanted = args[i + 1] i = i + 2 else rest[#rest + 1] = args[i] i = i + 1 end
  end
  local devices = hal.find("storage_network", env)
  local dev
  if wanted then
    for _, d in ipairs(devices) do if d.name == wanted then dev = d end end
  else
    dev = devices[1]
  end
  if not dev then
    io.err(wanted and ("no bridge named " .. wanted) or "no ME or RS bridge found (Advanced Peripherals must be installed and a bridge connected)")
    return false
  end
  local cmd = rest[1] or "storage"

  if cmd == "storage" then
    io.say("bridge: " .. dev.name)
    local p = dev:get("energy.percent")
    local stored, unit = dev:get("energy.stored")
    if p then io.say(("power:  %s %s (%.0f%%)"):format(fmt(stored), unit or "", p)) end
    local total = dev:get("storage.total")
    if total then
      io.say(("items:  %s of %s used (%.0f%%)"):format(fmt(dev:get("storage.used")), fmt(total), dev:get("storage.percent") or 0))
    end
    local kinds = dev:get("network.types")
    if kinds then io.say("kinds:  " .. kinds .. " different items") end
    return true

  elseif cmd == "items" then
    local list = dev.call("listItems") or {}
    local filter = rest[2] and rest[2]:lower()
    local rows = {}
    for _, it in pairs(list) do
      local name = it.name or it.id or "?"
      if not filter or name:lower():find(filter, 1, true) or (it.displayName and it.displayName:lower():find(filter, 1, true)) then
        rows[#rows + 1] = { name = name, count = it.count or it.amount or 0 }
      end
    end
    table.sort(rows, function(a, b) return a.count > b.count end)
    if #rows == 0 then io.say("Nothing found.") end
    for n = 1, math.min(20, #rows) do io.say(("%8s  %s"):format(fmt(rows[n].count), rows[n].name)) end
    if #rows > 20 then io.say("... and " .. (#rows - 20) .. " more") end
    return true

  elseif cmd == "count" then
    if not rest[2] then io.err("usage: me count <item>") return false end
    io.say(fmt(dev:get("network.count", rest[2])) .. "  " .. rest[2])
    return true

  elseif cmd == "craft" then
    if not rest[2] then io.err("usage: me craft <item> [count]") return false end
    local count = tonumber(rest[3]) or 1
    local ok, err = dev:act("network.craft", rest[2], count)
    if not ok then io.err(tostring(err)) return false end
    io.say("Crafting " .. count .. " x " .. rest[2] .. " requested.")
    return true
  end
  io.err("usage: me storage | items [text] | count <item> | craft <item> [n]")
  return false
end

function M.main(args) return M.run(args) end

return M
