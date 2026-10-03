-- SPDX-License-Identifier: AGPL-3.0-or-later
-- MQTT 3.1.1 packets (the publish/subscribe protocol of the Internet of Things), QoS 0 and 1.
-- Packets are tables:
--   { type = "connect", clientId, clean, keepalive, username, password, will = { topic, payload, qos, retain } }   { type = "connack", sessionPresent, code }
--   { type = "publish", topic, payload, qos, retain, dup, id }          { type = "puback", id }
--   { type = "subscribe", id, topics = { { filter, qos } } }            { type = "suback", id, codes = { 0, 1, 128 } }
--   { type = "unsubscribe", id, topics = { filter } }                   { type = "unsuback", id }
--   { type = "pingreq" } { type = "pingresp" } { type = "disconnect" }
-- encode(packet) -> bytes;  read(socket, timeout) -> packet (or nil + reason): reads one packet from a connection.
local M = {}

M.MAX_PACKET = 65536

local TYPES = { connect = 1, connack = 2, publish = 3, puback = 4, subscribe = 8, suback = 9, unsubscribe = 10, unsuback = 11, pingreq = 12, pingresp = 13, disconnect = 14 }
local NAMES = {}
for k, v in pairs(TYPES) do NAMES[v] = k end

M.CONNACK = { [0] = "accepted", [1] = "unacceptable protocol version", [2] = "identifier rejected", [3] = "server unavailable", [4] = "bad user name or password", [5] = "not authorized" }

local function u16(n) return string.char(math.floor(n / 256) % 256, n % 256) end
local function str(s) return u16(#s) .. s end

local function varlen(n)
  local out = {}
  repeat
    local d = n % 128
    n = math.floor(n / 128)
    if n > 0 then d = d + 128 end
    out[#out + 1] = string.char(d)
  until n == 0
  return table.concat(out)
end

local function frame(code, flags, body) return string.char(code * 16 + flags) .. varlen(#body) .. body end

function M.encode(p)
  local t = p.type
  if t == "connect" then
    local flags = 0
    if p.clean ~= false then flags = flags + 2 end
    if p.will then flags = flags + 4 + (p.will.qos or 0) * 8 + (p.will.retain and 32 or 0) end
    if p.password then flags = flags + 64 end
    if p.username then flags = flags + 128 end
    local body = str("MQTT") .. string.char(4, flags) .. u16(p.keepalive or 60) .. str(p.clientId or "")
    if p.will then body = body .. str(p.will.topic) .. str(p.will.payload or "") end
    if p.username then body = body .. str(p.username) end
    if p.password then body = body .. str(p.password) end
    return frame(1, 0, body)
  elseif t == "connack" then
    return frame(2, 0, string.char(p.sessionPresent and 1 or 0, p.code or 0))
  elseif t == "publish" then
    local qos = p.qos or 0
    local flags = (p.dup and 8 or 0) + qos * 2 + (p.retain and 1 or 0)
    local body = str(p.topic)
    if qos > 0 then body = body .. u16(p.id) end
    return frame(3, flags, body .. (p.payload or ""))
  elseif t == "puback" then return frame(4, 0, u16(p.id))
  elseif t == "subscribe" then
    local body = u16(p.id)
    for _, s in ipairs(p.topics) do body = body .. str(s.filter) .. string.char(s.qos or 0) end
    return frame(8, 2, body)
  elseif t == "suback" then return frame(9, 0, u16(p.id) .. string.char(table.unpack(p.codes)))
  elseif t == "unsubscribe" then
    local body = u16(p.id)
    for _, f in ipairs(p.topics) do body = body .. str(f) end
    return frame(10, 2, body)
  elseif t == "unsuback" then return frame(11, 0, u16(p.id))
  elseif t == "pingreq" then return frame(12, 0, "")
  elseif t == "pingresp" then return frame(13, 0, "")
  elseif t == "disconnect" then return frame(14, 0, "")
  end
  error("cannot encode a " .. tostring(t) .. " packet")
end

local function rd16(s, i) local a, b = s:byte(i, i + 1) if not b then return nil end return a * 256 + b end

local function rdstr(s, i)
  local n = rd16(s, i)
  if not n or i + 2 + n - 1 > #s then return nil end
  return s:sub(i + 2, i + 1 + n), i + 2 + n
end

--- Turn the bytes after the fixed header into a packet. Returns the packet or nil + reason (a protocol violation).
function M.decode(code, flags, body)
  local t = NAMES[code]
  if not t then return nil, "unknown packet type " .. code end
  if t == "connect" then
    local proto, i = rdstr(body, 1)
    if proto ~= "MQTT" and proto ~= "MQIsdp" then return nil, "not an MQTT connection" end
    local level, cf = body:byte(i, i + 1)
    if not cf then return nil, "short connect" end
    local ka = rd16(body, i + 2)
    if not ka then return nil, "short connect" end
    local p = { type = "connect", level = level, clean = cf % 4 >= 2, keepalive = ka }
    local id
    id, i = rdstr(body, i + 4)
    if not id then return nil, "short connect" end
    p.clientId = id
    if cf % 8 >= 4 then
      local topic, payload
      topic, i = rdstr(body, i)
      if not topic then return nil, "short will" end
      payload, i = rdstr(body, i)
      if not payload then return nil, "short will" end
      p.will = { topic = topic, payload = payload, qos = math.floor(cf / 8) % 4, retain = math.floor(cf / 32) % 2 == 1 }
    end
    if cf >= 128 then
      p.username, i = rdstr(body, i)
      if not p.username then return nil, "short user name" end
    end
    if math.floor(cf / 64) % 2 == 1 then
      p.password, i = rdstr(body, i)
      if not p.password then return nil, "short password" end
    end
    return p
  elseif t == "connack" then
    if #body < 2 then return nil, "short connack" end
    return { type = t, sessionPresent = body:byte(1) % 2 == 1, code = body:byte(2) }
  elseif t == "publish" then
    local topic, i = rdstr(body, 1)
    if not topic then return nil, "short publish" end
    local qos = math.floor(flags / 2) % 4
    if qos > 2 then return nil, "bad QoS" end
    local p = { type = t, topic = topic, qos = qos, retain = flags % 2 == 1, dup = math.floor(flags / 8) % 2 == 1 }
    if qos > 0 then
      p.id = rd16(body, i)
      if not p.id then return nil, "short publish" end
      i = i + 2
    end
    p.payload = body:sub(i)
    return p
  elseif t == "puback" or t == "unsuback" then
    local id = rd16(body, 1)
    if not id then return nil, "short " .. t end
    return { type = t, id = id }
  elseif t == "subscribe" then
    local id = rd16(body, 1)
    if not id then return nil, "short subscribe" end
    local p, i = { type = t, id = id, topics = {} }, 3
    while i <= #body do
      local filter
      filter, i = rdstr(body, i)
      if not filter or not body:byte(i) then return nil, "bad subscribe" end
      p.topics[#p.topics + 1] = { filter = filter, qos = body:byte(i) % 4 }
      i = i + 1
    end
    if #p.topics == 0 then return nil, "empty subscribe" end
    return p
  elseif t == "suback" then
    local id = rd16(body, 1)
    if not id then return nil, "short suback" end
    return { type = t, id = id, codes = { body:byte(3, -1) } }
  elseif t == "unsubscribe" then
    local id = rd16(body, 1)
    if not id then return nil, "short unsubscribe" end
    local p, i = { type = t, id = id, topics = {} }, 3
    while i <= #body do
      local filter
      filter, i = rdstr(body, i)
      if not filter then return nil, "bad unsubscribe" end
      p.topics[#p.topics + 1] = filter
    end
    return p
  end
  return { type = t }
end

--- Read one packet from a socket. Returns the packet, or nil + reason ("timeout", "closed", or a protocol error text).
function M.read(sock, timeout)
  local first, err = sock:receive(1, timeout)
  if not first then return nil, err or "closed" end
  local byte = first:byte()
  local len, mult = 0, 1
  for _ = 1, 4 do
    local b, e = sock:receive(1, timeout or 20)
    if not b then return nil, e or "closed" end
    local v = b:byte()
    len = len + (v % 128) * mult
    if v < 128 then mult = nil break end
    mult = mult * 128
  end
  if mult then return nil, "bad packet length" end
  if len > M.MAX_PACKET then return nil, "packet too large" end
  local body = ""
  if len > 0 then
    body, err = sock:receive(len, timeout or 20)
    if not body then return nil, err or "closed" end
  end
  return M.decode(math.floor(byte / 16), byte % 16, body)
end

return M
