-- SPDX-License-Identifier: AGPL-3.0-or-later
local F = dofile("/tests/lib/fakes.lua")
local rsio = require("tsrapps.rsio")
local rs = require("tsrapps.rs")
local redseq = require("tsrapps.redseq")

local function env()
  local clock = F.clock()
  local r = F.redstone()
  local relay = F.redstone()
  relay._type = "redstone_relay"
  local per = F.peripheralApi({ redstone_relay_0 = relay })
  return { redstone = r, peripheral = per, sleep = clock.sleep }, r, relay, clock
end

test("port specs parse sides, colours and relays", function()
  local p = rsio.parse("top")
  eq({ p.side, p.color, p.relay }, { "top", nil, nil })
  p = rsio.parse("back:red")
  eq({ p.side, p.color }, { "back", colors.red })
  p = rsio.parse("relay_0/left")
  eq({ p.side, p.relay }, { "left", "redstone_relay_0" })
  p = rsio.parse("relay_2/right:blue")
  eq({ p.side, p.relay, p.color }, { "right", "redstone_relay_2", colors.blue })
  local bad, err = rsio.parse("sideways")
  ok(bad == nil and err:find("unknown side"))
  bad, err = rsio.parse("top:plaid")
  ok(bad == nil and err:find("unknown colour"))
end)

test("levels parse", function()
  eq(rsio.level("on"), true)
  eq(rsio.level("OFF"), false)
  eq(rsio.level("7"), 7)
  eq(rsio.level("16"), nil)
  eq(rsio.level("1.5"), nil)
  eq(rsio.level("banana"), nil)
end)

test("analog ports set, read and toggle", function()
  local e, r = env()
  local port = assert(rsio.open("top", e))
  port.set(true)
  eq(r.out.top, 15)
  port.set(6)
  eq(port.getOutput(), 6)
  eq(port.toggle(), false)
  eq(r.out.top, 0)
  eq(port.toggle(), true)
  r.inp.top = 9
  eq(port.getInput(), 9)
  throws(function() port.set(20) end, "level")
end)

test("bundled ports change only their own colour", function()
  local e, r = env()
  local red = assert(rsio.open("back:red", e))
  local blue = assert(rsio.open("back:blue", e))
  red.set(true)
  blue.set(true)
  eq(r.bundled.back, colors.red + colors.blue)
  red.set(false)
  eq(r.bundled.back, colors.blue)
  eq(blue.getOutput(), true)
  eq(red.getOutput(), false)
  r.binp.back = colors.red
  eq(red.getInput(), true)
  eq(blue.getInput(), false)
end)

test("relay ports talk to the relay peripheral, not the computer", function()
  local e, r, relay = env()
  local port = assert(rsio.open("relay_0/left", e))
  port.set(true)
  eq(relay.out.left, 15)
  eq(r.out.left, nil)
  local none, err = rsio.open("relay_9/left", e)
  ok(none == nil and err:find("no redstone relay"))
end)

test("pulse switches on, waits, and switches off even when interrupted", function()
  local e, r, _, clock = env()
  local port = assert(rsio.open("front", e))
  port.pulse(1.5)
  eq(clock.sleeps, { 1.5 })
  eq(r.log, { "front:analog=15", "front:analog=0" })
  local boom = { redstone = r, peripheral = e.peripheral, sleep = function() error("interrupted") end }
  local p2 = assert(rsio.open("front", boom))
  throws(function() p2.pulse(1) end, "interrupted")
  eq(r.out.front, 0, "output is off again")
end)

test("rs commands", function()
  local e, r = env()
  local io = F.io()
  ok(rs.main({ "set", "top", "on" }, io, e))
  eq(r.out.top, 15)
  ok(rs.main({ "set", "top", "3" }, io, e))
  eq(r.out.top, 3)
  ok(rs.main({ "toggle", "top" }, io, e))
  eq(r.out.top, 0, "toggling a nonzero level switches off")
  r.inp.left = 4
  ok(rs.main({ "get", "left" }, io, e))
  ok(io.said[#io.said]:find("in 4"))
  ok(rs.main({ "pulse", "back", "2" }, io, e))
  eq(r.out.back, 0)
  ok(rs.main({ "list" }, io, e))
  eq(rs.main({ "set", "top", "loud" }, io, e), false)
  eq(rs.main({ "set", "nowhere", "on" }, io, e), false)
  eq(rs.main({ "pulse", "top", "-1" }, io, e), false)
  eq(rs.main({}, io, e), false)
end)

test("sequences parse, including nested repeats", function()
  local steps = assert(redseq.parse([[
# a comment
on top
wait 1
repeat 3
  pulse back 0.5   # inline comment
  wait 0.5
  repeat 2
    toggle left
  end
end
set front 7
off top
]]))
  eq(#steps, 5)
  eq(steps[3].op, "repeat")
  eq(steps[3].times, 3)
  eq(#steps[3].steps, 3)
  eq(redseq.count(steps), 1 + 1 + 3 * (1 + 1 + 2) + 1 + 1)
  eq(redseq.duration(steps), 1 + 3 * (0.5 + 0.5))
end)

test("sequence errors name the line", function()
  local s, err = redseq.parse("on top\nspin top\n")
  ok(s == nil and err:find("line 2") and err:find("unknown command"))
  s, err = redseq.parse("wait soon\n")
  ok(s == nil and err:find("line 1"))
  s, err = redseq.parse("repeat 2\non top\n")
  ok(s == nil and err:find("never closed"))
  s, err = redseq.parse("end\n")
  ok(s == nil and err:find("without"))
  s, err = redseq.parse("on nowhere\n")
  ok(s == nil and err:find("unknown side"))
  s, err = redseq.parse("pulse top 0\n")
  ok(s == nil and err:find("positive"))
  s, err = redseq.parse("repeat 0\nend\n")
  ok(s == nil and err:find("whole number"))
end)

test("running a sequence drives the outputs and takes the right time", function()
  local e, r, _, clock = env()
  local steps = assert(redseq.parse("on top\nwait 2\nrepeat 2\npulse back 0.5\nwait 1\nend\noff top\n"))
  ok(redseq.run(steps, e))
  eq(clock.now, 2 + 2 * 1.5)
  eq(r.out.top, 0)
  eq(r.out.back, 0)
  eq(r.log, { "top:analog=15", "back:analog=15", "back:analog=0", "back:analog=15", "back:analog=0", "top:analog=0" })
end)

test("a failing sequence switches everything it turned on back off", function()
  local e, r = env()
  local n = 0
  e.sleep = function() n = n + 1 if n == 2 then error("power cut") end end
  local steps = assert(redseq.parse("on top\nset left 9\nwait 1\nwait 1\non right\n"))
  local ok2, err = redseq.run(steps, e)
  ok(not ok2 and err:find("power cut"))
  eq(r.out.top, 0)
  eq(r.out.left, 0)
  eq(r.out.right, nil, "steps after the failure never ran")
end)

test("redseq command: check, run and list", function()
  local e, r = env()
  fs.makeDir("/tmp-seq")
  local h = fs.open("/tmp-seq/door.seq", "w") h.write("on top\nwait 1\noff top\n") h.close()
  local oldDir = redseq.DIR
  redseq.DIR = "/tmp-seq"
  local io = F.io()
  ok(redseq.main({ "check", "door" }, io, e))
  ok(io.said[1]:find("3 steps") and io.said[1]:find("1.0 seconds"))
  ok(redseq.main({ "run", "door", "--times", "2" }, io, e))
  eq(#r.log, 4)
  ok(io.said[#io.said]:find("2 times"))
  ok(redseq.main({ "list" }, io, e))
  ok(io.said[#io.said] == "door")
  eq(redseq.main({ "run", "missing" }, io, e), false)
  redseq.DIR = oldDir
  fs.delete("/tmp-seq")
end)
