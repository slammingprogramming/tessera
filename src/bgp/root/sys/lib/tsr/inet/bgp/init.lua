-- SPDX-License-Identifier: AGPL-3.0-or-later
-- A BGP-4 speaker (RFC 4271) for connecting networks that different players run into one internet: every network is an Autonomous System (AS) with a
-- number; neighbouring ASes exchange the prefixes they can reach, and each router picks the best path (customer routes before peer routes before
-- provider routes, then the shortest AS path). A session is a TCP connection to port 179 between two routers.
--
-- Peering agreements are first-class: each neighbour has a `relationship` that sets the policy in the way real networks do it (Gao-Rexford):
--   customer  pays us for transit: we prefer their routes (local-pref 200) and give them everything we know
--   peer      swaps traffic for free (100): we give them our own and our customers' routes, nothing else
--   provider  we pay them (50): we give them our own and our customers' routes, and learn the rest of the internet from them
-- Beyond that: prefix filters in both directions, a limit on the number of prefixes, AS-path prepending, communities (NO_EXPORT), route origin
-- validation against ROAs (a signed statement of which AS may announce a prefix, "RPKI" in the real world; here a list you keep), a shared secret.
--
--   cfg = { as = 65001, routerId = "10.0.0.1", networks = { "10.1.0.0/16" },
--           peers = { { ip = "192.0.2.2", as = 65002, relationship = "peer", maxPrefixes = 100,
--                       import = { allow = { { prefix = "10.2.0.0/16", le = 24 } } }, export = { prepend = 1 }, password = "secret" } } }
local B = require("tsr.inet.bytes")
local socket = require("tsr.inet.socket")
local W = require("tsr.inet.bgp.wire")

local M = {}
local Speaker = {}
Speaker.__index = Speaker

M.PORT = 179
M.PREF = { customer = 200, peer = 100, provider = 50 }
M.DISTANCE = { ebgp = 20, ibgp = 200 }

local function pkey(net, plen) return net .. "/" .. plen end

---------------------------------------------------------------------------------------------------------------------
-- Creation
---------------------------------------------------------------------------------------------------------------------

local function parsePrefixList(list)
  if not list then return nil end
  local out = {}
  for _, e in ipairs(list) do
    local net, plen = B.cidr(e.prefix or e)
    if net then out[#out + 1] = { net = net, plen = plen, ge = e.ge or plen, le = e.le or e.ge and 32 or plen } end
  end
  return out
end

local function listMatches(list, net, plen)
  for _, e in ipairs(list) do
    if plen >= e.ge and plen <= e.le and plen >= e.plen and B.inNet(net, e.net, e.plen) then return true end
  end
  return false
end

--- cfg: as, routerId, networks (prefixes originated here), holdTime (90), keepalive (hold / 3), connectRetry (10), mrai (1), peers, roas, rov ("reject" | "warn" | "off").
function M.new(stack, cfg)
  assert(cfg.as and cfg.as >= 1 and cfg.as <= 65535, "an AS number between 1 and 65535 is needed (64512-65534 are private)")
  local self = setmetatable({
    stack = stack, cfg = cfg, as = cfg.as, holdTime = cfg.holdTime or 90, connectRetry = cfg.connectRetry or 10, mrai = cfg.mrai or 1,
    peers = {}, peerList = {}, rib = {}, localRoutes = {}, installed = {}, dirty = false, stats = { updatesIn = 0, updatesOut = 0, rejected = 0, hijacks = 0 },
    log = {}, roas = {}, rov = cfg.rov or "reject",
  }, Speaker)
  self.keepalive = cfg.keepalive or math.max(1, math.floor(self.holdTime / 3))
  local rid = cfg.routerId and B.ip(cfg.routerId)
  if not rid then
    for _, i in ipairs(stack.ifaceList) do
      for _, a in ipairs(i.addrs) do if i.kind ~= "loopback" and (not rid or a.ip > rid) then rid = a.ip end end
    end
  end
  self.routerId = rid or 1
  for _, n in ipairs(cfg.networks or {}) do
    local net, plen = B.cidr(n)
    if net then
      self.localRoutes[pkey(net, plen)] = { net = net, plen = plen, origin = W.ORIGIN_IGP, asPath = {}, nextHop = 0, localPref = 1000, communities = {}, local_ = true, routerId = self.routerId, since = stack.clock() }
    end
  end
  for _, r in ipairs(cfg.roas or {}) do
    local net, plen = B.cidr(r.prefix)
    if net then self.roas[#self.roas + 1] = { net = net, plen = plen, maxLen = r.maxLen or plen, as = r.as } end
  end
  for _, p in ipairs(cfg.peers or {}) do self:addPeer(p) end
  return self
end

function Speaker:note(text)
  self.log[#self.log + 1] = ("%.1f %s"):format(self.stack.clock(), text)
  if #self.log > 100 then table.remove(self.log, 1) end
  if self.stack.logger then self.stack.logger("bgp: " .. text) end
end

function Speaker:addPeer(p)
  local ip = B.ip(p.ip)
  assert(ip and p.as, "a peer needs an ip and an as")
  local ebgp = p.as ~= self.as
  local rel = p.relationship or (ebgp and "peer" or "internal")
  if not ebgp then rel = "internal" end
  assert(rel == "customer" or rel == "peer" or rel == "provider" or rel == "internal", "relationship is customer, peer or provider")
  local peer = {
    ip = ip, as = p.as, ebgp = ebgp, rel = rel, description = p.description, state = "Idle", adjIn = {}, adjOut = {}, outq = {}, cfg = p,
    importAllow = parsePrefixList(p.import and p.import.allow), importDeny = parsePrefixList(p.import and p.import.deny),
    exportAllow = parsePrefixList(p.export and p.export.allow), exportDeny = parsePrefixList(p.export and p.export.deny),
    prepend = p.export and p.export.prepend or 0, exportCommunities = p.export and p.export.communities, maxPrefixes = p.maxPrefixes,
    password = p.password, stats = { received = 0, sent = 0, accepted = 0, filtered = 0 }, mode = p.mode, nextHopSelf = p.nextHopSelf ~= false,
  }
  self.peers[ip] = peer
  self.peerList[#self.peerList + 1] = peer
  return peer
end

---------------------------------------------------------------------------------------------------------------------
-- Policy
---------------------------------------------------------------------------------------------------------------------

--- Route origin validation: "valid", "invalid" or "unknown" for prefix/origin AS.
function Speaker:validate(net, plen, originAs)
  local covered = false
  for _, r in ipairs(self.roas) do
    if plen >= r.plen and B.inNet(net, r.net, r.plen) then
      covered = true
      if r.as == originAs and plen <= r.maxLen then return "valid" end
    end
  end
  return covered and "invalid" or "unknown"
end

--- Decide about a route received from `peer`; returns the stored route or nil + reason.
function Speaker:importRoute(peer, prefix, attrs)
  for _, asn in ipairs(attrs.asPath) do if asn == self.as then return nil, "AS path loop" end end
  if prefix.plen == 0 and not (peer.cfg.import and peer.cfg.import.acceptDefault) then return nil, "default route not accepted" end
  if peer.importDeny and listMatches(peer.importDeny, prefix.net, prefix.plen) then return nil, "denied by import filter" end
  if peer.importAllow and not listMatches(peer.importAllow, prefix.net, prefix.plen) then return nil, "not in the import allow list" end
  if peer.ebgp and self.rov ~= "off" and #self.roas > 0 then
    local origin = attrs.asPath[#attrs.asPath] or peer.as
    local v = self:validate(prefix.net, prefix.plen, origin)
    if v == "invalid" then
      self.stats.hijacks = self.stats.hijacks + 1
      if self.rov == "reject" then return nil, "origin validation failed (AS" .. origin .. " may not announce this prefix)" end
    end
  end
  local lp
  if peer.ebgp then lp = (peer.cfg.import and peer.cfg.import.localPref) or M.PREF[peer.rel] or 100 else lp = attrs.localPref or 100 end
  return {
    net = prefix.net, plen = prefix.plen, origin = attrs.origin or 0, asPath = attrs.asPath, nextHop = attrs.nextHop, med = attrs.med, localPref = lp,
    communities = attrs.communities or {}, peer = peer, ebgp = peer.ebgp, routerId = peer.routerId or peer.ip, since = self.stack.clock(),
  }
end

local function better(a, b)
  if a.localPref ~= b.localPref then return a.localPref > b.localPref end
  if #a.asPath ~= #b.asPath then return #a.asPath < #b.asPath end
  if a.origin ~= b.origin then return a.origin < b.origin end
  local an, bn = a.asPath[1], b.asPath[1]
  if an == bn and (a.med or 0) ~= (b.med or 0) then return (a.med or 0) < (b.med or 0) end
  if (a.ebgp and true or false) ~= (b.ebgp and true or false) then return a.ebgp and true or false end
  if a.routerId ~= b.routerId then return a.routerId < b.routerId end
  return (a.peer and a.peer.ip or 0) < (b.peer and b.peer.ip or 0)
end

--- Pick the best route of a prefix among the local one and what the established neighbours told us.
function Speaker:recompute(key)
  local best = self.localRoutes[key]
  if not best then
    for _, peer in ipairs(self.peerList) do
      local r = peer.state == "Established" and peer.adjIn[key]
      if r and (not best or better(r, best)) then best = r end
    end
  end
  local old = self.rib[key]
  if old ~= best then
    self.rib[key] = best
    self.dirty = true
    self:syncStack(key, best)
  end
end

--- Make the route known to the IP stack (the forwarding table).
function Speaker:syncStack(key, best)
  local stack = self.stack
  local old = self.installed[key]
  if old then
    stack:removeRoutes(function(r) return r.proto == "bgp" and r.net == old.net and r.plen == old.plen end)
    self.installed[key] = nil
  end
  if not best or best.local_ then return end
  -- resolve the next hop: on-link, or through another route (recursive, for iBGP)
  local nh = best.nextHop
  local gateway, iface
  local r = stack:lookup(nh)
  if r and r.proto ~= "bgp" then
    if r.gateway then gateway, iface = r.gateway, r.iface else gateway, iface = nh, r.iface end
  else
    return
  end
  local added = stack:addRoute(B.cidrStr(best.net, best.plen), gateway, { iface = iface, proto = "bgp", metric = (best.ebgp and M.DISTANCE.ebgp or M.DISTANCE.ibgp) + #best.asPath })
  if added then self.installed[key] = { net = best.net, plen = best.plen } end
end

--- What we would tell `peer` about `route`: the attributes to send, or nil when policy says no.
function Speaker:exportAttrs(peer, route)
  -- Gao-Rexford: peers and providers only hear our own routes and our customers' routes
  local from = route.local_ and "local" or route.peer.rel
  if peer.rel == "peer" or peer.rel == "provider" then
    if from ~= "local" and from ~= "customer" then return nil end
  end
  if route.peer == peer then return nil end
  -- iBGP does not re-advertise routes learned from iBGP
  if not peer.ebgp and route.peer and not route.peer.ebgp then return nil end
  if peer.ebgp then for _, c in ipairs(route.communities) do if c == W.NO_EXPORT then return nil end end end
  if peer.exportDeny and listMatches(peer.exportDeny, route.net, route.plen) then return nil end
  if peer.exportAllow and not listMatches(peer.exportAllow, route.net, route.plen) then return nil end
  local path = {}
  local attrs = { origin = route.origin, communities = {} }
  for _, c in ipairs(route.communities) do attrs.communities[#attrs.communities + 1] = c end
  if peer.ebgp then
    path[1] = self.as
    for _ = 1, peer.prepend do path[#path + 1] = self.as end
    for _, a in ipairs(route.asPath) do path[#path + 1] = a end
    attrs.nextHop = peer.localAddress or self:localAddressFor(peer)
    attrs.med = peer.cfg.export and peer.cfg.export.med or nil
  else
    for _, a in ipairs(route.asPath) do path[#path + 1] = a end
    attrs.localPref = route.localPref
    attrs.nextHop = (peer.nextHopSelf or route.local_) and (peer.localAddress or self:localAddressFor(peer)) or route.nextHop
    attrs.med = route.med
  end
  attrs.asPath = path
  for _, c in ipairs(peer.exportCommunities or {}) do
    local v = type(c) == "number" and c or W.community(c)
    if v then attrs.communities[#attrs.communities + 1] = v end
  end
  return attrs
end

function Speaker:localAddressFor(peer)
  if peer.conn and peer.conn.tcb then return peer.conn.tcb.laddr end
  local r = self.stack:lookup(peer.ip)
  if r then return self.stack:sourceFor(r, peer.ip) end
  return self.routerId
end

---------------------------------------------------------------------------------------------------------------------
-- Sending updates
---------------------------------------------------------------------------------------------------------------------

local function attrSignature(a)
  return table.concat(a.asPath, ",") .. "|" .. a.nextHop .. "|" .. (a.origin or 0) .. "|" .. (a.med or "") .. "|" .. (a.localPref or "") .. "|" .. table.concat(a.communities or {}, ",")
end

--- Bring `peer` up to date: withdraw what is gone, announce what is new or changed.
function Speaker:advertise(peer)
  if peer.state ~= "Established" then return end
  local wanted = {}
  for key, route in pairs(self.rib) do
    local a = self:exportAttrs(peer, route)
    if a then wanted[key] = { attrs = a, sig = attrSignature(a), net = route.net, plen = route.plen } end
  end
  local withdrawn = {}
  for key, old in pairs(peer.adjOut) do
    if not wanted[key] then withdrawn[#withdrawn + 1] = { net = old.net, plen = old.plen } peer.adjOut[key] = nil end
  end
  -- group announcements that share attributes into one UPDATE each
  local groups, order = {}, {}
  for key, w in pairs(wanted) do
    local cur = peer.adjOut[key]
    if not cur or cur.sig ~= w.sig then
      local g = groups[w.sig]
      if not g then g = { attrs = w.attrs, nlri = {} } groups[w.sig] = g order[#order + 1] = w.sig end
      g.nlri[#g.nlri + 1] = { net = w.net, plen = w.plen }
      peer.adjOut[key] = w
    end
  end
  if #withdrawn > 0 then
    for i = 1, #withdrawn, 100 do
      local chunk = {}
      for k = i, math.min(i + 99, #withdrawn) do chunk[#chunk + 1] = withdrawn[k] end
      self:enqueue(peer, W.frame(W.UPDATE, W.updateBody({ withdrawn = chunk })))
    end
  end
  table.sort(order)
  for _, sig in ipairs(order) do
    local g = groups[sig]
    for i = 1, #g.nlri, 100 do
      local chunk = {}
      for k = i, math.min(i + 99, #g.nlri) do chunk[#chunk + 1] = g.nlri[k] end
      self:enqueue(peer, W.frame(W.UPDATE, W.updateBody({ nlri = chunk, attrs = g.attrs })))
    end
  end
end

function Speaker:enqueue(peer, data)
  peer.outq[#peer.outq + 1] = data
  self.stack:wake()
end

---------------------------------------------------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------------------------------------------------

function Speaker:handleUpdate(peer, body)
  local u, err = W.parseUpdate(body)
  if not u then return nil, err end
  self.stats.updatesIn = self.stats.updatesIn + 1
  local touched = {}
  for _, p in ipairs(u.withdrawn) do
    local key = pkey(p.net, p.plen)
    if peer.adjIn[key] then peer.adjIn[key] = nil touched[key] = true end
  end
  for _, p in ipairs(u.nlri) do
    local key = pkey(p.net, p.plen)
    peer.stats.received = peer.stats.received + 1
    local route, why = self:importRoute(peer, p, u.attrs)
    if route then
      peer.adjIn[key] = route
      peer.stats.accepted = peer.stats.accepted + 1
    else
      peer.stats.filtered = peer.stats.filtered + 1
      self.stats.rejected = self.stats.rejected + 1
      peer.lastRejected = key .. ": " .. tostring(why)
      if peer.adjIn[key] then peer.adjIn[key] = nil end
    end
    touched[key] = true
  end
  local count = 0
  for _ in pairs(peer.adjIn) do count = count + 1 end
  if peer.maxPrefixes and count > peer.maxPrefixes then return nil, "maximum number of prefixes reached", 6, 1 end
  for key in pairs(touched) do self:recompute(key) end
  return true
end

local function dropPeerRoutes(self, peer)
  local keys = {}
  for key in pairs(peer.adjIn) do keys[#keys + 1] = key end
  peer.adjIn = {}
  peer.adjOut = {}
  for _, key in ipairs(keys) do self:recompute(key) end
end

---------------------------------------------------------------------------------------------------------------------
-- Sessions
---------------------------------------------------------------------------------------------------------------------

local function now(self) return self.stack.clock() end

local function authToken(peer, self, nonce)
  return require("tsr.crypto").kdf.hmac(peer.password, B.u32(self.routerId) .. B.u16(self.as) .. nonce):sub(1, 16)
end

--- Read one complete message from the connection. Returns type, body or nil + reason.
local function readMessage(conn, timeout)
  local head, err = conn:receive(19, timeout)
  if not head then return nil, err end
  local typ, len = W.parseHeader(head)
  if not typ then return nil, "bad header" end
  local body = ""
  if len > 19 then
    body, err = conn:receive(len - 19, 10)
    if not body then return nil, err end
  end
  return typ, body
end

function Speaker:teardown(peer, reason)
  if peer.conn then pcall(function() peer.conn:close() end) peer.conn = nil end
  if peer.state == "Established" then self:note(("session with %s (AS%d) went down: %s"):format(B.ipStr(peer.ip), peer.as, tostring(reason))) end
  peer.state = "Idle"
  peer.lastError = reason
  peer.outq = {}
  dropPeerRoutes(self, peer)
end

--- Run one session on an open connection until it ends. `conn` is a connected tcp socket.
function Speaker:session(peer, conn, active)
  local stack = self.stack
  peer.conn = conn
  peer.state = "OpenSent"
  peer.lastRx = now(self)
  local nonce = stack.random(65535) .. ""
  local auth
  if peer.password then auth = nonce .. authToken(peer, self, nonce) end
  self:enqueue(peer, W.frame(W.OPEN, W.openBody({ as = self.as, holdTime = self.holdTime, id = self.routerId, auth = auth })))
  -- the other side's OPEN
  local typ, body = readMessage(conn, 20)
  if typ ~= W.OPEN then self:enqueue(peer, W.notification(1, 3)) self:drain(peer) return self:teardown(peer, "no OPEN received") end
  local o, err = W.parseOpen(body)
  if not o or o.version ~= 4 then self:enqueue(peer, W.notification(2, 1)) self:drain(peer) return self:teardown(peer, "bad OPEN") end
  if o.as ~= peer.as then self:enqueue(peer, W.notification(2, 2)) self:drain(peer) return self:teardown(peer, ("expected AS%d but the neighbour says AS%d"):format(peer.as, o.as)) end
  if peer.password then
    local theirNonce = o.auth and o.auth:sub(1, #o.auth - 16)
    local ok = o.auth and #o.auth > 16 and require("tsr.crypto").kdf.hmac(peer.password, B.u32(o.id) .. B.u16(o.as) .. theirNonce):sub(1, 16) == o.auth:sub(-16)
    if not ok then self:enqueue(peer, W.notification(2, 5)) self:drain(peer) return self:teardown(peer, "authentication failed") end
  end
  if o.holdTime ~= 0 and o.holdTime < 3 then self:enqueue(peer, W.notification(2, 6)) self:drain(peer) return self:teardown(peer, "unacceptable hold time") end
  peer.routerId = o.id
  peer.hold = math.min(self.holdTime, o.holdTime == 0 and self.holdTime or o.holdTime)
  peer.state = "OpenConfirm"
  self:enqueue(peer, W.frame(W.KEEPALIVE))
  peer.lastTx = now(self)
  -- run
  while peer.conn == conn and not peer.stop do
    local t, b = readMessage(conn, 1)
    if t == nil then
      if b ~= "timeout" then return self:teardown(peer, b == "closed" and "the neighbour closed the connection" or tostring(b)) end
      if now(self) - peer.lastRx > peer.hold then
        self:enqueue(peer, W.notification(4, 0))
        self:drain(peer)
        return self:teardown(peer, "hold timer expired")
      end
    else
      peer.lastRx = now(self)
      if t == W.KEEPALIVE then
        if peer.state == "OpenConfirm" then
          peer.state = "Established"
          peer.since = now(self)
          self:note(("session with %s (AS%d, %s) established"):format(B.ipStr(peer.ip), peer.as, peer.rel))
          self.dirty = true
          for key, r in pairs(peer.adjIn) do self:recompute(key) end
        end
      elseif t == W.UPDATE then
        if peer.state ~= "Established" then self:enqueue(peer, W.notification(5, 0)) return self:teardown(peer, "UPDATE before the session was up") end
        local ok, why, code, sub = self:handleUpdate(peer, b)
        if not ok then
          self:enqueue(peer, W.notification(code or 3, sub or 0))
          self:drain(peer)
          return self:teardown(peer, why)
        end
      elseif t == W.NOTIFICATION then
        local n = W.parseNotification(b)
        return self:teardown(peer, ("notification from the neighbour: %s (%d/%d)"):format(W.ERRORS[n.code] or "?", n.code, n.sub))
      end
    end
  end
  if peer.conn == conn then self:teardown(peer, "stopped") end
end

--- Wait (briefly) until the writer has sent everything queued for the peer, e.g. a NOTIFICATION before the connection is closed.
function Speaker:drain(peer)
  self.stack.wait(function() return #peer.outq == 0 or peer.conn == nil end, 2)
end

function Speaker:flushNow(peer)
  local conn = peer.conn
  if not conn then return end
  while #peer.outq > 0 do
    local msg = table.remove(peer.outq, 1)
    conn:send(msg, 5)
    peer.lastTx = now(self)
  end
end

--- Does this side open the TCP connection? (Both sides trying at once makes two sessions.)
function Speaker:isActive(peer)
  if peer.mode == "active" then return true end
  if peer.mode == "passive" then return false end
  local r = self.stack:lookup(peer.ip)
  local mine = r and self.stack:sourceFor(r, peer.ip) or self.routerId
  return mine > peer.ip
end

---------------------------------------------------------------------------------------------------------------------
-- Workers
---------------------------------------------------------------------------------------------------------------------

--- Functions to run side by side: one session loop and one writer per peer, the listener, and the route advertisement timer.
function Speaker:workers()
  local stack = self.stack
  local srv = socket.tcp(stack)
  srv:bind(nil, M.PORT)
  local ok, err = srv:listen(8)
  if not ok then return nil, err end
  self.listener = srv
  self.running = true
  local jobs = {}
  local speaker = self
  jobs[#jobs + 1] = function()
    while speaker.running do
      local c = srv:accept(1)
      if c then
        local ip = B.ip((c:getpeername()))
        local peer = ip and speaker.peers[ip]
        if peer and (peer.state == "Idle" or peer.state == "Connect") and not peer.pending then
          peer.pending = c
          stack:wake()
        else
          c:send(W.notification(6, 5)) c:close()
        end
      end
    end
  end
  for _, peer in ipairs(self.peerList) do
    jobs[#jobs + 1] = function()
      -- session loop
      while speaker.running and not peer.stop do
        peer.state = "Idle"
        local conn
        if speaker:isActive(peer) then
          peer.state = "Connect"
          local c = socket.tcp(stack)
          local src = nil
          local ok2 = c:connect(B.ipStr(peer.ip), M.PORT, 5)
          if ok2 then conn = c else c:close() end
        end
        if not conn and not peer.pending then
          stack.wait(function() return peer.pending ~= nil or not speaker.running end, speaker.connectRetry)
        end
        if peer.pending then conn, peer.pending = peer.pending, nil end
        if conn then
          speaker:session(peer, conn, true)
          stack.wait(function() return not speaker.running end, 1)
        end
      end
    end
    jobs[#jobs + 1] = function()
      -- writer: sends what is queued, keepalives, and watches the hold timer from the outside
      while speaker.running and not peer.stop do
        stack.wait(function() return #peer.outq > 0 or not speaker.running end, 0.5)
        if peer.conn and #peer.outq > 0 then speaker:flushNow(peer) end
        if peer.conn and (peer.state == "Established" or peer.state == "OpenConfirm") and now(speaker) - (peer.lastTx or 0) >= speaker.keepalive then
          peer.conn:send(W.frame(W.KEEPALIVE), 5)
          peer.lastTx = now(speaker)
        end
      end
    end
  end
  jobs[#jobs + 1] = function()
    while speaker.running do
      stack.wait(function() return speaker.dirty or not speaker.running end, 5)
      if speaker.dirty then
        speaker.dirty = false
        for _, peer in ipairs(speaker.peerList) do speaker:advertise(peer) end
        stack.wait(function() return not speaker.running end, speaker.mrai)
      end
      -- a new session needs the whole table even when nothing changed
      for _, peer in ipairs(speaker.peerList) do
        if peer.state == "Established" and not peer.synced then peer.synced = true speaker:advertise(peer) end
        if peer.state ~= "Established" then peer.synced = false end
      end
    end
  end
  -- originate configured networks and let everything settle
  for key in pairs(self.localRoutes) do self:recompute(key) end
  return jobs
end

function Speaker:stop()
  self.running = false
  for _, peer in ipairs(self.peerList) do
    peer.stop = true
    if peer.conn then self:enqueue(peer, W.notification(6, 2)) self:flushNow(peer) self:teardown(peer, "shut down") end
  end
  if self.listener then self.listener:close() end
end

--- Reset a session (it will reconnect).
function Speaker:clear(ip)
  local peer = self.peers[B.ip(ip)]
  if not peer then return false end
  if peer.conn then self:enqueue(peer, W.notification(6, 4)) self:flushNow(peer) self:teardown(peer, "cleared by the administrator") end
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- Information
---------------------------------------------------------------------------------------------------------------------

function Speaker:routeList()
  local out = {}
  for key, r in pairs(self.rib) do out[#out + 1] = r end
  table.sort(out, function(a, b) if a.net ~= b.net then return a.net < b.net end return a.plen < b.plen end)
  return out
end

function Speaker:established()
  local n = 0
  for _, p in ipairs(self.peerList) do if p.state == "Established" then n = n + 1 end end
  return n
end

return M
