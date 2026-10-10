-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The MQTT broker: devices connect and publish messages to topics; the broker passes each message on to everyone who subscribed to a matching filter.
-- Supported (MQTT 3.1.1): QoS 0 and 1, retained messages, will messages (sent when a device vanishes), persistent sessions (queued QoS 1 mail for a device that
-- is offline), wildcards, user names and passwords, access lists per user, limits. QoS 2 is not supported (a client asking for it is disconnected).
-- The broker does not touch sockets: a connection is a "sink" { send = function(bytes), close = function() } and packets are given to broker:handle(client, packet),
-- which makes it easy to test; tsr.mqtt.daemon connects it to TCP.
local packet = require("tsr.mqtt.packet")
local topicMod = require("tsr.mqtt.topic")
local vfs = require("tsr.vfs")

local M = {}
local Broker = {}
Broker.__index = Broker

M.RETRY_AFTER = 20
M.MAX_TRIES = 3

---------------------------------------------------------------------------------------------------------------------
-- User accounts (a small file of salted password hashes)
---------------------------------------------------------------------------------------------------------------------

--- A user database: users:add(name, password), :remove(name), :check(name, password), :list().
function M.users(path, iterations)
  local crypto = require("tsr.crypto")
  iterations = iterations or 200
  local U = {}
  local function load() return vfs.readTable(path) or {} end
  function U:add(name, password)
    if not name:match("^[%w][%w._%-]*$") then return nil, "a user name has letters, digits, dots, dashes and underscores" end
    if #password < 4 then return nil, "the password needs at least 4 characters" end
    local t = load()
    local salt = crypto.toHex(crypto.rand.bytes(8))
    t[name] = salt .. "$" .. iterations .. "$" .. crypto.toHex(crypto.kdf.pbkdf2(password, salt, iterations, 32))
    vfs.mkdirp(path:match("^(.*)/[^/]*$") or "/")
    return vfs.writeTable(path, t)
  end
  function U:remove(name)
    local t = load()
    if not t[name] then return nil, "no such user" end
    t[name] = nil
    return vfs.writeTable(path, t)
  end
  function U:check(name, password)
    local rec = load()[name or ""]
    if not rec or not password then return nil end
    local salt, it, digest = rec:match("^(%x+)%$(%d+)%$(%x+)$")
    if not salt then return nil end
    local got = crypto.toHex(crypto.kdf.pbkdf2(password, salt, tonumber(it), 32))
    if crypto.equal(got, digest) then return name end
    return nil
  end
  function U:list()
    local out = {}
    for n in pairs(load()) do out[#out + 1] = n end
    table.sort(out)
    return out
  end
  return U
end

---------------------------------------------------------------------------------------------------------------------

--- opts: allowAnonymous (default false), users (a user database, or authenticate = function(name, password) -> name|nil), acl = { [user or "*"] = { pub = { filters }, sub = { filters } } },
--- maxClients (50), maxSubscriptions (100 per client), maxRetained (1000), now (function), log (function).
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    allowAnonymous = opts.allowAnonymous == true, users = opts.users, authenticate = opts.authenticate, acl = opts.acl,
    maxClients = opts.maxClients or 50, maxSubscriptions = opts.maxSubscriptions or 100, maxRetained = opts.maxRetained or 1000, maxQueue = opts.maxQueue or 100,
    now = opts.now or function() return os.clock() end, log = opts.log or function() end,
    clients = {}, sessions = {}, retained = {}, nretained = 0,
    stats = { connected = 0, received = 0, sent = 0, dropped = 0, connections = 0 }, started = (opts.now or os.clock)(),
  }, Broker)
end

local function send(c, p)
  local ok = c.sink.send(packet.encode(p))
  return ok ~= nil and ok ~= false
end

--- A new connection. Returns the client record to pass to handle().
function Broker:open(sink)
  return { sink = sink, state = "new", subs = {}, inflight = {}, nextId = 1, lastSeen = self.now(), keepalive = 0 }
end

local function allowed(self, c, kind, topic)
  if not self.acl then return true end
  local rules = self.acl[c.user or "*"] or self.acl["*"]
  if not rules then return false end
  local list = rules[kind]
  if not list then return false end
  for _, f in ipairs(list) do
    if kind == "pub" then
      if topicMod.match(f, topic) then return true end
    elseif topicMod.covers(f, topic) then return true end
  end
  return false
end

local function nextId(c)
  local id = c.nextId
  c.nextId = c.nextId % 65535 + 1
  return id
end

--- Hand a message to one connected client (or queue it for a persistent session that is offline).
local function deliver(self, target, topic, payload, qos, retain)
  if target.connected == false then
    if qos > 0 and #target.queue < self.maxQueue then target.queue[#target.queue + 1] = { topic = topic, payload = payload, qos = qos } end
    return
  end
  local p = { type = "publish", topic = topic, payload = payload, qos = qos, retain = retain }
  if qos > 0 then
    p.id = nextId(target)
    target.inflight[p.id] = { topic = topic, payload = payload, qos = qos, sent = self.now(), tries = 1 }
  end
  if send(target, p) then self.stats.sent = self.stats.sent + 1 else self.stats.dropped = self.stats.dropped + 1 end
end

--- Pass a message to every subscriber. retain = the retain flag of the original publish (subscribers get it as false: only the stored copy delivered at subscribe time has it).
function Broker:route(topic, payload, qos)
  local function targets()
    local list = {}
    for _, c in pairs(self.clients) do if c.state == "connected" then list[#list + 1] = c end end
    for id, s in pairs(self.sessions) do if not self.clients[id] then list[#list + 1] = s end end
    return list
  end
  for _, t in ipairs(targets()) do
    local best
    for filter, q in pairs(t.subs) do
      if topicMod.match(filter, topic) and (best == nil or q > best) then best = q end
    end
    if best ~= nil then deliver(self, t, topic, payload, math.min(best, qos), false) end
  end
end

function Broker:setRetained(topic, payload, qos)
  if payload == "" then
    if self.retained[topic] then self.retained[topic] = nil self.nretained = self.nretained - 1 end
    return
  end
  if #payload > 4096 then return end
  if not self.retained[topic] then
    if self.nretained >= self.maxRetained then return end
    self.nretained = self.nretained + 1
  end
  self.retained[topic] = { payload = payload, qos = qos }
end

--- Close a connection. graceful = the client said goodbye (then its will is dropped).
function Broker:close(c, graceful)
  if c.state == "closed" then return end
  local wasConnected = c.state == "connected"
  c.state = "closed"
  if wasConnected then
    if self.clients[c.id] == c then self.clients[c.id] = nil self.stats.connected = self.stats.connected - 1 end
    if not graceful and c.will then
      if c.will.retain then self:setRetained(c.will.topic, c.will.payload, c.will.qos) end
      self:route(c.will.topic, c.will.payload, c.will.qos)
    end
    if not c.clean then
      -- keep the subscriptions and the unacknowledged messages for the next time
      local queue = {}
      for _, m in pairs(c.inflight) do queue[#queue + 1] = m end
      self.sessions[c.id] = { connected = false, subs = c.subs, queue = queue, inflight = {}, nextId = c.nextId, state = "offline", user = c.user }
    else
      self.sessions[c.id] = nil
    end
  end
  pcall(c.sink.close)
end

local function connect(self, c, p)
  if c.state ~= "new" then return self:close(c, false) end
  if p.level ~= 4 then send(c, { type = "connack", code = 1 }) return self:close(c, true) end
  local id = p.clientId
  if id == "" then
    if not p.clean then send(c, { type = "connack", code = 2 }) return self:close(c, true) end
    id = "auto-" .. require("tsr.crypto").toHex(require("tsr.crypto").rand.bytes(4))
  end
  if #id > 128 then send(c, { type = "connack", code = 2 }) return self:close(c, true) end
  -- who is it
  local user
  if p.username then
    if self.users then user = self.users:check(p.username, p.password)
    elseif self.authenticate then user = self.authenticate(p.username, p.password) end
    if not user then
      if self.allowAnonymous and not self.users and not self.authenticate then user = nil
      else send(c, { type = "connack", code = 4 }) self.log("login refused for " .. tostring(p.username)) return self:close(c, true) end
    end
  elseif not self.allowAnonymous then
    send(c, { type = "connack", code = 5 })
    return self:close(c, true)
  end
  -- a will message is a publish made later: it needs a valid topic and the right to publish there, checked now
  if p.will then
    if not topicMod.validTopic(p.will.topic) or not allowed(self, { user = user }, "pub", p.will.topic) then
      send(c, { type = "connack", code = 5 })
      self.log(("%s may not set a will on %s"):format(tostring(user or id), tostring(p.will.topic)))
      return self:close(c, true)
    end
    p.will.qos = math.min(p.will.qos or 0, 1)
  end
  local old = self.clients[id]
  if not old and self.stats.connected >= self.maxClients then send(c, { type = "connack", code = 3 }) return self:close(c, true) end
  if old then self:close(old, false) end
  c.id, c.user, c.clean, c.keepalive, c.will = id, user, p.clean, p.keepalive or 0, p.will
  c.state = "connected"
  local present = false
  local session = self.sessions[id]
  -- a stored session belongs to the user who made it; somebody else with the same client id starts from nothing
  if session and session.user ~= user then session = nil end
  if session and not p.clean then
    present = true
    c.subs, c.nextId = {}, session.nextId
    for filter, q in pairs(session.subs) do
      if allowed(self, c, "sub", filter) then c.subs[filter] = q end      -- the access list may have changed since
    end
  end
  self.clients[id] = c
  self.stats.connected = self.stats.connected + 1
  self.stats.connections = self.stats.connections + 1
  send(c, { type = "connack", code = 0, sessionPresent = present })
  if present then
    local queue = session.queue
    self.sessions[id] = nil
    for _, m in ipairs(queue) do deliver(self, c, m.topic, m.payload, m.qos, false) end
  else
    self.sessions[id] = nil
  end
  self.log("connected: " .. id .. (user and (" as " .. user) or ""))
end

local function publish(self, c, p)
  self.stats.received = self.stats.received + 1
  if p.qos == 2 then return self:close(c, false) end
  if not topicMod.validTopic(p.topic) then return self:close(c, false) end
  local ok = allowed(self, c, "pub", p.topic)
  if ok then
    if p.retain then self:setRetained(p.topic, p.payload, p.qos) end
    self:route(p.topic, p.payload, p.qos)
  else
    self.stats.dropped = self.stats.dropped + 1
    self.log(("%s may not publish to %s"):format(tostring(c.id), p.topic))
  end
  if p.qos == 1 then send(c, { type = "puback", id = p.id }) end
end

local function subscribe(self, c, p)
  local codes, accepted = {}, {}
  local count = 0
  for _ in pairs(c.subs) do count = count + 1 end
  for i, s in ipairs(p.topics) do
    if not topicMod.validFilter(s.filter) or not allowed(self, c, "sub", s.filter) or (c.subs[s.filter] == nil and count >= self.maxSubscriptions) then
      codes[i] = 128
    else
      local q = math.min(s.qos, 1)
      if c.subs[s.filter] == nil then count = count + 1 end
      c.subs[s.filter] = q
      codes[i] = q
      accepted[#accepted + 1] = { filter = s.filter, qos = q }
    end
  end
  send(c, { type = "suback", id = p.id, codes = codes })
  for _, s in ipairs(accepted) do
    for t, m in pairs(self.retained) do
      if topicMod.match(s.filter, t) then deliver(self, c, t, m.payload, math.min(s.qos, m.qos), true) end
    end
  end
end

--- Process one packet from a client.
function Broker:handle(c, p)
  c.lastSeen = self.now()
  if p.type == "connect" then return connect(self, c, p) end
  if c.state ~= "connected" then return self:close(c, false) end
  if p.type == "publish" then return publish(self, c, p)
  elseif p.type == "puback" then c.inflight[p.id] = nil
  elseif p.type == "subscribe" then return subscribe(self, c, p)
  elseif p.type == "unsubscribe" then
    for _, f in ipairs(p.topics) do c.subs[f] = nil end
    send(c, { type = "unsuback", id = p.id })
  elseif p.type == "pingreq" then send(c, { type = "pingresp" })
  elseif p.type == "disconnect" then return self:close(c, true)
  else return self:close(c, false) end
end

--- Housekeeping: resend QoS 1 messages that were not acknowledged, drop silent clients. Call every few seconds.
function Broker:tick()
  local now = self.now()
  for _, c in pairs(self.clients) do
    if c.keepalive > 0 and now - c.lastSeen > c.keepalive * 1.5 then
      self.log("keepalive expired: " .. tostring(c.id))
      self:close(c, false)
    else
      for id, m in pairs(c.inflight) do
        if now - m.sent > M.RETRY_AFTER then
          if m.tries >= M.MAX_TRIES then c.inflight[id] = nil self.stats.dropped = self.stats.dropped + 1
          else
            m.tries, m.sent = m.tries + 1, now
            send(c, { type = "publish", topic = m.topic, payload = m.payload, qos = m.qos, id = id, dup = true })
          end
        end
      end
    end
  end
end

--- Broker statistics as topic/payload pairs ($SYS/...).
function Broker:sys()
  local retained = 0
  for _ in pairs(self.retained) do retained = retained + 1 end
  return {
    { "$SYS/broker/uptime", tostring(math.floor(self.now() - self.started)) },
    { "$SYS/broker/clients/connected", tostring(self.stats.connected) },
    { "$SYS/broker/messages/received", tostring(self.stats.received) },
    { "$SYS/broker/messages/sent", tostring(self.stats.sent) },
    { "$SYS/broker/messages/dropped", tostring(self.stats.dropped) },
    { "$SYS/broker/retained messages/count", tostring(retained) },
  }
end

--- The retained messages as a plain table (for saving to disk) and back.
function Broker:exportRetained()
  local out = {}
  for t, m in pairs(self.retained) do out[t] = { m.payload, m.qos } end
  return out
end

function Broker:importRetained(t)
  for topic, m in pairs(t or {}) do if type(m) == "table" and type(m[1]) == "string" then self:setRetained(topic, m[1], m[2] or 0) end end
end

M.Broker = Broker

return M
