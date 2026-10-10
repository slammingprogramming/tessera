-- SPDX-License-Identifier: AGPL-3.0-or-later
local packet = require("tsr.mqtt.packet")
local topic = require("tsr.mqtt.topic")
local brokerMod = require("tsr.mqtt.broker")
local mqtt = require("tsr.mqtt")
local daemon = require("tsr.mqtt.daemon")
local cli = require("tsr.mqtt.cli")
local socket = require("tsr.inet.socket")
local vfs = require("tsr.vfs")
local Sim = dofile("/tests/lib/inetsim.lua")

local ROOT = "/tmp/mqtt-test"

test("topics: validity, wildcards, the $ rule, subscription rights", function()
  ok(topic.validTopic("home/kitchen/light") and topic.validTopic("a") and not topic.validTopic("") and not topic.validTopic("a/+/b") and not topic.validTopic("a/#") and not topic.validTopic("x\0y"))
  ok(topic.validFilter("home/+/light") and topic.validFilter("#") and topic.validFilter("home/#") and topic.validFilter("+") and topic.validFilter("a//b"))
  ok(not topic.validFilter("") and not topic.validFilter("home/#/light") and not topic.validFilter("home/a+") and not topic.validFilter("home#") and not topic.validFilter("a/b#"))
  ok(topic.match("home/kitchen/light", "home/kitchen/light"))
  ok(topic.match("home/+/light", "home/kitchen/light") and not topic.match("home/+/light", "home/kitchen/main/light") and not topic.match("home/+", "home"))
  ok(topic.match("home/#", "home/kitchen/light") and topic.match("home/#", "home") and topic.match("#", "a/b/c") and topic.match("+/+", "a/b") and not topic.match("+/+", "a/b/c"))
  ok(not topic.match("#", "$SYS/broker/uptime") and not topic.match("+/broker/uptime", "$SYS/broker/uptime") and topic.match("$SYS/#", "$SYS/broker/uptime"))
  ok(topic.match("a//b", "a//b") and not topic.match("a/b", "a//b"))
  ok(topic.covers("home/#", "home/kitchen/#") and topic.covers("home/+/light", "home/kitchen/light") and topic.covers("home/+/light", "home/+/light") and topic.covers("#", "x/y"))
  ok(not topic.covers("home/+/light", "home/#") and not topic.covers("home/kitchen", "home/+") and not topic.covers("home/kitchen/light", "home/kitchen") and not topic.covers("a/b", "a/b/c"))
end)

local function roundTrip(p)
  local bytes = packet.encode(p)
  local code, flags = math.floor(bytes:byte(1) / 16), bytes:byte(1) % 16
  local len, mult, i = 0, 1, 2
  repeat
    local b = bytes:byte(i)
    len = len + (b % 128) * mult
    mult = mult * 128
    i = i + 1
  until b < 128
  eq(#bytes - i + 1, len, "the length field is right")
  return assert(packet.decode(code, flags, bytes:sub(i)))
end

test("packets: every kind encodes and decodes, lengths of any size, protocol errors are refused", function()
  local c = roundTrip({ type = "connect", clientId = "dev1", clean = false, keepalive = 30, username = "u", password = "p", will = { topic = "w/t", payload = "gone", qos = 1, retain = true } })
  eq({ c.type, c.clientId, c.clean, c.keepalive, c.username, c.password, c.level }, { "connect", "dev1", false, 30, "u", "p", 4 })
  eq(c.will, { topic = "w/t", payload = "gone", qos = 1, retain = true })
  local plain = roundTrip({ type = "connect", clientId = "", clean = true, keepalive = 0 })
  eq({ plain.clientId, plain.clean, plain.username, plain.will }, { "", true, nil, nil })
  eq(roundTrip({ type = "connack", sessionPresent = true, code = 5 }), { type = "connack", sessionPresent = true, code = 5 })
  local pub = roundTrip({ type = "publish", topic = "a/b", payload = "hello", qos = 1, retain = true, dup = true, id = 513 })
  eq(pub, { type = "publish", topic = "a/b", payload = "hello", qos = 1, retain = true, dup = true, id = 513 })
  eq(roundTrip({ type = "publish", topic = "a", payload = "" }), { type = "publish", topic = "a", payload = "", qos = 0, retain = false, dup = false })
  local big = string.rep("x", 20000)
  eq(roundTrip({ type = "publish", topic = "big", payload = big }).payload, big)
  eq(#packet.encode({ type = "publish", topic = "big", payload = string.rep("x", 127 - 5) }), 2 + 127)
  eq(roundTrip({ type = "puback", id = 7 }), { type = "puback", id = 7 })
  eq(roundTrip({ type = "subscribe", id = 9, topics = { { filter = "a/#", qos = 1 }, { filter = "b", qos = 0 } } }), { type = "subscribe", id = 9, topics = { { filter = "a/#", qos = 1 }, { filter = "b", qos = 0 } } })
  eq(roundTrip({ type = "suback", id = 9, codes = { 1, 128 } }), { type = "suback", id = 9, codes = { 1, 128 } })
  eq(roundTrip({ type = "unsubscribe", id = 3, topics = { "a", "b/c" } }), { type = "unsubscribe", id = 3, topics = { "a", "b/c" } })
  eq(roundTrip({ type = "unsuback", id = 3 }), { type = "unsuback", id = 3 })
  for _, t in ipairs({ "pingreq", "pingresp", "disconnect" }) do eq(roundTrip({ type = t }), { type = t }) end
  -- a connect as a real client sends it (checked by hand against the specification)
  eq(packet.encode({ type = "connect", clientId = "a", clean = true, keepalive = 60 }), "\16\13\0\4MQTT\4\2\0\60\0\1a")
  -- bad data
  ok(packet.decode(1, 0, "\0\4XXXX\4\2\0\60\0\0") == nil)
  ok(packet.decode(3, 6, "\0\1a") == nil, "QoS 3")
  ok(packet.decode(8, 2, "\0\1") == nil, "subscribe without topics")
  ok(packet.decode(15, 0, "") == nil, "unknown type")
  ok(packet.decode(3, 0, "\0\9ab") == nil, "a topic longer than the packet")
  ok(packet.decode(1, 0, "\0\4MQTT\4\2") == nil, "a short connect")
end)

--- A broker with a recording connection for each client.
local function newBroker(opts)
  opts = opts or {}
  local clock = { now = 0 }
  opts.now = function() return clock.now end
  local b = brokerMod.new(opts)
  local function client()
    local c = { received = {}, closed = false }
    c.rec = b:open({ send = function(bytes)
        local code, flags = math.floor(bytes:byte(1) / 16), bytes:byte(1) % 16
        local i = 2
        while bytes:byte(i) >= 128 do i = i + 1 end
        c.received[#c.received + 1] = assert(packet.decode(code, flags, bytes:sub(i + 1)))
        return true
      end, close = function() c.closed = true end })
    function c:send(p) b:handle(self.rec, p) end
    function c:take()
      local list = self.received
      self.received = {}
      return list
    end
    function c:connect(id, extra)
      local p = { type = "connect", clientId = id, clean = true, keepalive = 0, level = 4 }
      for k, v in pairs(extra or {}) do p[k] = v end
      self:send(p)
      local list = self:take()
      local first = table.remove(list, 1)
      self.received = list   -- whatever else came with the CONNACK stays to be read
      return first
    end
    return c
  end
  return b, clock, client
end

test("the broker: logging in, accounts, limits", function()
  vfs.fs.delete(ROOT)
  local users = brokerMod.users(ROOT .. "/users.db", 3)
  ok(users:add("alice", "secret-1"))
  ok(select(2, users:add("bad name", "secret")):find("letters, digits", 1, true) and select(2, users:add("bob", "x")):find("at least 4", 1, true))
  eq(users:check("alice", "secret-1"), "alice") eq(users:check("alice", "nope"), nil) eq(users:check("nobody", "x"), nil)
  eq(users:list(), { "alice" })
  local b, clock, client = newBroker({ users = users, maxClients = 2 })
  -- no name, wrong password, right password
  local a = client()
  eq(a:connect("d1").code, 5) ok(a.closed)
  a = client()
  eq(a:connect("d1", { username = "alice", password = "wrong" }).code, 4)
  a = client()
  local ack = a:connect("d1", { username = "alice", password = "secret-1" })
  eq({ ack.code, ack.sessionPresent }, { 0, false })
  eq(b.stats.connected, 1)
  -- the second device with the same id pushes the first one out
  local a2 = client()
  eq(a2:connect("d1", { username = "alice", password = "secret-1" }).code, 0)
  ok(a.closed and not a2.closed) eq(b.stats.connected, 1)
  -- a limit on the number of devices
  local a3, a4 = client(), client()
  eq(a3:connect("d2", { username = "alice", password = "secret-1" }).code, 0)
  eq(a4:connect("d3", { username = "alice", password = "secret-1" }).code, 3)
  -- protocol level 3.1 and empty ids
  local old = client()
  eq(old:connect("x", { level = 3 }).code, 1) ok(old.closed)
  local anon, _, clientB = newBroker({ allowAnonymous = true })
  local c1 = clientB()
  local ca = c1:connect("")
  eq(ca.code, 0)
  local c2 = clientB()
  eq(c2:connect("", { clean = false }).code, 2)
  -- a second CONNECT on a connection is a violation
  c1:send({ type = "connect", clientId = "again", clean = true, keepalive = 0, level = 4 })
  ok(c1.closed)
end)

test("the broker: routing, wildcards, QoS, retained messages", function()
  local b, clock, client = newBroker({ allowAnonymous = true })
  local pubr, s1, s2, s3 = client(), client(), client(), client()
  for i, c in ipairs({ pubr, s1, s2, s3 }) do c:connect("c" .. i) end
  s1:send({ type = "subscribe", id = 1, topics = { { filter = "home/+/light", qos = 1 } } })
  eq(s1:take(), { { type = "suback", id = 1, codes = { 1 } } })
  s2:send({ type = "subscribe", id = 1, topics = { { filter = "home/#", qos = 0 }, { filter = "bad/#/x", qos = 0 }, { filter = "#", qos = 2 } } })
  eq(s2:take(), { { type = "suback", id = 1, codes = { 0, 128, 1 } } })
  s3:send({ type = "subscribe", id = 1, topics = { { filter = "garage/door", qos = 0 } } })
  s3:take()
  pubr:send({ type = "publish", topic = "home/kitchen/light", payload = "on", qos = 1, id = 77 })
  eq(pubr:take(), { { type = "puback", id = 77 } })
  local got1, got2 = s1:take(), s2:take()
  eq(#got1, 1) eq({ got1[1].topic, got1[1].payload, got1[1].qos, got1[1].retain }, { "home/kitchen/light", "on", 1, false })
  ok(got1[1].id ~= nil)
  eq(#got2, 1, "a client with two matching filters gets the message once") eq(got2[1].qos, 1, "with the best QoS of its filters")
  eq(#s3:take(), 0)
  -- the subscriber confirms: nothing left to resend
  s1:send({ type = "puback", id = got1[1].id })
  clock.now = 100
  b:tick()
  eq(#s1:take(), 0)
  -- a message that is not acknowledged is sent again with the dup flag, and finally given up
  pubr:send({ type = "publish", topic = "home/hall/light", payload = "off", qos = 1, id = 78 })
  pubr:take() s1:take()
  clock.now = 125 b:tick()
  local again = s1:take()
  eq(#again, 1) ok(again[1].dup)
  clock.now = 150 b:tick() clock.now = 175 b:tick()
  s1:take()
  clock.now = 200 b:tick()
  eq(#s1:take(), 0)
  -- QoS 0 stays at 0
  pubr:send({ type = "publish", topic = "home/kitchen/light", payload = "x", qos = 0 })
  eq(s1:take()[1].qos, 0)
  -- retained messages: stored, delivered at subscribe time, replaced, cleared by an empty payload
  pubr:send({ type = "publish", topic = "garage/door", payload = "closed", qos = 0, retain = true })
  eq(#s3:take(), 1)
  local late = client()
  late:connect("late")
  late:send({ type = "subscribe", id = 5, topics = { { filter = "garage/+", qos = 1 } } })
  local l = late:take()
  eq(l[1].type, "suback") eq({ l[2].topic, l[2].payload, l[2].retain }, { "garage/door", "closed", true })
  pubr:send({ type = "publish", topic = "garage/door", payload = "open", qos = 0, retain = true })
  late:take()
  late:send({ type = "subscribe", id = 6, topics = { { filter = "garage/door", qos = 0 } } })
  eq(late:take()[2].payload, "open")
  pubr:send({ type = "publish", topic = "garage/door", payload = "", qos = 0, retain = true })
  late:take()
  late:send({ type = "subscribe", id = 7, topics = { { filter = "garage/door", qos = 0 } } })
  eq(#late:take(), 1, "only the SUBACK: the retained message is gone")
  -- unsubscribing
  s1:send({ type = "unsubscribe", id = 2, topics = { "home/+/light" } })
  eq(s1:take(), { { type = "unsuback", id = 2 } })
  pubr:send({ type = "publish", topic = "home/kitchen/light", payload = "y", qos = 0 })
  eq(#s1:take(), 0)
  -- ping
  s1:send({ type = "pingreq" })
  eq(s1:take(), { { type = "pingresp" } })
  -- $SYS topics are not reached by a plain #
  local sys = b:sys()
  ok(#sys >= 5 and sys[1][1] == "$SYS/broker/uptime")
  -- the retained table can be saved and restored
  local b2 = brokerMod.new({ allowAnonymous = true })
  pubr:send({ type = "publish", topic = "keep/me", payload = "42", qos = 1, id = 1, retain = true })
  b2:importRetained(b:exportRetained())
  eq(b2.retained["keep/me"].payload, "42")
  -- QoS 2 and bad topics end the connection
  local q2 = client()
  q2:connect("q2")
  q2:send({ type = "publish", topic = "a", payload = "x", qos = 2, id = 1 })
  ok(q2.closed)
  local bad = client()
  bad:connect("bad")
  bad:send({ type = "publish", topic = "a/+", payload = "x", qos = 0 })
  ok(bad.closed)
  -- packets before CONNECT
  local early = client()
  early:send({ type = "pingreq" })
  ok(early.closed)
end)

test("the broker: will messages, persistent sessions, keepalive, access lists, limits", function()
  local b, clock, client = newBroker({ allowAnonymous = true, acl = {
    sensor = { pub = { "home/+/+/state" }, sub = {} }, ["*"] = { pub = { "chat/#", "home/+/online" }, sub = { "home/#", "chat/#" } } }, maxSubscriptions = 2, authenticate = nil })
  local watcher = client()
  watcher:connect("watcher")
  watcher:send({ type = "subscribe", id = 1, topics = { { filter = "home/+/online", qos = 0 } } })
  watcher:take()
  -- will: sent when the device disappears, not when it says goodbye
  local dev = client()
  dev:connect("dev", { will = { topic = "home/dev/online", payload = "0", qos = 0, retain = true } })
  b:close(dev.rec, false)
  eq(watcher:take()[1].payload, "0")
  eq(b.retained["home/dev/online"].payload, "0")
  local dev2 = client()
  dev2:connect("dev2", { will = { topic = "home/dev2/online", payload = "0", qos = 0 } })
  dev2:send({ type = "disconnect" })
  eq(#watcher:take(), 0) ok(dev2.closed)
  -- keepalive: a silent device is dropped and its will is sent
  local quiet = client()
  quiet:connect("quiet", { keepalive = 10, will = { topic = "home/quiet/online", payload = "0", qos = 0 } })
  clock.now = 10 b:tick()
  ok(not quiet.closed)
  clock.now = 20 b:tick()
  ok(quiet.closed) eq(watcher:take()[1].topic, "home/quiet/online")
  -- access list: a sensor may publish states, nothing else, and may not subscribe; others read home/# and chat
  local sensor = client()
  sensor:connect("sensor")
  sensor.rec.user = "sensor"
  sensor:send({ type = "publish", topic = "home/kitchen/light/state", payload = "on", qos = 1, id = 1 })
  eq(sensor:take(), { { type = "puback", id = 1 } })
  sensor:send({ type = "subscribe", id = 2, topics = { { filter = "home/#", qos = 0 } } })
  eq(sensor:take()[1].codes, { 128 })
  watcher:send({ type = "subscribe", id = 3, topics = { { filter = "home/+/+/state", qos = 0 }, { filter = "secret/#", qos = 0 }, { filter = "chat/+", qos = 0 } } })
  eq(watcher:take()[1].codes, { 0, 128, 128 }, "the subscription limit of 2 applies to the third")
  sensor:send({ type = "publish", topic = "home/kitchen/light/state", payload = "off", qos = 0 })
  eq(watcher:take()[1].payload, "off")
  sensor:send({ type = "publish", topic = "home/kitchen/light/set", payload = "on", qos = 0 })
  eq(#watcher:take(), 0)
  eq(b.stats.dropped >= 1, true)
  -- persistent sessions: subscriptions survive, QoS 1 messages wait
  local p = client()
  eq(p:connect("pers", { clean = false }).sessionPresent, false)
  p:send({ type = "subscribe", id = 1, topics = { { filter = "chat/#", qos = 1 } } })
  p:take()
  p:send({ type = "disconnect" })
  local talker = client()
  talker:connect("talker")
  talker:send({ type = "publish", topic = "chat/room", payload = "hello?", qos = 1, id = 1 })
  talker:send({ type = "publish", topic = "chat/room", payload = "anyone?", qos = 0 })
  local p2 = client()
  local ack = p2:connect("pers", { clean = false })
  eq(ack.sessionPresent, true)
  local rest = p2:take()
  eq(#rest, 1) eq({ rest[1].topic, rest[1].payload, rest[1].qos }, { "chat/room", "hello?", 1 })
  -- a clean session forgets everything
  p2:send({ type = "disconnect" })
  local p3 = client()
  eq(p3:connect("pers", { clean = true }).sessionPresent, false)
  eq(#p3:take(), 0)
end)

--- A broker on a simulated network with workers that serve TCP connections.
local function networkBroker(opts)
  if vfs.fs.exists(ROOT) then vfs.fs.delete(ROOT) end
  vfs.fs.makeDir(ROOT)
  local sim = Sim.new()
  local seg = sim:segment("lan")
  local h = sim:host("broker")
  sim:plug(h, "eth0", seg, "10.0.0.1/24")
  local hosts = {}
  for i = 1, 4 do
    hosts[i] = sim:host("dev" .. i)
    sim:plug(hosts[i], "eth0", seg, "10.0.0." .. (10 + i) .. "/24")
  end
  opts = opts or {}
  opts.now = function() return h.clock() end
  local b = brokerMod.new(opts)
  local l = socket.tcp(h)
  l:bind(nil, 1883)
  l:listen(8)
  local t = sim:spawn(function()
    while true do
      local c = l:accept(300)
      if not c then return end
      local worker = sim:spawn(function() daemon.serve(b, c) end)
      worker.daemon = true
    end
  end)
  t.daemon = true
  sim:run(0.2)
  return sim, b, hosts
end

test("over the network: connect, subscribe, publish, receive; QoS 1; accounts; will on a dead connection", function()
  local users
  vfs.fs.makeDir(ROOT)
  local sim, b, hosts = networkBroker({ allowAnonymous = false })
  b.users = brokerMod.users(ROOT .. "/users.db", 3)
  assert(b.users:add("home", "pass-home"))
  -- refused without or with a wrong password
  local c, err = mqtt.connect(hosts[1], "10.0.0.1", { clientId = "x" })
  ok(c == nil and err:find("not authorized", 1, true), tostring(err))
  c, err = mqtt.connect(hosts[1], "10.0.0.1", { clientId = "x", username = "home", password = "nope" })
  ok(c == nil and err:find("bad user name or password", 1, true), tostring(err))
  -- two devices talking
  local light = assert(mqtt.connect(hosts[1], "10.0.0.1", { clientId = "light", username = "home", password = "pass-home", keepalive = 30,
    will = { topic = "home/kitchen/light/online", payload = "0", retain = true } }))
  local panel = assert(mqtt.connect(hosts[2], "10.0.0.1", { clientId = "panel", username = "home", password = "pass-home" }))
  eq(light:subscribe("home/kitchen/light/set", 1), 1)
  eq(panel:subscribe("home/+/+/online", 0), 0)
  ok(not select(1, panel:subscribe("bad/#/x")))
  local got
  sim:spawn(function() got = light:receive(10) end)
  ok(panel:publish("home/kitchen/light/set", "on", { qos = 1 }))
  sim:run(0.5)
  eq({ got.topic, got.payload, got.qos }, { "home/kitchen/light/set", "on", 1 })
  -- a retained message reaches a device that connects later
  ok(panel:publish("home/hall/temp", "21.5", { retain = true }))
  local late = assert(mqtt.connect(hosts[3], "10.0.0.1", { clientId = "late", username = "home", password = "pass-home" }))
  eq(late:subscribe("home/hall/#", 0), 0)
  local m = assert(late:receive(5))
  eq({ m.topic, m.payload, m.retain }, { "home/hall/temp", "21.5", true })
  eq(select(2, late:receive(1)), "timeout")
  -- the connection of the light dies without a goodbye: its will is announced
  light.sock:reset()
  sim:run(2)
  local w = assert(panel:receive(5))
  eq({ w.topic, w.payload }, { "home/kitchen/light/online", "0" })
  eq(b.stats.connected, 2)
  panel:disconnect() late:disconnect()
  sim:run(1)
  eq(b.stats.connected, 0)
end)

test("the mqtt commands and the user database", function()
  local sim, b, hosts = networkBroker({ allowAnonymous = true })
  local function ctx(stack)
    local out = { lines = {}, errors = {} }
    out.ctx = { stack = stack, say = function(t) out.lines[#out.lines + 1] = t end, err = function(t) out.errors[#out.errors + 1] = t end, readPassword = function() return "typed-pass" end }
    return out
  end
  local sub = ctx(hosts[1])
  local result
  sim:spawn(function() result = cli.run({ "sub", "10.0.0.1", "lab/#", "-n", "2", "-t", "20" }, sub.ctx) end)
  sim:run(0.5)
  local pub = ctx(hosts[2])
  ok(cli.run({ "pub", "10.0.0.1", "lab/temp", "hot", "and", "dry", "-r" }, pub.ctx))
  ok(cli.run({ "pub", "10.0.0.1", "lab/door", "closed", "-q", "1" }, ctx(hosts[2]).ctx))
  sim:run(1)
  eq(sub.lines, { "lab/temp hot and dry", "lab/door closed" })
  ok(result)
  local bad = ctx(hosts[2])
  ok(not cli.run({ "pub", "10.0.0.1" }, bad.ctx) and bad.errors[1]:find("usage: mqtt pub", 1, true))
  -- administration (files redirected to the test folder)
  local savedUsers, savedConfig = daemon.USERS, daemon.CONFIG
  daemon.USERS, daemon.CONFIG = ROOT .. "/ctl-users.db", ROOT .. "/ctl.lua"
  local c1 = ctx(nil)
  ok(cli.ctl({ "init" }, c1.ctx) and vfs.fs.exists(daemon.CONFIG))
  ok(not cli.ctl({ "init" }, ctx(nil).ctx))
  ok(cli.ctl({ "user", "add", "alice" }, c1.ctx))
  ok(cli.ctl({ "user", "add", "bob", "bob-pass" }, c1.ctx))
  local list = ctx(nil)
  cli.ctl({ "user", "list" }, list.ctx)
  eq(list.lines, { "alice", "bob" })
  ok(brokerMod.users(daemon.USERS):check("alice", "typed-pass"))
  ok(cli.ctl({ "user", "del", "bob" }, c1.ctx) and not cli.ctl({ "user", "del", "bob" }, ctx(nil).ctx))
  local st = ctx(nil)
  ok(cli.ctl({ "status" }, st.ctx))
  ok(st.lines[1]:find("port 1883, anonymous devices refused, 1 user(s)", 1, true), st.lines[1])
  eq(daemon.loadConfig().port, 1883)
  daemon.USERS, daemon.CONFIG = savedUsers, savedConfig
end)

test("the broker: a will needs the right to publish, and a stored session belongs to its user", function()
  local users = { alice = "a", bob = "b" }
  local b, clock, client = newBroker({ authenticate = function(name, pw) if users[name] and users[name] == pw then return name end end,
    acl = { alice = { pub = { "chat/#" }, sub = { "secret/#", "chat/#" } }, bob = { pub = { "chat/#" }, sub = { "chat/#" } } } })
  -- a will on a topic the user may not publish to is refused at CONNECT
  local mallory = client()
  local ack = mallory:connect("m1", { username = "bob", password = "b", will = { topic = "home/door/set", payload = "open", qos = 0, retain = true } })
  eq(ack.code, 5) ok(mallory.closed)
  eq(b.retained["home/door/set"], nil)
  -- topics with wildcards or in $SYS are no wills either
  local m2 = client()
  eq(m2:connect("m2", { username = "bob", password = "b", will = { topic = "chat/#", payload = "x", qos = 0 } }).code, 5)
  -- an allowed will still works
  local watcher = client()
  watcher:connect("w", { username = "alice", password = "a" })
  watcher:send({ type = "subscribe", id = 1, topics = { { filter = "chat/#", qos = 0 } } })
  watcher:take()
  local good = client()
  eq(good:connect("g", { username = "bob", password = "b", will = { topic = "chat/bob", payload = "gone", qos = 2 } }).code, 0)
  b:close(good.rec, false)
  eq(watcher:take()[1].payload, "gone")
  -- alice's persistent session cannot be taken over by bob with the same client id
  local a1 = client()
  a1:connect("panel", { username = "alice", password = "a", clean = false })
  a1:send({ type = "subscribe", id = 1, topics = { { filter = "secret/#", qos = 1 } } })
  a1:take()
  a1:send({ type = "disconnect" })
  local talker = client()
  talker:connect("t", { username = "alice", password = "a" })
  b.acl.alice.pub = { "chat/#", "secret/#" }
  talker:send({ type = "publish", topic = "secret/plan", payload = "the plan", qos = 1, id = 1 })
  local bobPanel = client()
  local bobAck = bobPanel:connect("panel", { username = "bob", password = "b", clean = false })
  eq(bobAck.sessionPresent, false)
  eq(#bobPanel:take(), 0, "none of alice's queued messages")
  bobPanel:send({ type = "publish", topic = "chat/x", payload = "hi", qos = 0 })
  -- alice gets her own session back, with her queued message
  bobPanel:send({ type = "disconnect" })
  local a2 = client()
  eq(a2:connect("panel", { username = "alice", password = "a", clean = false }).sessionPresent, false, "bob's connection replaced the stored session")
end)
