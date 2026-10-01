-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The `cdisplay` command: put text on Create display links (CC:C Bridge `create_source`) and read display targets.
--   cdisplay list                      the Create displays that are connected
--   cdisplay write <name> <text...>    clear the display and show the text (\n starts a new line)
--   cdisplay show <name>               print what a create_target currently shows
--   cdisplay metric <name> <device> <reading> [label]   show one live HAL reading, e.g. an energy percentage
local hal = require("tsr.hal")

local M = {}

local function defaultIO()
  local io = {}
  local function color(c) if term.isColor() then term.setTextColor(c) end end
  function io.say(t) print(t) end
  function io.err(t) color(colors.red) print(t) color(colors.white) end
  return io
end

local function displays(env)
  local out = {}
  for _, d in ipairs(hal.find("display", env)) do
    for _, t in ipairs(d.types) do
      if t == "create_source" or t == "create_target" then out[#out + 1] = d break end
    end
  end
  return out
end

local function find(env, name)
  for _, d in ipairs(displays(env)) do if d.name == name then return d end end
end

--- Write `text` (with \n line breaks) on a source display.
function M.writeText(dev, text)
  dev:act("display.clear")
  local y = 1
  for line in (text:gsub("\\n", "\n") .. "\n"):gmatch("(.-)\n") do
    dev:act("display.write", line, 1, y)
    y = y + 1
  end
  return true
end

function M.run(args, io, env)
  io = io or defaultIO()
  env = env or {}
  local cmd = args[1] or "list"
  if cmd == "list" then
    local list = displays(env)
    if #list == 0 then io.say("No Create displays found (needs the CC:C Bridge mod).") end
    for _, d in ipairs(list) do io.say(("%-22s %s  %s"):format(d.name, d.types[1], tostring(d:get("display.size")))) end
    return true
  elseif cmd == "write" then
    local dev = args[2] and find(env, args[2])
    if not dev then io.err("no such display: " .. tostring(args[2])) return false end
    if not dev.actions["display.write"] then io.err(args[2] .. " is read-only") return false end
    M.writeText(dev, table.concat(args, " ", 3))
    return true
  elseif cmd == "show" then
    local dev = args[2] and find(env, args[2])
    if not dev then io.err("no such display: " .. tostring(args[2])) return false end
    local text, err = dev:get("display.text")
    if not text then io.err(tostring(err or "this display cannot be read")) return false end
    io.say(text)
    return true
  elseif cmd == "metric" then
    local dev = args[2] and find(env, args[2])
    local source = args[3] and hal.get(args[3], env)
    if not dev or not source or not args[4] then io.err("usage: cdisplay metric <display> <device> <reading> [label]") return false end
    local value, unit = source:get(args[4])
    if value == nil then io.err(tostring(unit)) return false end
    local text = (type(value) == "number" and ("%.1f"):format(value) or tostring(value)) .. (unit and (" " .. unit) or "")
    M.writeText(dev, (args[5] and (args[5] .. ": ") or "") .. text)
    return true
  end
  io.err("usage: cdisplay list | write <name> <text> | show <name> | metric <name> <device> <reading> [label]")
  return false
end

function M.main(args) return M.run(args) end

return M
