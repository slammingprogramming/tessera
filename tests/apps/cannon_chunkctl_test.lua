-- SPDX-License-Identifier: AGPL-3.0-or-later
local F = dofile("/tests/lib/fakes.lua")
local cannon = require("tsrapps.cannon")
local chunkctl = require("tsrapps.chunkctl")
local redseq = require("tsrapps.redseq")

local function setup()
  fs.delete("/tmp-cfg")
  cannon.CONFIG, cannon.STATE = "/tmp-cfg/cannon.cfg", "/tmp-cfg/cannon.state"
  chunkctl.CONFIG = "/tmp-cfg/chunkctl.cfg"
  local clock = F.clock()
  local r = F.redstone()
  local time = { t = 1000 }
  local env = { redstone = r, peripheral = F.peripheralApi({}), sleep = clock.sleep, now = function() return time.t end, maxRounds = 2 }
  return env, r, clock, time
end

local GOOD = { charge = "back", fire = "top", volley = 2, charge_pulse = 0.4, gap = 0.6, fire_delay = 1, cooldown = 5 }

local function configured(code)
  local cfg = {}
  for k, v in pairs(GOOD) do cfg[k] = v end
  cfg.salt = "pepper"
  cfg.hash = cannon.hashCode(code, cfg.salt)
  cannon.saveConfig(cfg)
  return cfg
end

test("cannon sequence: charges, waits, fires, cools down between volleys", function()
  local steps = cannon.sequence(GOOD, 2)
  eq(redseq.count(steps), 2 * (2 * 2 + 1 + 1) + 1)
  ok(math.abs(redseq.duration(steps) - (2 * (2 * (0.4 + 0.6) + 1 + 0.3) + 5)) < 1e-9)
  eq(steps[1], { op = "pulse", port = "back", secs = 0.4 })
  eq(steps[#steps], { op = "pulse", port = "top", secs = 0.3 })
end)

test("cannon config validation", function()
  ok(cannon.validate(GOOD))
  local bad = { charge = "back", fire = "back", volley = 1, charge_pulse = 1, gap = 1, fire_delay = 1, cooldown = 1 }
  local good, why = cannon.validate(bad)
  ok(not good and why:find("different"))
  bad.fire = "nowhere"
  good, why = cannon.validate(bad)
  ok(not good and why:find("fire port"))
  bad.fire, bad.gap = "top", 0
  good, why = cannon.validate(bad)
  ok(not good and why:find("gap"))
  bad.gap, bad.volley = 1, 100
  good, why = cannon.validate(bad)
  ok(not good and why:find("volley"))
end)

test("the arming code is checked as a salted hash", function()
  local env = setup()
  local cfg = configured("secret123")
  ok(cfg.hash ~= "secret123" and #cfg.hash == 64)
  ok(cannon.hashCode("secret123", "a") ~= cannon.hashCode("secret123", "b"))
  local ok1, err = cannon.arm(cfg, "wrong", env)
  ok(not ok1 and err:find("wrong arming code"))
  ok(not cannon.armed(env))
  ok(cannon.arm(cfg, "secret123", env))
  ok(cannon.armed(env))
  eq(cannon.arm({ salt = "x" }, "a", env), false)
  fs.delete("/tmp-cfg")
end)

test("armed status expires", function()
  local env, _, _, time = setup()
  local cfg = configured("secret123")
  cannon.arm(cfg, "secret123", env)
  time.t = time.t + 59
  ok(cannon.armed(env))
  time.t = time.t + 2
  ok(not cannon.armed(env))
  fs.delete("/tmp-cfg")
end)

test("firing needs to be armed, runs the sequence, then disarms", function()
  local env, r, clock = setup()
  local cfg = configured("secret123")
  local ok1, err = cannon.fire(cfg, 1, env)
  ok(not ok1 and err:find("not armed"))
  eq(#r.log, 0, "nothing switched while safe")
  cannon.arm(cfg, "secret123", env)
  local ok2, steps = cannon.fire(cfg, 2, env)
  ok(ok2, tostring(steps))
  eq(clock.now, redseq.duration(cannon.sequence(cfg, 2)))
  eq(r.out.back, 0)
  eq(r.out.top, 0)
  local pulses = 0
  for _, l in ipairs(r.log) do if l == "top:analog=15" then pulses = pulses + 1 end end
  eq(pulses, 2, "fired once per volley")
  ok(not cannon.armed(env), "auto-disarmed")
  fs.delete("/tmp-cfg")
end)

test("dry run and volley limits", function()
  local env, r = setup()
  local cfg = configured("secret123")
  local good, steps = cannon.fire(cfg, 3, env, { dryRun = true })
  ok(good and #steps > 0)
  eq(#r.log, 0)
  local bad, why = cannon.fire(cfg, 11, env, { dryRun = true })
  ok(not bad and why:find("1 to 10"))
  bad = cannon.fire(cfg, 0, env, { dryRun = true })
  eq(bad, false)
  fs.delete("/tmp-cfg")
end)

test("a failed sequence still disarms and leaves outputs off", function()
  local env, r = setup()
  local cfg = configured("secret123")
  cannon.arm(cfg, "secret123", env)
  local n = 0
  env.sleep = function() n = n + 1 if n == 3 then error("chunk unloaded") end end
  local ok1, err = cannon.fire(cfg, 1, env)
  ok(not ok1 and err:find("chunk unloaded"))
  eq(r.out.back, 0)
  eq(r.out.top or 0, 0)
  ok(not cannon.armed(env))
  fs.delete("/tmp-cfg")
end)

test("cannon command flow: setup, arm, fire", function()
  local env, r = setup()
  local io = F.io({ "back", "top", "1", "0.4", "0.5", "1", "3", "hunter22" })
  ok(cannon.main({ "setup" }, io, env))
  local cfg = cannon.loadConfig()
  eq({ cfg.charge, cfg.fire, cfg.volley }, { "back", "top", 1 })
  ok(cfg.hash and cfg.salt)
  local io2 = F.io({ "nope" })
  eq(cannon.main({ "arm" }, io2, env), false)
  local io3 = F.io({ "hunter22" })
  ok(cannon.main({ "arm" }, io3, env))
  ok(cannon.main({ "status" }, io3, env))
  ok(io3.said[#io3.said]:find("ARMED"))
  ok(cannon.main({ "fire" }, io3, env))
  ok(r.out.top == 0)
  ok(cannon.main({ "status" }, io3, env))
  ok(io3.said[#io3.said]:find("safe"))
  eq(cannon.main({ "fire", "banana" }, io3, env), false)
  fs.delete("/tmp-cfg")
end)

test("setup refuses missing codes and bad ports", function()
  local env = setup()
  local io = F.io({ "back", "top", "1", "0.4", "0.5", "1", "3", "abc" })
  eq(cannon.main({ "setup" }, io, env), false)
  ok(io.errs[1]:find("6 characters"))
  local io2 = F.io({ "back", "back", "1", "0.4", "0.5", "1", "3" })
  eq(cannon.main({ "setup" }, io2, env), false)
  eq(cannon.main({ "status" }, F.io(), env), false)
  fs.delete("/tmp-cfg")
end)

test("chunk loader modes decide correctly", function()
  local d = chunkctl.desired
  ok(d({ mode = "always" }, { hour = 3 }))
  ok(d({ mode = "manual", manual = true }, {}))
  ok(not d({ mode = "manual", manual = false }, {}))
  local day = { mode = "schedule", from = 6, to = 22 }
  ok(d(day, { hour = 12 }) and not d(day, { hour = 23 }) and not d(day, { hour = 5.9 }) and d(day, { hour = 6 }))
  local night = { mode = "schedule", from = 20, to = 4 }
  ok(d(night, { hour = 22 }) and d(night, { hour = 2 }) and not d(night, { hour = 12 }))
  ok(d({ mode = "schedule", from = 5, to = 5 }, { hour = 1 }), "equal times mean always on")
  ok(d({ mode = "players" }, { playersNear = true }))
  ok(not d({ mode = "players" }, { playersNear = false }))
  ok(d({ mode = "players" }, { playersNear = nil }), "no detector -> keep loaded")
end)

test("player detection uses the Advanced Peripherals detector when present", function()
  local none = F.peripheralApi({})
  eq(chunkctl.playersNear(64, none), nil)
  local det = { _type = "playerDetector", isPlayersInRange = function(range) return range >= 10 end }
  local per = F.peripheralApi({ detector = det })
  eq(chunkctl.playersNear(64, per), true)
  eq(chunkctl.playersNear(5, per), false)
  local listy = { _type = "playerDetector", getPlayersInRange = function() return { "Steve" } end }
  eq(chunkctl.playersNear(64, F.peripheralApi({ d = listy })), true)
  local broken = { _type = "playerDetector", isPlayersInRange = function() error("boom") end }
  eq(chunkctl.playersNear(64, F.peripheralApi({ d = broken })), nil)
end)

test("tick applies the mode to the redstone output", function()
  local env, r = setup()
  env.hour = 12
  eq(chunkctl.tick({ output = "back", mode = "schedule", from = 6, to = 22 }, env), true)
  eq(r.out.back, 15)
  env.hour = 23
  eq(chunkctl.tick({ output = "back", mode = "schedule", from = 6, to = 22 }, env), false)
  eq(r.out.back, 0)
  env.peripheral = F.peripheralApi({ d = { _type = "playerDetector", isPlayersInRange = function() return true end } })
  eq(chunkctl.tick({ output = "left", mode = "players", range = 32 }, env), true)
  eq(r.out.left, 15)
end)

test("chunkctl commands", function()
  local env, r = setup()
  local io = F.io({ "back", "schedule", "6", "22" })
  ok(chunkctl.main({ "setup" }, io, env))
  local cfg = chunkctl.load()
  eq({ cfg.mode, cfg.from, cfg.to }, { "schedule", 6, 22 })
  ok(chunkctl.main({ "on" }, io, env))
  eq(r.out.back, 15)
  eq(chunkctl.load().mode, "manual")
  ok(chunkctl.main({ "off" }, io, env))
  eq(r.out.back, 0)
  env.hour = 10
  ok(chunkctl.main({ "status" }, io, env))
  eq(chunkctl.main({ "setup" }, F.io({ "sideways" }), env), false)
  eq(chunkctl.main({ "setup" }, F.io({ "back", "chaos" }), env), false)
  eq(chunkctl.main({ "setup" }, F.io({ "back", "schedule", "30", "2" }), env), false)
  eq(chunkctl.main({}, io, env), false)
  fs.delete("/tmp-cfg")
end)
