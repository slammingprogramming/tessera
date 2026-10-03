-- SPDX-License-Identifier: AGPL-3.0-or-later
-- An MQTT 3.1.1 client: connect to a broker, publish messages, subscribe to topics, receive messages.
--   local c, err = mqtt.connect(stack, "10.0.0.5", { clientId = "kitchen", username = "u", password = "p", keepalive = 60, will = { topic = "home/kitchen/online", payload = "0", retain = true } })
--   c:subscribe("home/#", 1)     c:publish("home/kitchen/light", "on", { qos = 1, retain = true })
--   local m = c:receive(5)       -- { topic, payload, qos, retain } or nil + "timeout"
--   c:loop(function(m) print(m.topic, m.payload) end)      c:disconnect()
local socket = require("tsr.inet.socket")
local packet = require("tsr.mqtt.packet")
local topicMod = require("tsr.mqtt.topic")

local M = {}
local Client = {}
Client.__index = Client

M.packet, M.topic = packet, topicMod
M.TIMEOUT = 10

--- Connect and log in. opts: port (1883), clientId, clean (true), keepalive (60), username, password, will, timeout.
function M.connect(stack, host, opts)
  opts = opts or {}
  local timeout = opts.timeout or M.TIMEOUT
  local sock = socket.tcp(stack)
  local ok, err = sock:connect(host, opts.port or 1883, timeout)
  if not ok then return nil, "cannot connect to " .. tostring(host) .. ": " .. tostring(err) end
  local c = setmetatable({ sock = sock, nextId = 1, inbox = {}, pending = {}, keepalive = opts.keepalive or 60, lastSent = stack.clock(), stack = stack }, Client)
  local okS, serr = sock:send(packet.encode({ type = "connect", clientId = opts.clientId or "", clean = opts.clean ~= false, keepalive = c.keepalive,
    username = opts.username, password = opts.password, will = opts.will }), timeout)
  if not okS then return nil, "cannot send: " .. tostring(serr) end
  local p, why = packet.read(sock, timeout)
  if not p then sock:close() return nil, "no answer from the broker: " .. tostring(why) end
  if p.type ~= "connack" then sock:close() return nil, "the broker did not answer with CONNACK" end
  if p.code ~= 0 then sock:close() return nil, "the broker refused the connection: " .. (packet.CONNACK[p.code] or tostring(p.code)) end
  c.sessionPresent = p.sessionPresent
  return c
end

local function send(self, p)
  local ok, err = self.sock:send(packet.encode(p), M.TIMEOUT)
  if not ok then return nil, err end
  self.lastSent = self.stack.clock()
  return true
end

local function newId(self)
  local id = self.nextId
  self.nextId = self.nextId % 65535 + 1
  return id
end

--- Read one packet and deal with it. Returns the packet, or nil + reason ("timeout" when nothing came).
function Client:poll(timeout)
  local p, why = packet.read(self.sock, timeout)
  if not p then return nil, why end
  if p.type == "publish" then
    if p.qos == 1 then send(self, { type = "puback", id = p.id }) end
    self.inbox[#self.inbox + 1] = { topic = p.topic, payload = p.payload, qos = p.qos, retain = p.retain }
  elseif p.type == "puback" or p.type == "suback" or p.type == "unsuback" then
    self.pending[p.id] = p
  end
  return p
end

--- Wait for the answer with this packet id (messages that arrive meanwhile go to the inbox).
local function await(self, id, timeout)
  local deadline = self.stack.clock() + (timeout or M.TIMEOUT)
  while not self.pending[id] do
    local left = deadline - self.stack.clock()
    if left <= 0 then return nil, "timeout" end
    local p, why = self:poll(left)
    if not p and why ~= "timeout" then return nil, why end
  end
  local p = self.pending[id]
  self.pending[id] = nil
  return p
end

--- Publish a message. opts: qos (0 or 1; with 1 the call waits for the broker's receipt), retain.
function Client:publish(topic, payload, opts)
  opts = opts or {}
  if not topicMod.validTopic(topic) then return nil, "bad topic" end
  local qos = opts.qos or 0
  if qos > 1 then return nil, "only QoS 0 and 1 are supported" end
  local p = { type = "publish", topic = topic, payload = tostring(payload or ""), qos = qos, retain = opts.retain }
  if qos == 1 then p.id = newId(self) end
  local ok, err = send(self, p)
  if not ok then return nil, err end
  if qos == 1 then
    local ack, why = await(self, p.id, opts.timeout)
    if not ack then return nil, "no receipt: " .. tostring(why) end
  end
  return true
end

--- Subscribe to a filter (wildcards + and #). Returns the QoS the broker granted.
function Client:subscribe(filter, qos)
  if not topicMod.validFilter(filter) then return nil, "bad filter" end
  local id = newId(self)
  local ok, err = send(self, { type = "subscribe", id = id, topics = { { filter = filter, qos = qos or 0 } } })
  if not ok then return nil, err end
  local ack, why = await(self, id)
  if not ack then return nil, tostring(why) end
  if ack.codes[1] == 128 then return nil, "the broker refused the subscription" end
  return ack.codes[1]
end

function Client:unsubscribe(filter)
  local id = newId(self)
  local ok, err = send(self, { type = "unsubscribe", id = id, topics = { filter } })
  if not ok then return nil, err end
  local ack, why = await(self, id)
  return ack ~= nil, why
end

--- The next message (nil + "timeout" when none comes within the time). Keeps the connection alive meanwhile.
function Client:receive(timeout)
  local deadline = self.stack.clock() + (timeout or M.TIMEOUT)
  while #self.inbox == 0 do
    local now = self.stack.clock()
    if now >= deadline then return nil, "timeout" end
    if self.keepalive > 0 and now - self.lastSent > self.keepalive * 0.6 then send(self, { type = "pingreq" }) end
    local slice = math.min(deadline - now, self.keepalive > 0 and self.keepalive * 0.3 or 5)
    local p, why = self:poll(slice)
    if not p and why ~= "timeout" then return nil, why end
  end
  return table.remove(self.inbox, 1)
end

--- Call handler(message) for every message until it returns false or the connection ends.
function Client:loop(handler)
  while true do
    local m, why = self:receive(30)
    if m then
      if handler(m) == false then return true end
    elseif why ~= "timeout" then return nil, why end
  end
end

function Client:disconnect()
  send(self, { type = "disconnect" })
  self.sock:close()
  return true
end

return M
