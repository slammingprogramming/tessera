-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The smart-home hub: gives the lamps, doors, switches and sensors of a base friendly names, rooms and states, groups them into scenes ("night"), switches scenes at times
-- of day, and (optionally) speaks MQTT so that panels, phones and other computers can see and control everything.
-- Devices come from the hardware layer (hal): a redstone lamp declared as a virtual device, a peripheral, a machine. Settings: /etc/tsr/home.lua
--   devices  = { ["kitchen-light"] = { room = "kitchen", kind = "light", dev = "lamp1" },
--                ["front-door"]    = { room = "hall", kind = "door", dev = "doorrelay", on = { "redstone.set", "top", 15 }, off = { "redstone.set", "top", 0 }, state = "redstone.output" },
--                ["tank"]          = { room = "cellar", kind = "sensor", dev = "gauge", read = "sensor.value", unit = "%" } }
--   scenes   = { night = { ["kitchen-light"] = "off", ["front-door"] = "closed" } }
--   schedule = { { at = "22:30", scene = "night" }, { at = "07:00", scene = "morning", days = "mon,tue,wed,thu,fri" } }
--   mqtt     = { host = "10.0.0.5", username = "home", password = "...", prefix = "home" }
local M = {}
local Hub = {}
Hub.__index = Hub

M.KINDS = {
  light = { on = "on", off = "off" }, switch = { on = "on", off = "off" }, outlet = { on = "on", off = "off" },
  door = { on = "open", off = "closed" }, gate = { on = "open", off = "closed" }, trapdoor = { on = "open", off = "closed" },
  lock = { on = "unlocked", off = "locked" },
  sensor = {},
}

local WORDS = {
  on = "on", off = "off", open = "on", closed = "off", close = "off", unlocked = "on", unlock = "on", locked = "off", lock = "off",
  ["1"] = "on", ["0"] = "off", ["true"] = "on", ["false"] = "off",
}

--- cfg: the settings table. env: devices (function -> list of hal devices), now (function -> { hour, min, day = "mon".. , date = "2026-10-03" }), tz.
function M.new(cfg, env)
  env = env or {}
  local self = setmetatable({ cfg = cfg or {}, env = env, last = {}, fired = {} }, Hub)
  self.devices = {}
  for name, d in pairs(self.cfg.devices or {}) do
    local kind = M.KINDS[d.kind or "switch"]
    if not kind then error(("device %s has an unknown kind %s"):format(name, tostring(d.kind)), 0) end
    self.devices[name] = d
  end
  return self
end

local function halDevice(self, entry)
  local list = self.env.devices and self.env.devices() or {}
  for _, d in ipairs(list) do if d.name == entry.dev then return d end end
end

--- The state of a device: "on"/"off" (shown as the words of its kind), a number for sensors, or nil + reason.
function Hub:state(name)
  local entry = self.devices[name]
  if not entry then return nil, "no such device" end
  local dev = halDevice(self, entry)
  if not dev then return nil, "the device " .. tostring(entry.dev) .. " is not connected" end
  local kind = M.KINDS[entry.kind or "switch"]
  if entry.kind == "sensor" then
    local v, unit = dev:get(entry.read or "sensor.value")
    if v == nil then return nil, tostring(unit or "no reading") end
    if type(v) == "number" and entry.scale then v = v * entry.scale end
    return v, entry.unit or unit
  end
  local reading = entry.state or "machine.running"
  local v, why = dev:get(reading)
  if v == nil then
    -- a redstone relay or a plain peripheral has no running state: use what the last command was
    if self.last[name] then return kind[self.last[name]], "assumed" end
    return nil, tostring(why)
  end
  local on = v == true or (type(v) == "number" and v > 0)
  return kind[on and "on" or "off"]
end

local function commandFor(entry, on)
  local cmd = on and entry.on or entry.off
  if cmd then return cmd end
  if on then return { "machine.start" } end
  return { "machine.stop" }
end

--- Switch a device. what: "on"/"off" or the words of its kind (open, closed, locked ...), or "toggle".
function Hub:set(name, what)
  local entry = self.devices[name]
  if not entry then return nil, "no such device" end
  if entry.kind == "sensor" then return nil, name .. " is a sensor: it cannot be switched" end
  local dev = halDevice(self, entry)
  if not dev then return nil, "the device " .. tostring(entry.dev) .. " is not connected" end
  local word = WORDS[tostring(what):lower()]
  if what == "toggle" then
    local cur = self:state(name)
    local kind = M.KINDS[entry.kind or "switch"]
    word = (cur == kind.on) and "off" or "on"
  end
  if not word then return nil, "unknown state " .. tostring(what) end
  local cmd = commandFor(entry, word == "on")
  local ok, why = dev:act(table.unpack(cmd))
  if not ok and why then return nil, tostring(why) end
  self.last[name] = word
  return M.KINDS[entry.kind or "switch"][word]
end

--- Apply a scene: every device in it is set. Returns how many were set and a list of problems.
function Hub:scene(name)
  local scene = (self.cfg.scenes or {})[name]
  if not scene then return nil, "no such scene" end
  local n, problems = 0, {}
  local names = {}
  for dev in pairs(scene) do names[#names + 1] = dev end
  table.sort(names)
  for _, dev in ipairs(names) do
    local ok, why = self:set(dev, scene[dev])
    if ok then n = n + 1 else problems[#problems + 1] = dev .. ": " .. tostring(why) end
  end
  return n, problems
end

--- All devices with room, kind, state: { { name, room, kind, state, unit } } sorted by room and name.
function Hub:list()
  local out = {}
  for name, d in pairs(self.devices) do
    local state, unit = self:state(name)
    out[#out + 1] = { name = name, room = d.room or "-", kind = d.kind or "switch", state = state, unit = unit }
  end
  table.sort(out, function(a, b) if a.room ~= b.room then return a.room < b.room end return a.name < b.name end)
  return out
end

--- Run scenes that are due. Call every few seconds. Returns the names of the scenes that ran.
function Hub:tick()
  local t = self.env.now and self.env.now()
  if not t then return {} end
  local ran = {}
  for i, item in ipairs(self.cfg.schedule or {}) do
    local h, m = tostring(item.at):match("^(%d+):(%d+)$")
    if h and tonumber(h) == t.hour and tonumber(m) == t.min then
      local dayOk = true
      if item.days then
        dayOk = false
        for d in item.days:gmatch("%a+") do if d:lower() == t.day then dayOk = true end end
      end
      local key = i .. "@" .. t.date .. "T" .. item.at
      if dayOk and not self.fired[key] then
        self.fired[key] = true
        self:scene(item.scene)
        ran[#ran + 1] = item.scene
      end
    end
  end
  return ran
end

---------------------------------------------------------------------------------------------------------------------
-- MQTT
---------------------------------------------------------------------------------------------------------------------

--- Publish state changes. client: an MQTT client (tsr.mqtt). Topics: <prefix>/<room>/<device>/state (retained). Returns the number of messages sent.
function Hub:publishChanges(client, force)
  local prefix = (self.cfg.mqtt and self.cfg.mqtt.prefix) or "home"
  local n = 0
  self.published = self.published or {}
  for _, d in ipairs(self:list()) do
    local value = d.state ~= nil and tostring(d.state) or nil
    if value ~= nil and (force or self.published[d.name] ~= value) then
      local ok = client:publish(("%s/%s/%s/state"):format(prefix, d.room, d.name), value, { retain = true })
      if ok then self.published[d.name] = value n = n + 1 end
    end
  end
  return n
end

--- Subscribe to the command topics: <prefix>/+/+/set (a device) and <prefix>/scene/+/set (a scene).
function Hub:subscribe(client)
  local prefix = (self.cfg.mqtt and self.cfg.mqtt.prefix) or "home"
  local ok, why = client:subscribe(prefix .. "/+/+/set", 1)
  if not ok then return nil, why end
  return true
end

--- Act on one received message. Returns what was done (a text) or nil.
function Hub:onMessage(m)
  local prefix = (self.cfg.mqtt and self.cfg.mqtt.prefix) or "home"
  local room, name = m.topic:match("^" .. prefix:gsub("%p", "%%%0") .. "/([^/]+)/([^/]+)/set$")
  if not room then return nil end
  if room == "scene" then
    local n = self:scene(name)
    return n and ("scene " .. name) or nil
  end
  local entry = self.devices[name]
  if not entry or (entry.room or "-") ~= room then return nil end
  local ok = self:set(name, m.payload)
  return ok and (name .. " " .. m.payload) or nil
end

return M
