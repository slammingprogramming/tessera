# tsr.home

Package: `smarthome`

The smart-home hub: gives the lamps, doors, switches and sensors of a base friendly names, rooms and states, groups them into scenes ("night"), switches scenes at times
of day, and (optionally) speaks MQTT so that panels, phones and other computers can see and control everything.
Devices come from the hardware layer (hal): a redstone lamp declared as a virtual device, a peripheral, a machine. Settings: /etc/tsr/home.lua
  devices  = { ["kitchen-light"] = { room = "kitchen", kind = "light", dev = "lamp1" },
               ["front-door"]    = { room = "hall", kind = "door", dev = "doorrelay", on = { "redstone.set", "top", 15 }, off = { "redstone.set", "top", 0 }, state = "redstone.output" },
               ["tank"]          = { room = "cellar", kind = "sensor", dev = "gauge", read = "sensor.value", unit = "%" } }
  scenes   = { night = { ["kitchen-light"] = "off", ["front-door"] = "closed" } }
  schedule = { { at = "22:30", scene = "night" }, { at = "07:00", scene = "morning", days = "mon,tue,wed,thu,fri" } }
  mqtt     = { host = "10.0.0.5", username = "home", password = "...", prefix = "home" }

## `M.new(cfg, env)`

cfg: the settings table. env: devices (function -> list of hal devices), now (function -> { hour, min, day = "mon".. , date = "2026-10-03" }), tz.

## `Hub:state(name)`

The state of a device: "on"/"off" (shown as the words of its kind), a number for sensors, or nil + reason.

## `Hub:set(name, what)`

Switch a device. what: "on"/"off" or the words of its kind (open, closed, locked ...), or "toggle".

## `Hub:scene(name)`

Apply a scene: every device in it is set. Returns how many were set and a list of problems.

## `Hub:list()`

All devices with room, kind, state: { { name, room, kind, state, unit } } sorted by room and name.

## `Hub:tick()`

Run scenes that are due. Call every few seconds. Returns the names of the scenes that ran.

## `Hub:publishChanges(client, force)`

Publish state changes. client: an MQTT client (tsr.mqtt). Topics: <prefix>/<room>/<device>/state (retained). Returns the number of messages sent.

## `Hub:subscribe(client)`

Subscribe to the command topics: <prefix>/+/+/set (a device) and <prefix>/scene/+/set (a scene).

## `Hub:onMessage(m)`

Act on one received message. Returns what was done (a text) or nil.
