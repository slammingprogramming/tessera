-- SPDX-License-Identifier: AGPL-3.0-or-later
local home = require("tsr.home")
local daemon = require("tsr.home.daemon")
local cli = require("tsr.home.cli")
local vfs = require("tsr.vfs")

--- Fake hardware: a lamp that reports whether it runs, a door driven by redstone.set (no state reading), a gauge.
local function house()
  local w = { lamp = false, door = 0, gauge = 42, log = {}, missing = false }
  local lamp = { name = "lamp1",
    get = function(_, what) if what == "machine.running" then return w.lamp end end,
    act = function(_, action) w.log[#w.log + 1] = action if action == "machine.start" then w.lamp = true elseif action == "machine.stop" then w.lamp = false else return nil, "no such action" end return true end }
  local door = { name = "doorrelay",
    get = function(_, what) if what == "redstone.output" then return w.door end end,
    act = function(_, action, side, level) w.log[#w.log + 1] = action .. "(" .. tostring(side) .. "," .. tostring(level) .. ")" w.door = level return true end }
  local gauge = { name = "gauge", get = function(_, what) if what == "sensor.value" then return w.gauge, "%" end end, act = function() return nil, "read only" end }
  local devices = function() if w.missing then return { door, gauge } end return { lamp, door, gauge } end
  return w, devices
end

local function config()
  return {
    devices = {
      ["kitchen-light"] = { room = "kitchen", kind = "light", dev = "lamp1" },
      ["front-door"] = { room = "hall", kind = "door", dev = "doorrelay", on = { "redstone.set", "top", 15 }, off = { "redstone.set", "top", 0 }, state = "redstone.output" },
      ["cellar-tank"] = { room = "cellar", kind = "sensor", dev = "gauge", read = "sensor.value" },
      ["hall-lamp"] = { room = "hall", kind = "light", dev = "doorrelay", on = { "redstone.set", "left", 15 }, off = { "redstone.set", "left", 0 } },
    },
    scenes = { night = { ["kitchen-light"] = "off", ["front-door"] = "closed" }, party = { ["kitchen-light"] = "on", ["cellar-tank"] = "on", ["ghost"] = "on" } },
    schedule = { { at = "22:30", scene = "night" }, { at = "07:00", scene = "party", days = "mon,tue" } },
    mqtt = { prefix = "home" },
  }
end

test("states, switching, toggling, kinds and words", function()
  local w, devices = house()
  local hub = home.new(config(), { devices = devices })
  eq({ hub:state("kitchen-light") }, { "off" })
  eq(hub:set("kitchen-light", "on"), "on") eq(w.lamp, true)
  eq({ hub:state("kitchen-light") }, { "on" })
  eq(hub:set("kitchen-light", "toggle"), "off") eq(w.lamp, false)
  -- a door says open/closed and is driven by the commands of its entry
  eq(hub:set("front-door", "open"), "open")
  eq(w.log[#w.log], "redstone.set(top,15)")
  eq({ hub:state("front-door") }, { "open" })
  eq(hub:set("front-door", "close"), "closed") eq({ hub:state("front-door") }, { "closed" })
  eq(hub:set("front-door", "toggle"), "open")
  -- a device without a state reading is assumed to be as it was last set
  local s, how = hub:state("hall-lamp")
  eq(s, nil)
  hub:set("hall-lamp", "on")
  eq({ hub:state("hall-lamp") }, { "on", "assumed" })
  -- a sensor has a value and cannot be switched
  eq({ hub:state("cellar-tank") }, { 42, "%" })
  ok(select(2, hub:set("cellar-tank", "on")):find("is a sensor", 1, true))
  -- problems
  ok(select(2, hub:set("nothing", "on")) == "no such device" and select(2, hub:set("kitchen-light", "sideways")):find("unknown state", 1, true))
  w.missing = true
  ok(select(2, hub:state("kitchen-light")):find("is not connected", 1, true))
  ok(select(2, hub:set("kitchen-light", "on")):find("is not connected", 1, true))
  local okNew, err = pcall(home.new, { devices = { x = { kind = "toaster", dev = "t" } } }, {})
  ok(not okNew and tostring(err):find("unknown kind toaster", 1, true))
  -- locks and gates use their own words
  local lockHub = home.new({ devices = { l = { kind = "lock", dev = "lamp1" } } }, { devices = devices })
  w.missing = false
  eq(lockHub:set("l", "unlock"), "unlocked") eq(lockHub:set("l", "lock"), "locked")
end)

test("scenes and the schedule", function()
  local w, devices = house()
  local t = { hour = 22, min = 30, day = "wed", date = "day5" }
  local hub = home.new(config(), { devices = devices, now = function() return t end })
  hub:set("kitchen-light", "on") hub:set("front-door", "open")
  local n, problems = hub:scene("night")
  eq(n, 2) eq(problems, {})
  eq({ hub:state("kitchen-light") }, { "off" }) eq({ hub:state("front-door") }, { "closed" })
  n, problems = hub:scene("party")
  eq(n, 1) eq(#problems, 2) ok(problems[1]:find("cellar-tank: ", 1, true) and problems[2]:find("ghost: no such device", 1, true), table.concat(problems, ";"))
  ok(select(2, hub:scene("nothing")) == "no such scene")
  -- the schedule runs a scene once at its time
  hub:set("kitchen-light", "on")
  eq(hub:tick(), { "night" })
  eq({ hub:state("kitchen-light") }, { "off" })
  hub:set("kitchen-light", "on")
  eq(hub:tick(), {}, "not twice in the same minute")
  t = { hour = 22, min = 31, day = "wed", date = "day5" }
  eq(hub:tick(), {})
  t = { hour = 22, min = 30, day = "thu", date = "day6" }
  eq(hub:tick(), { "night" }, "the next day again")
  -- weekdays
  t = { hour = 7, min = 0, day = "wed", date = "day7" }
  eq(hub:tick(), {})
  t = { hour = 7, min = 0, day = "tue", date = "day8" }
  eq(hub:tick(), { "party" })
  -- the listing is sorted by room
  local list = hub:list()
  eq({ list[1].room, list[1].name, list[#list].room }, { "cellar", "cellar-tank", "kitchen" })
end)

--- A recording MQTT client.
local function fakeClient()
  local c = { sent = {}, subs = {} }
  function c:publish(topic, payload, opts) self.sent[#self.sent + 1] = { topic, payload, opts and opts.retain } return true end
  function c:subscribe(filter, qos) self.subs[#self.subs + 1] = filter return qos or 0 end
  return c
end

test("the MQTT bridge: states are published when they change, set topics are obeyed", function()
  local w, devices = house()
  local hub = home.new(config(), { devices = devices })
  local c = fakeClient()
  ok(hub:subscribe(c)) eq(c.subs, { "home/+/+/set" })
  hub:set("kitchen-light", "on")
  local n = hub:publishChanges(c, true)
  eq(n, 3, "the lamp, the door (assumed none) and the tank; the hall lamp has no state yet")
  local topics = {}
  for _, m in ipairs(c.sent) do topics[m[1]] = m[2] end
  eq(topics["home/kitchen/kitchen-light/state"], "on") eq(topics["home/cellar/cellar-tank/state"], "42")
  ok(c.sent[1][3] == true, "retained")
  eq(hub:publishChanges(c), 0, "nothing changed")
  w.lamp = false
  eq(hub:publishChanges(c), 1)
  eq(c.sent[#c.sent][2], "off")
  -- commands
  eq(hub:onMessage({ topic = "home/kitchen/kitchen-light/set", payload = "on" }), "kitchen-light on")
  eq(w.lamp, true)
  eq(hub:onMessage({ topic = "home/hall/front-door/set", payload = "open" }), "front-door open")
  eq(hub:onMessage({ topic = "home/scene/night/set", payload = "1" }), "scene night")
  eq(w.lamp, false)
  ok(hub:onMessage({ topic = "home/kitchen/front-door/set", payload = "open" }) == nil, "wrong room")
  ok(hub:onMessage({ topic = "home/kitchen/kitchen-light/state", payload = "on" }) == nil)
  ok(hub:onMessage({ topic = "other/x/y/set", payload = "on" }) == nil)
  ok(hub:onMessage({ topic = "home/kitchen/kitchen-light/set", payload = "dance" }) == nil)
  -- a different prefix
  local cfg = config()
  cfg.mqtt.prefix = "my.house"
  local hub2 = home.new(cfg, { devices = devices })
  eq(hub2:onMessage({ topic = "my.house/kitchen/kitchen-light/set", payload = "on" }), "kitchen-light on")
end)

test("the home command and the clock", function()
  local w, devices = house()
  local hub = home.new(config(), { devices = devices })
  local function run(args)
    local out = { lines = {}, errors = {} }
    local okRun = cli.run(args, { hub = hub, say = function(t) out.lines[#out.lines + 1] = t end, err = function(t) out.errors[#out.errors + 1] = t end })
    return okRun, out
  end
  local good, o = run({})
  ok(good)
  eq(o.lines[1], "cellar:") ok(o.lines[2]:find("cellar%-tank%s+sensor%s+42 %%"), o.lines[2])
  ok(table.concat(o.lines, "\n"):find("kitchen%-light%s+light%s+off"))
  good, o = run({ "on", "kitchen-light" })
  ok(good) eq(o.lines, { "kitchen-light is now on" })
  good, o = run({ "toggle", "kitchen-light" })
  eq(o.lines, { "kitchen-light is now off" })
  good, o = run({ "open", "front-door" })
  ok(good and w.door == 15)
  good, o = run({ "on", "ghost" })
  ok(not good and o.errors[1] == "no such device")
  good, o = run({ "scene", "night" })
  ok(good) eq(o.lines, { "scene night: 2 device(s) set" })
  good, o = run({ "scenes" })
  eq(o.lines, { "night", "party" })
  good, o = run({ "scene", "party" })
  ok(not good and #o.errors == 2)
  good, o = run({ "on" })
  ok(not good and o.errors[1]:find("usage: home on", 1, true))
  good, o = run({ "dance" })
  ok(not good and o.errors[1]:find("usage: home", 1, true))
  -- the example settings are valid and empty
  local saved = daemon.CONFIG
  daemon.CONFIG = "/tmp/home-test.lua"
  if vfs.fs.exists(daemon.CONFIG) then vfs.fs.delete(daemon.CONFIG) end
  ok(cli.run({ "init" }, { say = function() end, err = function() end }))
  ok(not cli.run({ "init" }, { say = function() end, err = function() end }))
  local cfg = assert(daemon.loadConfig())
  eq(cfg.clock, "ingame") eq(cfg.devices, {})
  vfs.fs.delete(daemon.CONFIG)
  daemon.CONFIG = saved
  -- clocks
  local c = daemon.clock("ingame")
  ok(c.hour >= 0 and c.hour < 24 and c.min >= 0 and c.min < 60 and c.day and c.date)
  local l = daemon.clock("local")
  ok(l.hour >= 0 and l.date:match("^%d%d%d%d%-%d%d%-%d%d$"), tostring(l.date))
end)
