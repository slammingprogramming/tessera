-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Virtual devices: machines and sensors that have no ComputerCraft interface and are reached through redstone only.
-- Declared in /etc/tsr/hal.devices (edit with `hal virtual add ...`):
--   ["smelter"]   = { kind = "switch", port = "back:red", invert = false, label = "furnace bank" }
--   ["tank-gauge"] = { kind = "sensor", port = "left", scale = 100 / 15, unit = "%", label = "tank fill (comparator)" }
-- A switch is a "machine" you can start/stop (the port is the redstone output that powers it); a sensor reads a redstone input.
-- Ports use the rsio notation: top, back:red, relay_0/left ...
local vfs = require("tsr.vfs")

local function open(spec, env)
  local rsio = require("tsrapps.rsio")
  return rsio.open(spec.port, env)
end

local function switchAdapter(spec)
  local function port(dev) return assert(open(spec, dev.env)) end
  local function active(dev)
    local level = port(dev).getOutput()
    local on
    if type(level) == "boolean" then on = level else on = level > 0 end
    if spec.invert then on = not on end
    return on
  end
  local function set(dev, on)
    local p = port(dev)
    if spec.invert then on = not on end
    p.set(on)
    return true
  end
  return {
    caps = { "machine", "redstone" },
    label = spec.label,
    read = {
      ["machine.running"] = function(dev) return active(dev) end,
    },
    act = {
      ["machine.start"] = function(dev) return set(dev, true) end,
      ["machine.stop"] = function(dev) return set(dev, false) end,
      ["machine.toggle"] = function(dev) return set(dev, not active(dev)) end,
      ["redstone.set"] = function(dev, _, level) return set(dev, level == true or (type(level) == "number" and level > 0)) end,
    },
  }
end

local function sensorAdapter(spec)
  local function level(dev)
    local v = assert(open(spec, dev.env)).getInput()
    if type(v) == "boolean" then v = v and 15 or 0 end
    return v
  end
  return {
    caps = { "sensor", "redstone" },
    label = spec.label,
    read = {
      ["sensor.level"] = function(dev) return level(dev), "level" end,
      ["sensor.active"] = function(dev) return level(dev) > 0 end,
      ["sensor.value"] = function(dev) return level(dev) * (spec.scale or 1), spec.unit end,
      ["redstone.input"] = function(dev) return level(dev), "level" end,
    },
  }
end

return {
  id = "virtual",
  devices = function(env)
    local specs = vfs.readTable(env.devicesPath or "/etc/tsr/hal.devices") or {}
    local out = {}
    local names = {}
    for name in pairs(specs) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      local spec = specs[name]
      if type(spec) == "table" and type(spec.port) == "string" then
        if spec.kind == "switch" then
          out[#out + 1] = { name = name, types = { "virtual_switch" }, adapter = switchAdapter(spec) }
        elseif spec.kind == "sensor" then
          out[#out + 1] = { name = name, types = { "virtual_sensor" }, adapter = sensorAdapter(spec) }
        end
      end
    end
    return out
  end,
}
