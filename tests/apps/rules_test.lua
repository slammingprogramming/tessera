-- SPDX-License-Identifier: AGPL-3.0-or-later
local F = dofile("/tests/lib/fakes.lua")
local hal = require("tsr.hal")
local rules = require("tsr.rules")

local DIR = "/tmp-rules"

local function cell(stored, cap)
  local c = { _type = "energy_storage", stored = stored }
  function c.getEnergy() return c.stored end
  function c.getEnergyCapacity() return cap end
  return c
end

--- An engine over fake hardware with a controllable clock.
local function world(devices, extra)
  if fs.exists(DIR) then fs.delete(DIR) end
  fs.makeDir(DIR)
  hal.reset()
  local clock = { t = 1000 }
  local rs = F.redstone()
  local env = { peripheral = F.peripheralApi(devices), redstone = rs, devicesPath = DIR .. "/devices" }
  local engine = rules.engine({ now = function() return clock.t end, env = env, run = extra and extra.run })
  return engine, clock, rs
end

local function lookupFor(devices)
  hal.reset()
  local list = hal.scan({ peripheral = F.peripheralApi(devices), redstone = F.redstone(), devicesPath = DIR .. "/devices" })
  return function(name) return hal.byName(list, name) end
end

test("conditions: operators, combinations, errors", function()
  fs.makeDir(DIR)
  local lookup = lookupFor({ a = cell(500, 1000), b = cell(900, 1000) })
  local function ev(c) return (rules.evaluate(c, lookup)) end
  ok(ev({ device = "a", metric = "energy.percent", op = "<", value = 60 }) == true)
  ok(ev({ device = "a", metric = "energy.percent", op = ">", value = 60 }) == false)
  ok(ev({ device = "a", metric = "energy.stored", op = "==", value = 500 }) == true)
  ok(ev({ device = "a", metric = "energy.percent", op = "between", value = { 40, 60 } }) == true)
  ok(ev({ device = "a", metric = "energy.percent", op = "~=", value = 50 }) == false)
  ok(ev({ all = { { device = "a", metric = "energy.percent", op = "<", value = 60 }, { device = "b", metric = "energy.percent", op = ">", value = 80 } } }) == true)
  ok(ev({ all = { { device = "a", metric = "energy.percent", op = "<", value = 10 }, { device = "b", metric = "energy.percent", op = ">", value = 80 } } }) == false)
  ok(ev({ any = { { device = "a", metric = "energy.percent", op = "<", value = 10 }, { device = "b", metric = "energy.percent", op = ">", value = 80 } } }) == true)
  ok(ev({ ["not"] = { device = "a", metric = "energy.percent", op = "<", value = 10 } }) == true)
  local r, v = rules.evaluate({ device = "a", metric = "energy.percent", op = "<", value = 60 }, lookup)
  eq(v, 50)
  -- problems give nil + reason, never an exception
  local bad, why = rules.evaluate({ device = "ghost", metric = "x", op = "<", value = 1 }, lookup)
  ok(bad == nil and why:find("no device"))
  bad, why = rules.evaluate({ device = "a", metric = "nothing", op = "<", value = 1 }, lookup)
  ok(bad == nil and why:find("no such reading"))
  bad, why = rules.evaluate({ device = "a", metric = "energy.percent", op = "~~", value = 1 }, lookup)
  ok(bad == nil and why:find("unknown operator"))
  bad = rules.evaluate({ device = "a", metric = "energy.percent" }, lookup)
  eq(bad, true, "no operator: a non-zero reading is true")
  -- an `any` with one broken branch still works through the good one
  ok(ev({ any = { { device = "ghost", metric = "x", op = "<", value = 1 }, { device = "b", metric = "energy.percent", op = ">", value = 80 } } }) == true)
end)

test("a rule fires on and off once, at the edges", function()
  local c = cell(900, 1000)
  local engine, clock, rs = world({ cell = c })
  engine:setRules({ {
    name = "low", every = 1,
    when = { device = "cell", metric = "energy.percent", op = "<", value = 20 },
    on = { { action = "redstone", port = "top", set = true } },
    off = { { action = "redstone", port = "top", set = false } },
  } })
  eq(#engine:tick(), 0)
  eq(rs.out.top, nil)
  c.stored = 100
  clock.t = clock.t + 1
  eq(engine:tick(), { { rule = "low", event = "on" } })
  eq(rs.out.top, 15)
  clock.t = clock.t + 1
  eq(#engine:tick(), 0, "still low: nothing new happens")
  eq(#rs.log, 1)
  c.stored = 500
  clock.t = clock.t + 1
  eq(engine:tick(), { { rule = "low", event = "off" } })
  eq(rs.out.top, 0)
  eq(engine:status()[1].state, "idle")
end)

test("hold time delays the firing and cancels if the condition goes away", function()
  local c = cell(100, 1000)
  local engine, clock, rs = world({ cell = c })
  engine:setRules({ {
    name = "slow", every = 1, hold = 10,
    when = { device = "cell", metric = "energy.percent", op = "<", value = 20 },
    on = { { action = "redstone", port = "top", set = true } },
  } })
  engine:tick()
  eq(engine:status()[1].state, "pending")
  clock.t = clock.t + 5
  engine:tick()
  eq(rs.out.top, nil)
  c.stored = 900
  clock.t = clock.t + 1
  engine:tick()
  eq(engine:status()[1].state, "idle")
  c.stored = 100
  clock.t = clock.t + 1
  engine:tick()
  clock.t = clock.t + 10
  eq(engine:tick(), { { rule = "slow", event = "on" } })
  eq(rs.out.top, 15)
end)

test("hysteresis: a clear condition keeps the rule active until it is met", function()
  local c = cell(100, 1000)
  local engine, clock, rs = world({ cell = c })
  engine:setRules({ {
    name = "gen", every = 1,
    when = { device = "cell", metric = "energy.percent", op = "<", value = 20 },
    clear = { device = "cell", metric = "energy.percent", op = ">", value = 60 },
    on = { { action = "redstone", port = "top", set = true } },
    off = { { action = "redstone", port = "top", set = false } },
  } })
  local function step(stored)
    c.stored = stored
    clock.t = clock.t + 1
    return engine:tick()
  end
  eq(step(100), { { rule = "gen", event = "on" } })
  eq(step(300), {}, "above the start threshold but not yet at the clear level")
  eq(step(500), {})
  eq(rs.out.top, 15)
  eq(step(700), { { rule = "gen", event = "off" } })
  eq(rs.out.top, 0)
  eq(step(300), {}, "does not restart until below 20% again")
  eq(step(100), { { rule = "gen", event = "on" } })
end)

test("checks respect each rule's interval", function()
  local reads = 0
  local counting = { _type = "energy_storage", getEnergyCapacity = function() return 1000 end,
                     getEnergy = function() reads = reads + 1 return 100 end }
  local engine, clock = world({ cell = counting })
  engine:setRules({ { name = "r", every = 10, when = { device = "cell", metric = "energy.percent", op = "<", value = 50 } } })
  engine:tick()
  local first = reads
  clock.t = clock.t + 3
  engine:tick()
  eq(reads, first, "not due yet")
  clock.t = clock.t + 8
  engine:tick()
  ok(reads > first)
end)

test("missing devices are reported and never fire actions", function()
  local engine, clock, rs = world({})
  engine:setRules({ { name = "ghost-rule", every = 1,
    when = { device = "nothing", metric = "energy.percent", op = "<", value = 20 },
    on = { { action = "redstone", port = "top", set = true } } } })
  eq(#engine:tick(), 0)
  local st = engine:status()[1]
  eq(st.state, "idle")
  ok(st.error and st.error:find("no device"))
  eq(rs.out.top, nil)
end)

test("device, command, service, log and event actions", function()
  local c = cell(100, 1000)
  local ran = ""
  local engine = world({ cell = c }, { run = function(line) ran = ran .. line return true end })
  local rs = F.redstone()
  local h = fs.open(DIR .. "/devices", "w")
  h.write(textutils.serialize({ pump = { kind = "switch", port = "left" } }))
  h.close()
  engine.env.redstone = rs
  local svc = require("tsr.svc")
  svc.reset()
  svc.define({ name = "demo-svc", run = function() while true do os.pullEvent("never_ever") end end })
  engine:setRules({ {
    name = "multi", every = 1,
    when = { device = "cell", metric = "energy.percent", op = "<", value = 50 },
    on = {
      { action = "device", device = "pump", do_ = "machine.start" },
      { action = "command", line = "echo hi" },
      { action = "service", start = "demo-svc" },
      { action = "log", level = "warn", text = "${rule} is ${state} at ${value}%" },
      { action = "event", name = "custom" },
      { action = "nonsense" },
    },
  } })
  local K = require("tsr.kernel")
  K.reset()
  K.init({ term = window.create(term.current(), 1, 1, 20, 5, false) })
  engine:tick()
  eq(rs.out.left, 15, "device action went through the HAL to redstone")
  eq(ran, "echo hi")
  eq(svc.status("demo-svc").state, "running")
  local found = false
  for _, l in ipairs(require("tsr.log").tail(10)) do
    if l:find("multi is on at 10%", 1, true) then found = true end
  end
  ok(found, "log text is expanded")
  svc.stop("demo-svc")
  svc.reset()
end)

test("rule files load, problems are reported", function()
  local engine = world({})
  fs.makeDir(DIR .. "/rules")
  local function put(name, text)
    local h = fs.open(DIR .. "/rules/" .. name, "w")
    h.write(text)
    h.close()
  end
  put("one.lua", [[return { name = "one", when = { device = "a", metric = "m", op = "<", value = 1 } }]])
  put("many.lua", [[return { { name = "two", when = { device = "a", metric = "m" } }, { name = "three", when = { device = "a", metric = "m" } } }]])
  put("bad.lua", [[return { name = "no condition" }]])
  put("broken.lua", "return {")
  put("note.txt", "ignored")
  local n, problems = engine:load(DIR .. "/rules")
  eq(n, 3)
  eq(#problems, 2)
  local names = {}
  for _, r in ipairs(engine.rules) do names[#names + 1] = r.name end
  table.sort(names)
  eq(names, { "one", "three", "two" })
end)

test("the rules command lists and checks", function()
  local c = cell(100, 1000)
  hal.reset()
  fs.makeDir(DIR)
  rules.dir = DIR .. "/rules.d"
  fs.makeDir(rules.dir)
  local h = fs.open(rules.dir .. "/p.lua", "w")
  h.write([[return { name = "low", every = 3, hold = 5, when = { device = "cell", metric = "energy.percent", op = "<", value = 20 } }]])
  h.close()
  local function run(...)
    local io = { said = {}, errs = {} }
    function io.say(t) io.said[#io.said + 1] = t end
    function io.err(t) io.errs[#io.errs + 1] = t end
    local r = rules.cli({ ... }, io, { peripheral = F.peripheralApi({ cell = c }), redstone = F.redstone(), devicesPath = DIR .. "/devices" })
    return r, table.concat(io.said, " / "), table.concat(io.errs, " / ")
  end
  local r, text = run("list")
  ok(r and text:find("low", 1, true) and text:find("hold 5s", 1, true), text)
  r, text = run("check")
  ok(text:find("low: TRUE (reading 10)", 1, true), text)
  r, text = run("check", "other")
  eq(text, "")
  eq(run("bogus"), false)
  rules.dir = "/etc/tsr/rules.d"
end)
