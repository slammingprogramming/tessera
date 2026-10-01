-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Hardware abstraction layer (HAL). Every attached peripheral (and every declared "virtual" device, such as a machine that is
-- only switched by redstone) becomes a device with
--   caps     what it can do: "energy", "fluid", "inventory", "machine", "redstone", "reactor", "display", "audio", "sensor"...
--   read     named readings:  device:get("energy.percent")
--   act      named actions:   device:act("machine.stop")
-- Drivers translate between a device's own API and these names. Core drivers live in tsr/hal/drivers/*.lua; integration packs
-- (Advanced Peripherals, Mekanism, Create...) ship more drivers in the same folder. A driver is a table:
--   { id = "name", match = function(dev) -> adapter | nil }     dev = { name, types = {...}, per = <wrapped peripheral> }
--   adapter = { caps = { "energy" }, read = { ["energy.stored"] = function(dev) return 5, "FE" end }, act = { ... } }
--   optional  devices = function(env) -> { { name=, types=, adapter= } }  for devices that are not peripherals
-- All readings return value, unit (unit may be nil). Unknown readings return nil, "no such reading".
local M = {}

M.driverDir = "/sys/lib/tsr/hal/drivers"
M.VIRTUAL_PATH = "/etc/tsr/hal.devices"

local drivers = {}

function M.driver(def)
  assert(type(def) == "table" and def.id, "a driver needs an id")
  for i, d in ipairs(drivers) do
    if d.id == def.id then drivers[i] = def return end
  end
  drivers[#drivers + 1] = def
end

function M.drivers() return drivers end
function M.reset() drivers = {} end

--- Load every driver file from M.driverDir (idempotent per file: a driver with the same id is replaced).
function M.loadDrivers()
  local count = 0
  if not fs.isDir(M.driverDir) then return 0 end
  local names = fs.list(M.driverDir)
  table.sort(names)
  for _, f in ipairs(names) do
    if f:match("%.lua$") then
      local chunk = loadfile(M.driverDir .. "/" .. f, "t", setmetatable({ require = require }, { __index = _G }))
      local ok, def = false, nil
      if chunk then ok, def = pcall(chunk) end
      if ok and type(def) == "table" then
        if def.id then M.driver(def) count = count + 1
        else for _, d in ipairs(def) do M.driver(d) count = count + 1 end end
      end
    end
  end
  return count
end

---------------------------------------------------------------------------------------------------------------------
-- Devices
---------------------------------------------------------------------------------------------------------------------

local Device = {}
Device.__index = Device

function Device:has(cap) return self.caps[cap] == true end

function Device:get(metric, ...)
  local fn = self.read[metric]
  if not fn then return nil, "no such reading" end
  local ok, value, unit = pcall(fn, self, ...)
  if not ok then return nil, tostring(value) end
  return value, unit
end

function Device:act(action, ...)
  local fn = self.actions[action]
  if not fn then return nil, "no such action" end
  local ok, res, err = pcall(fn, self, ...)
  if not ok then return nil, tostring(res) end
  if res == nil and err then return nil, err end
  return res == nil and true or res
end

function Device:metrics()
  local out = {}
  for k in pairs(self.read) do out[#out + 1] = k end
  table.sort(out)
  return out
end

function Device:actionNames()
  local out = {}
  for k in pairs(self.actions) do out[#out + 1] = k end
  table.sort(out)
  return out
end

local function merge(dev, adapter, driverId)
  dev.drivers[#dev.drivers + 1] = driverId
  for _, c in ipairs(adapter.caps or {}) do dev.caps[c] = true end
  for k, fn in pairs(adapter.read or {}) do if dev.read[k] == nil then dev.read[k] = fn end end
  for k, fn in pairs(adapter.act or {}) do if dev.actions[k] == nil then dev.actions[k] = fn end end
  if adapter.label and not dev.label then dev.label = adapter.label end
end

local function newDevice(name, types, per)
  return setmetatable({ name = name, types = types, per = per, caps = {}, read = {}, actions = {}, drivers = {} }, Device)
end

local function typesOf(per, name)
  local t = { per.getType(name) }
  if #t == 0 then return {} end
  return t
end

--- Look at everything attached. env (optional): peripheral, redstone, colors (tests). Returns an array of devices (sorted by
--- name); devices with no matching driver are left out unless env.all is set.
function M.scan(env)
  env = env or {}
  local per = env.peripheral or peripheral
  if #drivers == 0 then M.loadDrivers() end
  local out = {}
  for _, name in ipairs(per.getNames()) do
    local dev = newDevice(name, typesOf(per, name), nil)
    local wrapped
    dev.per = setmetatable({}, { __index = function(_, k)
      wrapped = wrapped or per.wrap(name)
      return wrapped and wrapped[k]
    end })
    dev.call = function(method, ...) return per.call(name, method, ...) end
    dev.methods = function() return per.getMethods(name) end
    dev.env = env
    for _, d in ipairs(drivers) do
      if d.match then
        local ok, adapter = pcall(d.match, dev)
        if ok and adapter then merge(dev, adapter, d.id) end
      end
    end
    if #dev.drivers > 0 or env.all then out[#out + 1] = dev end
  end
  for _, d in ipairs(drivers) do
    if d.devices then
      local ok, list = pcall(d.devices, env)
      if ok and type(list) == "table" then
        for _, v in ipairs(list) do
          local dev = newDevice(v.name, v.types or { "virtual" }, nil)
          dev.env = env
          merge(dev, v.adapter, d.id)
          out[#out + 1] = dev
        end
      end
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

--- Devices with capability `cap` from a scan result.
function M.withCap(devices, cap)
  local out = {}
  for _, d in ipairs(devices) do if d.caps[cap] then out[#out + 1] = d end end
  return out
end

function M.byName(devices, name)
  for _, d in ipairs(devices) do if d.name == name then return d end end
end

--- Convenience: scan + lookup.
function M.get(name, env) return M.byName(M.scan(env), name) end
function M.find(cap, env) return M.withCap(M.scan(env), cap) end

--- A short human description of a device: "name  [caps]  (driver)".
function M.describe(dev)
  local caps = {}
  for c in pairs(dev.caps) do caps[#caps + 1] = c end
  table.sort(caps)
  return ("%-22s %-28s %s"):format(dev.name, table.concat(caps, ","), table.concat(dev.drivers, "+"))
end

return M
