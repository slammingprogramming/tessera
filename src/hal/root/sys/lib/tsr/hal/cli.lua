-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The `hal` command.
--   hal list [capability]               every device the HAL understands
--   hal show <device>                   its readings (live) and actions
--   hal get <device> <reading> [arg]    one reading, e.g.  hal get cube energy.percent
--   hal do <device> <action> [args...]  e.g.  hal do smelter machine.stop
--   hal virtual add switch <name> <port> [--invert]     a machine switched by redstone
--   hal virtual add sensor <name> <port> [--scale n] [--unit u]
--   hal virtual remove <name> | hal virtual list
local hal = require("tsr.hal")
local vfs = require("tsr.vfs")

local M = {}

local function defaultIO()
  local io = {}
  local function color(c) if term.isColor() then term.setTextColor(c) end end
  function io.say(t) print(t) end
  function io.err(t) color(colors.red) print(t) color(colors.white) end
  return io
end

local function show(v, unit)
  if type(v) == "number" then
    local s = (v == math.floor(v)) and ("%d"):format(v) or ("%.1f"):format(v)
    return s .. (unit and (" " .. unit) or "")
  elseif type(v) == "table" then
    return textutils.serialize(v, { compact = true })
  end
  return tostring(v) .. (unit and (" " .. unit) or "")
end
M.format = show

local function convertArg(a)
  if a == "true" then return true elseif a == "false" then return false end
  return tonumber(a) or a
end

function M.run(args, io, env)
  io = io or defaultIO()
  env = env or {}
  local cmd = args[1] or "list"

  if cmd == "list" then
    local devices = args[2] and hal.find(args[2], env) or hal.scan(env)
    if #devices == 0 then io.say("No devices.") end
    for _, d in ipairs(devices) do io.say(hal.describe(d)) end
    return true

  elseif cmd == "show" then
    local dev = args[2] and hal.get(args[2], env)
    if not dev then io.err("no such device: " .. tostring(args[2])) return false end
    io.say(dev.name .. (dev.label and (" - " .. dev.label) or ""))
    for _, m in ipairs(dev:metrics()) do
      local v, unit = dev:get(m)
      io.say(("  %-22s %s"):format(m, v == nil and ("(" .. tostring(unit) .. ")") or show(v, unit)))
    end
    local actions = dev:actionNames()
    if #actions > 0 then io.say("  actions: " .. table.concat(actions, ", ")) end
    return true

  elseif cmd == "get" then
    local dev = args[2] and hal.get(args[2], env)
    if not dev then io.err("no such device: " .. tostring(args[2])) return false end
    if not args[3] then io.err("usage: hal get <device> <reading> [arg]") return false end
    local v, unit = dev:get(args[3], args[4] and convertArg(args[4]) or nil)
    if v == nil then io.err(tostring(unit)) return false end
    io.say(show(v, unit))
    return true

  elseif cmd == "do" then
    local dev = args[2] and hal.get(args[2], env)
    if not dev then io.err("no such device: " .. tostring(args[2])) return false end
    if not args[3] then io.err("usage: hal do <device> <action> [args...]") return false end
    local rest = {}
    for i = 4, #args do rest[#rest + 1] = convertArg(args[i]) end
    local ok, err = dev:act(args[3], table.unpack(rest))
    if not ok then io.err(tostring(err)) return false end
    io.say("ok")
    return true

  elseif cmd == "virtual" then
    local path = env.devicesPath or hal.VIRTUAL_PATH
    local specs = vfs.readTable(path) or {}
    local sub = args[2]
    if sub == "list" or sub == nil then
      local names = {}
      for n in pairs(specs) do names[#names + 1] = n end
      table.sort(names)
      if #names == 0 then io.say("No virtual devices.") end
      for _, n in ipairs(names) do io.say(("%-16s %-7s %s"):format(n, specs[n].kind, specs[n].port)) end
      return true
    elseif sub == "add" then
      local kind, name, port = args[3], args[4], args[5]
      if (kind ~= "switch" and kind ~= "sensor") or not name or not port then
        io.err("usage: hal virtual add switch|sensor <name> <port> [--invert] [--scale n] [--unit u]")
        return false
      end
      if not name:match("^[%w_%-%.]+$") then io.err("names may contain letters, digits, - _ .") return false end
      local ok, rsio = pcall(require, "tsrapps.rsio")
      if ok then
        local p, err = rsio.parse(port)
        if not p then io.err(err) return false end
      end
      local spec = { kind = kind, port = port }
      local i = 6
      while args[i] do
        if args[i] == "--invert" then spec.invert = true
        elseif args[i] == "--scale" then spec.scale = tonumber(args[i + 1]) i = i + 1
        elseif args[i] == "--unit" then spec.unit = args[i + 1] i = i + 1 end
        i = i + 1
      end
      specs[name] = spec
      vfs.writeTable(path, specs)
      io.say("Added " .. kind .. " '" .. name .. "' on " .. port .. ".")
      return true
    elseif sub == "remove" then
      if not args[3] or not specs[args[3]] then io.err("no such virtual device") return false end
      specs[args[3]] = nil
      vfs.writeTable(path, specs)
      io.say("Removed.")
      return true
    end
  end
  io.err("usage: hal list|show|get|do|virtual ...")
  return false
end

function M.main(args) return M.run(args) end

return M
