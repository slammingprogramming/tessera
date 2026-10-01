-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Tessera networking. A Node is one computer's presence on the network: it owns a transport (rednet by default), a hostname,
-- a database of paired peers and a table of services it offers.
--
--   local net = require("tsr.net")
--   local node = net.default()                 -- opens the modems, uses the computer's id and hostname
--   node:serve("echo", function(from, method, args) return args end)
--   node:run()                                 -- (daemon) answer discovery, pings, pairing and calls
--
--   node:lookup("echo")                        -- who offers it?            -> { {id=, host=, services=} ... }
--   node:ping(id)                              -- round trip in seconds     -> number | nil
--   node:pairListen{ code = "..." } / node:pairConnect(id, code)
--   node:call("peername", "echo", "say", {1,2})  -- authenticated call to a paired peer
--
-- Security model: pairing exchanges a random 256-bit key protected by a one-time code that is typed on both computers.
-- Calls carry HMAC-SHA256 over (sender, receiver, counter, payload) so they cannot be forged or replayed; with
-- opts.encrypt they are also encrypted. Discovery, ping and time are unauthenticated by design (they reveal only the
-- hostname and service names). Nothing here can protect against someone who controls a computer or its modem hardware.
local hash = require("tsr.hash")
local vfs = require("tsr.vfs")
local crypto = require("tsr.net.crypto")
local log = require("tsr.log").get("net")

local M = {}
M.crypto = crypto

M.PROTOCOL = "tsr.net"
M.FRESH_MS = 120000        -- calls older than this are rejected (replay window)
M.CACHE_SECONDS = 120

local Node = {}
Node.__index = Node
M.Node = Node

---------------------------------------------------------------------------------------------------------------------
-- Transports. A transport is { send(id, msg), broadcast(msg), receive(timeout) -> id, msg }.
---------------------------------------------------------------------------------------------------------------------

--- The default transport: rednet with every attached modem opened.
function M.rednetTransport()
  local opened = false
  local t = {}
  local function open()
    if opened then return end
    for _, name in ipairs(peripheral.getNames()) do
      if peripheral.getType(name) == "modem" and not rednet.isOpen(name) then pcall(rednet.open, name) end
    end
    opened = true
  end
  function t.available()
    for _, name in ipairs(peripheral.getNames()) do
      if peripheral.getType(name) == "modem" then return true end
    end
    return false
  end
  function t.send(id, msg) open() rednet.send(id, msg, M.PROTOCOL) end
  function t.broadcast(msg) open() rednet.broadcast(msg, M.PROTOCOL) end
  function t.receive(timeout)
    open()
    local id, msg = rednet.receive(M.PROTOCOL, timeout)
    return id, msg
  end
  return t
end

---------------------------------------------------------------------------------------------------------------------
-- Nodes
---------------------------------------------------------------------------------------------------------------------

--- Create a node. opts: id, hostname, transport, peersPath (default /etc/tsr/net/peers.db).
function M.node(opts)
  opts = opts or {}
  local self = setmetatable({
    id = opts.id or os.getComputerID(),
    hostname = opts.hostname,
    transport = opts.transport or M.rednetTransport(),
    peersPath = opts.peersPath or "/etc/tsr/net/peers.db",
    services = {},
    handlers = {},
    pairing = nil,
    lastSent = 0,
    lastSeen = {},
    cache = {},
  }, Node)
  if not self.hostname then
    local okTsr, tsr = pcall(function() return rawget(_G, "tsr") end)
    self.hostname = (okTsr and tsr and tsr.hostname and tsr.hostname()) or os.getComputerLabel() or ("cc-" .. self.id)
  end
  self.handlers = {
    ping = Node.onPing, ["disco.q"] = Node.onDiscoQuery, ["time.q"] = Node.onTimeQuery,
    rpc = Node.onRpc, ["pair.1"] = Node.onPair1, ["pair.3"] = Node.onPair3,
  }
  return self
end

local defaultNode
function M.default()
  if not defaultNode then defaultNode = M.node() end
  return defaultNode
end
function M.setDefault(node) defaultNode = node end

function Node:send(id, msg) self.transport.send(id, msg) end
function Node:broadcast(msg) self.transport.broadcast(msg) end
function Node:receive(timeout) return self.transport.receive(timeout) end

--- Wait for a message from `from` (nil = anyone) accepted by `want(msg)`; returns the message or nil on timeout.
function Node:await(from, want, timeout)
  local deadline = os.clock() + timeout
  while true do
    local remaining = deadline - os.clock()
    if remaining <= 0 then return nil end
    local id, msg = self:receive(remaining)
    if id == nil then return nil end
    if (from == nil or id == from) and type(msg) == "table" and want(msg, id) then return msg, id end
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Peers
---------------------------------------------------------------------------------------------------------------------

function Node:loadPeers()
  if not self.peerDb then
    self.peerDb = vfs.readTable(self.peersPath) or { peers = {} }
    self.peerDb.peers = self.peerDb.peers or {}
  end
  return self.peerDb
end

function Node:savePeers()
  return vfs.writeTable(self.peersPath, self.peerDb)
end

--- Peer record by id or name, or nil. { id, name, key, added }
function Node:peer(idOrName)
  local db = self:loadPeers()
  if type(idOrName) == "number" then return db.peers[tostring(idOrName)] end
  for _, p in pairs(db.peers) do
    if p.name == idOrName then return p end
  end
  local n = tonumber(idOrName)
  if n then return db.peers[tostring(n)] end
end

function Node:peers()
  local out = {}
  for _, p in pairs(self:loadPeers().peers) do out[#out + 1] = { id = p.id, name = p.name, added = p.added } end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

function Node:addPeer(id, name, key)
  local db = self:loadPeers()
  db.peers[tostring(id)] = { id = id, name = name, key = key, added = os.epoch and os.epoch("utc") or 0 }
  return self:savePeers()
end

function Node:removePeer(idOrName)
  local p = self:peer(idOrName)
  if not p then return nil, "not paired with " .. tostring(idOrName) end
  self:loadPeers().peers[tostring(p.id)] = nil
  return self:savePeers()
end

---------------------------------------------------------------------------------------------------------------------
-- Discovery, ping, time (unauthenticated)
---------------------------------------------------------------------------------------------------------------------

function Node:serviceNames()
  local names = {}
  for name in pairs(self.services) do names[#names + 1] = name end
  table.sort(names)
  return names
end

function Node:onPing(from, msg)
  self:send(from, { t = "ping.r", n = msg.n, host = self.hostname })
end

function Node:onDiscoQuery(from, msg)
  if msg.svc and not self.services[msg.svc] then return end
  if msg.host and msg.host ~= self.hostname then return end
  self:send(from, { t = "disco.r", host = self.hostname, services = self:serviceNames(), q = msg.q })
end

function Node:onTimeQuery(from, msg)
  self:send(from, {
    t = "time.r", q = msg.q, utc = os.epoch and os.epoch("utc") or 0, ingame = os.epoch and os.epoch("ingame") or 0,
  })
end

--- Computers (answering within `timeout` seconds) that offer `service`, or that are called `host`. Returns a list of
--- { id, host, services }. With neither argument: everybody who answers.
function Node:lookup(service, timeout, host)
  local q = crypto.randomHex(4)
  self:broadcast({ t = "disco.q", svc = service, host = host, q = q })
  local found, seen = {}, {}
  local deadline = os.clock() + (timeout or 1)
  while true do
    local remaining = deadline - os.clock()
    if remaining <= 0 then break end
    local id, msg = self:receive(remaining)
    if id == nil then break end
    if type(msg) == "table" and msg.t == "disco.r" and msg.q == q and not seen[id] then
      seen[id] = true
      found[#found + 1] = { id = id, host = msg.host, services = msg.services or {} }
      self.cache[msg.host] = { id = id, at = os.clock() }
    end
  end
  table.sort(found, function(a, b) return a.id < b.id end)
  return found
end

--- Turn a peer name, hostname or number into a computer id.
function Node:resolve(target, timeout)
  if type(target) == "number" then return target end
  local p = self:peer(target)
  if p then return p.id end
  local cached = self.cache[target]
  if cached and os.clock() - cached.at < M.CACHE_SECONDS then return cached.id end
  if tonumber(target) then return tonumber(target) end
  local found = self:lookup(nil, timeout or 1, target)
  if found[1] then return found[1].id end
  return nil, "cannot find a computer called " .. tostring(target)
end

--- Round-trip time in seconds, or nil.
function Node:ping(target, timeout)
  local id, err = self:resolve(target, timeout)
  if not id then return nil, err end
  local n = crypto.randomHex(4)
  local start = os.clock()
  self:send(id, { t = "ping", n = n })
  local reply = self:await(id, function(m) return m.t == "ping.r" and m.n == n end, timeout or 2)
  if not reply then return nil, "no answer from " .. tostring(target) end
  return os.clock() - start, reply.host
end

--- Ask another computer for its clocks. Returns { utc, ingame, rtt, offset } where offset = theirs - ours (ms, utc clock).
function Node:time(target, timeout)
  local id, err = self:resolve(target, timeout)
  if not id then return nil, err end
  local q = crypto.randomHex(4)
  local start = os.clock()
  self:send(id, { t = "time.q", q = q })
  local reply = self:await(id, function(m) return m.t == "time.r" and m.q == q end, timeout or 2)
  if not reply then return nil, "no answer from " .. tostring(target) end
  local rtt = os.clock() - start
  local ours = os.epoch and os.epoch("utc") or 0
  return { utc = reply.utc, ingame = reply.ingame, rtt = rtt, offset = reply.utc + rtt * 500 - ours }
end

---------------------------------------------------------------------------------------------------------------------
-- Pairing
---------------------------------------------------------------------------------------------------------------------

--- Wait for another computer to pair using a one-time code. opts: code (default: a fresh one), timeout (seconds, default 120),
--- onCode(code) called as soon as the code is known (to display it), attempts (wrong codes tolerated, default 3).
--- Returns the peer ({ id, name }) or nil + reason.
function Node:pairListen(opts)
  opts = opts or {}
  local code = crypto.cleanCode(opts.code or crypto.pairingCode())
  local timeout = opts.timeout or 120
  self.pairing = {
    code = code, expires = os.clock() + timeout, failures = 0, maxFailures = opts.attempts or 3, result = nil,
  }
  if opts.onCode then opts.onCode(code:sub(1, 5) .. "-" .. code:sub(6)) end
  local p = self.pairing
  while os.clock() < p.expires and not p.result and p.failures < p.maxFailures do
    local id, msg = self:receive(math.min(1, p.expires - os.clock()))
    if id and type(msg) == "table" and self.handlers[msg.t] then
      local ok, err = pcall(self.handlers[msg.t], self, id, msg)
      if not ok then log.warn("pairing message failed: %s", tostring(err)) end
    end
  end
  self.pairing = nil
  if p.result then return p.result end
  if p.failures >= p.maxFailures then return nil, "too many wrong codes" end
  return nil, "timed out"
end

--- First message of pairing (we are the listener).
function Node:onPair1(from, msg)
  local p = self.pairing
  if not p or os.clock() > p.expires then return end
  if type(msg.nonce) ~= "string" or type(msg.name) ~= "string" or #msg.nonce > 64 then return end
  if p.pending and p.pending.nonceB == msg.nonce then return end      -- already being handled (the daemon sees it too)
  if not crypto.equal(msg.proof or "", crypto.mac(p.code, "B|" .. msg.nonce .. "|" .. msg.name)) then
    p.failures = p.failures + 1
    return                                   -- wrong code: stay silent so a guesser learns nothing
  end
  local key = crypto.randomHex(32)
  local nonceA = crypto.randomHex(16)
  local mask = crypto.stream(p.code, nonceA .. msg.nonce, 32)
  local keyBytes = hash.fromHex(key)
  local enc = {}
  for i = 1, 32 do enc[i] = string.char(bit32.bxor(keyBytes:byte(i), mask:byte(i))) end
  p.pending = { from = from, name = msg.name, key = key, nonceA = nonceA, nonceB = msg.nonce }
  self:send(from, {
    t = "pair.2", name = self.hostname, nonce = nonceA, enc = hash.toHex(table.concat(enc)),
    proof = crypto.mac(p.code, "A|" .. nonceA .. "|" .. msg.nonce .. "|" .. key),
  })
end

--- Last message of pairing (we are the listener): the other side confirms it got the key.
function Node:onPair3(from, msg)
  local p = self.pairing
  if not p or not p.pending or p.pending.from ~= from or p.result then return end
  local pend = p.pending
  if not crypto.equal(msg.proof or "", crypto.mac(pend.key, "done|" .. pend.nonceA .. "|" .. pend.nonceB)) then
    p.failures = p.failures + 1
    return
  end
  self:addPeer(from, pend.name, pend.key)
  p.result = { id = from, name = pend.name }
  log.info("paired with %s (%d)", pend.name, from)
end

--- Pair with the computer `id` that is listening with `code`. Returns the peer ({ id, name }) or nil + reason.
function Node:pairConnect(id, code, timeout)
  code = crypto.cleanCode(code)
  if #code ~= 10 then return nil, "the code must have 10 characters" end
  local nonceB = crypto.randomHex(16)
  self:send(id, { t = "pair.1", name = self.hostname, nonce = nonceB, proof = crypto.mac(code, "B|" .. nonceB .. "|" .. self.hostname) })
  local reply = self:await(id, function(m) return m.t == "pair.2" end, timeout or 5)
  if not reply then return nil, "no answer (wrong id, out of range, not listening, or wrong code)" end
  if type(reply.nonce) ~= "string" or type(reply.enc) ~= "string" or #reply.enc ~= 64 then return nil, "malformed reply" end
  local mask = crypto.stream(code, reply.nonce .. nonceB, 32)
  local encBytes = hash.fromHex(reply.enc)
  local keyBytes = {}
  for i = 1, 32 do keyBytes[i] = string.char(bit32.bxor(encBytes:byte(i), mask:byte(i))) end
  local key = hash.toHex(table.concat(keyBytes))
  if not crypto.equal(reply.proof or "", crypto.mac(code, "A|" .. reply.nonce .. "|" .. nonceB .. "|" .. key)) then
    return nil, "the other computer did not prove it knows the code"
  end
  self:addPeer(id, tostring(reply.name or id), key)
  self:send(id, { t = "pair.3", proof = crypto.mac(key, "done|" .. reply.nonce .. "|" .. nonceB) })
  return { id = id, name = reply.name }
end

---------------------------------------------------------------------------------------------------------------------
-- Authenticated calls
---------------------------------------------------------------------------------------------------------------------

local function canon(from, to, n, enc, payload)
  return table.concat({ tostring(from), tostring(to), string.format("%.0f", n), enc and "1" or "0", payload }, "|")
end

local function nextCounter(self)
  local now = os.epoch and os.epoch("utc") or 0
  self.lastSent = math.max(self.lastSent + 1, now)
  return self.lastSent
end

local function seal(key, from, to, n, body, encrypt)
  local payload = textutils.serialize(body)
  if encrypt then payload = crypto.encrypt(key, string.format("%.0f", n), payload) end
  return payload, crypto.mac(key, canon(from, to, n, encrypt, payload))
end

local function open(key, from, to, n, enc, payload, mac)
  if not crypto.equal(mac or "", crypto.mac(key, canon(from, to, n, enc, payload or ""))) then return nil end
  if enc then payload = crypto.decrypt(key, string.format("%.0f", n), payload) end
  if type(payload) ~= "string" then return nil end
  local body = textutils.unserialize(payload)
  if type(body) ~= "table" then return nil end
  return body
end

--- Offer a service. handler(from, method, args) returns results; errors become error replies. opts.allow(peer) -> bool restricts
--- which paired peers may call it (default: all paired peers). opts.async runs each call in its own process when the kernel is up.
function Node:serve(name, handler, opts)
  self.services[name] = { handler = handler, allow = opts and opts.allow, async = opts and opts.async }
end

function Node:unserve(name) self.services[name] = nil end

--- Call `service.method(args)` on a paired computer. opts: timeout (seconds), encrypt (bool). Returns the result, or nil + error.
function Node:call(target, service, method, args, opts)
  opts = opts or {}
  local peer = self:peer(target)
  if not peer then return nil, "not paired with " .. tostring(target) end
  local n = nextCounter(self)
  local payload, mac = seal(peer.key, self.id, peer.id, n, { s = service, m = method, a = args }, opts.encrypt)
  self:send(peer.id, { t = "rpc", from = self.id, n = n, enc = opts.encrypt and true or false, p = payload, mac = mac })
  local reply = self:await(peer.id, function(m) return m.t == "rpc.r" and m.n == n end, opts.timeout or 5)
  if not reply then return nil, "no answer from " .. tostring(peer.name) end
  local body = open(peer.key, peer.id, self.id, n, reply.enc, reply.p, reply.mac)
  if not body then return nil, "bad signature on the reply" end
  if body.ok then return body.result end
  return nil, tostring(body.err or "call failed")
end

function Node:onRpc(from, msg)
  local peer = self:peer(from)
  if not peer or msg.from ~= from or type(msg.n) ~= "number" then return end
  local now = os.epoch and os.epoch("utc") or 0
  local body = open(peer.key, from, self.id, msg.n, msg.enc and true or false, msg.p, msg.mac)
  if not body then return end
  -- replay protection: the counter must grow and not be ancient
  if msg.n <= (self.lastSeen[from] or -1) then return end
  if now > 0 and now - msg.n > M.FRESH_MS then return end
  self.lastSeen[from] = msg.n
  local svc = self.services[body.s]
  local function respond()
    local reply = { ok = false, err = "no such service: " .. tostring(body.s) }
    if svc and svc.allow and not svc.allow(peer) then
      reply = { ok = false, err = "not allowed" }
    elseif svc then
      local ok, res = pcall(svc.handler, from, body.m, body.a)
      if ok then reply = { ok = true, result = res } else reply = { ok = false, err = tostring(res) } end
    end
    local payload, mac = seal(peer.key, self.id, from, msg.n, reply, msg.enc and true or false)
    self:send(from, { t = "rpc.r", n = msg.n, enc = msg.enc and true or false, p = payload, mac = mac })
  end
  -- slow services (opts.async) get their own process so the daemon keeps answering others
  if svc and svc.async then
    local okK, kernel = pcall(require, "tsr.kernel")
    if okK and kernel.isRunning and kernel.isRunning() then
      kernel.spawn({ name = "rpc:" .. tostring(body.s), window = false, daemon = true, fn = respond })
      return
    end
  end
  respond()
end

---------------------------------------------------------------------------------------------------------------------
-- Daemon loop
---------------------------------------------------------------------------------------------------------------------

--- Answer everything addressed to this node. Never returns. Handlers run inline, so a slow service delays others: services
--- that take long should spawn their own process.
function Node:run()
  while true do
    local id, msg = self:receive()
    if id ~= nil and type(msg) == "table" and type(msg.t) == "string" then
      local h = self.handlers[msg.t]
      if h then
        local ok, err = pcall(h, self, id, msg)
        if not ok then log.warn("handler %s failed: %s", msg.t, tostring(err)) end
      end
    end
  end
end

return M
