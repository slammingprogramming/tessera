-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The IPv4 stack of one computer: interfaces, ARP, routing, forwarding, fragmentation and reassembly, ICMP, hooks for firewalls and NAT, and
-- the dispatch to UDP and TCP. It is driven from outside: frames come in through stack:input(iface, frame), time passes through stack:tick(),
-- and frames leave through the `send(frame)` function that each interface was given. That makes the stack testable without a game (see
-- tests/lib/inetsim.lua) and lets the same code run over wired modems, wireless modems, a Wi-Fi link or a virtual cable.
--
--   local stack = Stack.new{ clock = os.clock, hostname = "gw" }
--   local eth0 = stack:addInterface{ name = "eth0", mac = B.makeMac(os.getComputerID(), 0), send = function(frame) ... end }
--   stack:setAddress("eth0", "10.0.0.2", 24)
--   stack:addRoute("0.0.0.0/0", "10.0.0.1")
--   stack:ping("10.0.0.1")
local B = require("tsr.inet.bytes")
local W = require("tsr.inet.wire")

local M = {}
local Stack = {}
Stack.__index = Stack
M.Stack = Stack

local floor, min, max = math.floor, math.min, math.max

M.DEFAULTS = {
  arpTimeout = 120,          -- seconds a resolved neighbour stays valid without traffic
  arpRetry = 1,              -- seconds between ARP requests
  arpTries = 3,
  arpQueue = 4,              -- packets kept while waiting for an answer
  reassemblyTimeout = 30,
  reassemblyEntries = 32,
  icmpBurst = 20,
  icmpRate = 10,             -- error messages per second (token bucket)
  defaultTtl = 64,
}

local function nowOf(self) return self.clock() end

---------------------------------------------------------------------------------------------------------------------
-- Creation
---------------------------------------------------------------------------------------------------------------------

--- opts: clock (function -> seconds), wait (blocking-call helper, see tsr.inet.socket), hostname, forwarding (bool), random (function(n) -> 1..n).
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({
    clock = opts.clock or os.clock,
    hostname = opts.hostname or "host",
    ifaces = {}, ifaceList = {},
    routes = {},
    neigh = {},
    frags = {}, fragCount = 0,
    protocols = {},
    hooks = { prerouting = {}, input = {}, forward = {}, output = {}, postrouting = {} },
    forwarding = opts.forwarding or false,
    taps = {},
    deferred = {}, depth = 0,
    timers = {}, timerId = 0,
    etherHandlers = {},
    sysctl = {},
    stats = { ip = {}, icmp = {}, udp = {}, tcp = {} },
    icmpTokens = M.DEFAULTS.icmpBurst, icmpRefill = 0,
    ipId = 0,
    wait = opts.wait,
    hosts = {},
    lastTick = nil,
  }, Stack)
  for k, v in pairs(M.DEFAULTS) do self.sysctl[k] = v end
  self.random = opts.random or function(n) return math.random(n) end
  self.ipId = self.random(65535)
  if not self.wait then self.wait = function(cond, timeout) return require("tsr.inet.wait").block(self, cond, timeout) end end
  -- loopback
  local lo = self:addInterface({ name = "lo", kind = "loopback", mac = string.rep("\0", 6), mtu = 65535,
    send = function(frame) end })
  self:setAddress("lo", "127.0.0.1", 8)
  -- protocol handlers register themselves
  require("tsr.inet.icmp").attach(self)
  require("tsr.inet.udp").attach(self)
  require("tsr.inet.tcp").attach(self)
  return self
end

local function count(self, group, name, n)
  local g = self.stats[group]
  g[name] = (g[name] or 0) + (n or 1)
end
Stack.count = count

--- Run `fn` so that anything it triggers through loopback is delivered when the outermost call returns (never recursively).
function Stack:run(fn, ...)
  self.depth = self.depth + 1
  local res = table.pack(pcall(fn, ...))
  self.depth = self.depth - 1
  if self.depth == 0 then self:flush() end
  if not res[1] then error(res[2], 0) end
  return table.unpack(res, 2, res.n)
end

function Stack:defer(fn) self.deferred[#self.deferred + 1] = fn end

function Stack:flush()
  local guard = 0
  while #self.deferred > 0 and guard < 100000 do
    guard = guard + 1
    local fn = table.remove(self.deferred, 1)
    self.depth = self.depth + 1
    local ok, err = pcall(fn)
    self.depth = self.depth - 1
    if not ok then self:log("deferred work failed: " .. tostring(err)) end
  end
end

function Stack:log(text)
  if self.logger then self.logger(text) end
end

--- Called when something happened that a blocked caller may be waiting for.
function Stack:wake()
  self.version = (self.version or 0) + 1
  if self.onWake then self.onWake() end
end

--- Call fn after `delay` seconds (on the stack's clock). Returns an id for cancelTimer.
function Stack:after(delay, fn)
  self.timerId = self.timerId + 1
  self.timers[#self.timers + 1] = { id = self.timerId, at = nowOf(self) + delay, fn = fn }
  return self.timerId
end

function Stack:cancelTimer(id)
  for i, t in ipairs(self.timers) do if t.id == id then table.remove(self.timers, i) return true end end
  return false
end

---------------------------------------------------------------------------------------------------------------------
-- Interfaces and addresses
---------------------------------------------------------------------------------------------------------------------

--- spec: name, mac (6 bytes), mtu (1500), kind ("ethernet" | "wifi" | "loopback" | "virtual"), send (function(frame)), parent + vlan for 802.1Q
--- subinterfaces. Returns the interface table.
function Stack:addInterface(spec)
  assert(spec.name, "interface needs a name")
  if self.ifaces[spec.name] then error("interface " .. spec.name .. " exists already", 0) end
  local iface = {
    name = spec.name, mac = spec.mac, mtu = spec.mtu or 1500, kind = spec.kind or "ethernet", up = spec.up ~= false,
    addrs = {}, send = spec.send, parent = spec.parent, vlan = spec.vlan, vlans = {}, stack = self,
    promisc = false, noarp = spec.noarp or false, forwarding = nil,
    stats = { rxPackets = 0, rxBytes = 0, txPackets = 0, txBytes = 0, rxErrors = 0, rxDropped = 0, txErrors = 0 },
    meta = spec.meta or {},
  }
  if spec.parent then
    local parent = self.ifaces[spec.parent]
    assert(parent, "no parent interface " .. tostring(spec.parent))
    iface.mac = iface.mac or parent.mac
    iface.kind = "vlan"
    iface.send = function(frame) return parent.send(frame) end
    parent.vlans[spec.vlan] = iface
  end
  self.ifaces[iface.name] = iface
  self.ifaceList[#self.ifaceList + 1] = iface
  self.neigh[iface.name] = {}
  return iface
end

function Stack:removeInterface(name)
  local iface = self.ifaces[name]
  if not iface then return false end
  self:setUp(name, false)
  for i, f in ipairs(self.ifaceList) do if f == iface then table.remove(self.ifaceList, i) break end end
  if iface.parent and self.ifaces[iface.parent] then self.ifaces[iface.parent].vlans[iface.vlan] = nil end
  self.ifaces[name] = nil
  self.neigh[name] = nil
  return true
end

function Stack:iface(name) return self.ifaces[name] end

--- Add a VLAN subinterface "<parent>.<vid>" (802.1Q).
function Stack:addVlan(parent, vid, name)
  return self:addInterface({ name = name or (parent .. "." .. vid), parent = parent, vlan = vid, mtu = self.ifaces[parent].mtu - 4 })
end

local function connectedRoute(self, iface, a)
  local net = B.band(a.ip, B.mask(a.plen))
  self:addRoute(B.cidrStr(net, a.plen), nil, { iface = iface.name, proto = "connected", metric = 0, src = a.ip })
end

--- Give an interface an address ("10.0.0.2", 24). Adds the connected route and announces the address with a gratuitous ARP.
function Stack:setAddress(name, ip, plen)
  local iface = assert(self.ifaces[name], "no interface " .. tostring(name))
  ip = B.ip(ip)
  assert(ip, "bad address")
  for _, a in ipairs(iface.addrs) do if a.ip == ip and a.plen == plen then return a end end
  local a = { ip = ip, plen = plen }
  iface.addrs[#iface.addrs + 1] = a
  if iface.up then connectedRoute(self, iface, a) end
  if iface.up and iface.kind ~= "loopback" and not iface.noarp then self:announce(iface, ip) end
  return a
end

function Stack:removeAddress(name, ip)
  local iface = self.ifaces[name]
  if not iface then return false end
  ip = B.ip(ip)
  for i, a in ipairs(iface.addrs) do
    if a.ip == ip then
      table.remove(iface.addrs, i)
      self:removeRoutes(function(r) return r.iface == name and r.proto == "connected" and r.src == ip end)
      return true
    end
  end
  return false
end

function Stack:clearAddresses(name)
  local iface = self.ifaces[name]
  if not iface then return end
  for i = #iface.addrs, 1, -1 do self:removeAddress(name, iface.addrs[i].ip) end
end

function Stack:setUp(name, up)
  local iface = assert(self.ifaces[name], "no interface " .. tostring(name))
  if iface.up == up then return end
  iface.up = up
  if up then
    for _, a in ipairs(iface.addrs) do connectedRoute(self, iface, a) end
    for _, a in ipairs(iface.addrs) do if iface.kind ~= "loopback" then self:announce(iface, a.ip) end end
  else
    self:removeRoutes(function(r) return r.iface == name end)
    self.neigh[name] = {}
  end
  for _, vl in pairs(iface.vlans) do self:setUp(vl.name, up) end
end

--- Is `ip` one of our own addresses?
function Stack:isLocal(ip)
  if B.isLoopback(ip) then return true end
  for _, iface in ipairs(self.ifaceList) do
    if iface.up then for _, a in ipairs(iface.addrs) do if a.ip == ip then return true, iface end end end
  end
  return false
end

--- The directed-broadcast address of an interface address.
local function bcastOf(a) return B.broadcast(B.band(a.ip, B.mask(a.plen)), a.plen) end

function Stack:isBroadcastFor(iface, ip)
  if ip == B.BROADCAST then return true end
  for _, a in ipairs(iface.addrs) do
    if a.plen < 31 and ip == bcastOf(a) then return true end
  end
  return false
end

function Stack:primaryAddress(name)
  local iface = self.ifaces[name]
  return iface and iface.addrs[1] and iface.addrs[1].ip
end

---------------------------------------------------------------------------------------------------------------------
-- Routing table
---------------------------------------------------------------------------------------------------------------------

--- Add a route. dest is "a.b.c.d/n" (or "default"); gateway is an address or nil (on-link). opts: iface, metric, proto, src.
function Stack:addRoute(dest, gateway, opts)
  opts = opts or {}
  local net, plen
  if dest == "default" then net, plen = 0, 0 else net, plen = B.cidr(dest) end
  if not net then return nil, "bad destination " .. tostring(dest) end
  local gw = gateway and B.ip(gateway) or nil
  if gateway and not gw then return nil, "bad gateway" end
  local ifname = opts.iface
  if not ifname then
    if not gw then return nil, "a route needs a gateway or an interface" end
    local r = self:lookup(gw)
    if not r or r.gateway then return nil, "the gateway " .. B.ipStr(gw) .. " is not reachable directly" end
    ifname = r.iface
  end
  if not self.ifaces[ifname] then return nil, "no interface " .. tostring(ifname) end
  local metric = opts.metric or 1
  local proto = opts.proto or "static"
  for _, r in ipairs(self.routes) do
    if r.net == net and r.plen == plen and r.gateway == gw and r.iface == ifname and r.proto == proto then
      r.metric = metric
      r.src = opts.src or r.src
      return r
    end
  end
  local r = { net = net, plen = plen, gateway = gw, iface = ifname, metric = metric, proto = proto, src = opts.src, since = nowOf(self), extra = opts.extra }
  self.routes[#self.routes + 1] = r
  return r
end

function Stack:removeRoutes(pred)
  local n = 0
  for i = #self.routes, 1, -1 do
    if pred(self.routes[i]) then table.remove(self.routes, i) n = n + 1 end
  end
  return n
end

function Stack:delRoute(dest, gateway)
  local net, plen
  if dest == "default" then net, plen = 0, 0 else net, plen = B.cidr(dest) end
  local gw = gateway and B.ip(gateway) or nil
  return self:removeRoutes(function(r) return r.net == net and r.plen == plen and (gateway == nil or r.gateway == gw) and r.proto ~= "connected" end) > 0
end

--- Longest-prefix match. Ties go to the lower metric, then to the older route. Routes on interfaces that are down are skipped.
function Stack:lookup(dst, onlyIface)
  local best
  for _, r in ipairs(self.routes) do
    local iface = self.ifaces[r.iface]
    if iface and iface.up and (not onlyIface or r.iface == onlyIface) and B.band(dst, B.mask(r.plen)) == r.net then
      if not best or r.plen > best.plen or (r.plen == best.plen and r.metric < best.metric) then best = r end
    end
  end
  return best
end

--- The source address to use when sending to `dst` via `route`.
function Stack:sourceFor(route, dst)
  local iface = self.ifaces[route.iface]
  if route.src and route.proto == "connected" then return route.src end
  local target = route.gateway or dst
  for _, a in ipairs(iface.addrs) do
    if B.inNet(target, B.band(a.ip, B.mask(a.plen)), a.plen) then return a.ip end
  end
  return iface.addrs[1] and iface.addrs[1].ip
end

---------------------------------------------------------------------------------------------------------------------
-- Capture
---------------------------------------------------------------------------------------------------------------------

--- fn(direction "rx" | "tx", iface, frame). Returns a function that removes the tap.
function Stack:addTap(fn)
  self.taps[#self.taps + 1] = fn
  return function()
    for i, f in ipairs(self.taps) do if f == fn then table.remove(self.taps, i) return end end
  end
end

local function tap(self, dir, iface, frame)
  for _, fn in ipairs(self.taps) do pcall(fn, dir, iface, frame) end
end

---------------------------------------------------------------------------------------------------------------------
-- Link layer: transmit, receive, ARP
---------------------------------------------------------------------------------------------------------------------

--- Send an Ethernet frame out of `iface` (a VLAN subinterface tags it and goes out through its parent).
function Stack:transmit(iface, dstMac, ethType, payload)
  if not iface.up then return false, "interface down" end
  local f = { dst = dstMac, src = iface.mac, type = ethType, payload = payload }
  local out = iface
  if iface.parent then f.vlan = iface.vlan out = self.ifaces[iface.parent] end
  local frame = W.ethEncode(f)
  tap(self, "tx", out, frame)
  out.stats.txPackets = out.stats.txPackets + 1
  out.stats.txBytes = out.stats.txBytes + #frame
  if iface.parent then iface.stats.txPackets = iface.stats.txPackets + 1 iface.stats.txBytes = iface.stats.txBytes + #frame end
  if not out.send then return false, "no driver" end
  local ok, err = pcall(out.send, frame)
  if not ok then out.stats.txErrors = out.stats.txErrors + 1 return false, err end
  return true
end

function Stack:neighbour(iface, ip) return self.neigh[iface.name] and self.neigh[iface.name][ip] end

function Stack:addNeighbour(iface, ip, mac, static)
  local table_ = self.neigh[iface.name]
  local e = table_[ip]
  if not e then e = {} table_[ip] = e end
  e.mac = mac
  e.expires = static and math.huge or nowOf(self) + self.sysctl.arpTimeout
  e.static = static or nil
  local pending = e.pending
  e.pending = nil
  e.tries = nil
  if pending then for _, bytes in ipairs(pending) do self:transmit(iface, mac, W.ETH_IPV4, bytes) end end
  return e
end

local function sendArp(self, iface, op, tha, tpa, spa)
  local sha = iface.mac
  local payload = W.arpEncode({ op = op, sha = sha, spa = spa, tha = tha, tpa = tpa })
  self:transmit(iface, op == W.ARP_REQUEST and B.MAC_BROADCAST or tha, W.ETH_ARP, payload)
  count(self, "ip", "arpOut")
end

--- Gratuitous ARP: tell the segment who owns `ip` (RFC 5227 announcement).
function Stack:announce(iface, ip)
  if iface.noarp or not iface.mac then return end
  sendArp(self, iface, W.ARP_REQUEST, string.rep("\0", 6), ip, ip)
end

--- Ask who has `ip` (used by DHCP address conflict probes too). spa 0 = a probe.
function Stack:arpRequest(iface, ip, spa)
  sendArp(self, iface, W.ARP_REQUEST, string.rep("\0", 6), ip, spa or self:primaryAddress(iface.name) or 0)
end

--- Send an IP packet (bytes) to the next hop `nexthop` on `iface`, resolving the Ethernet address first.
function Stack:linkSend(iface, nexthop, bytes, broadcast)
  if not iface.up then return false, "interface down" end
  if iface.kind == "loopback" then
    self:defer(function() self:ipInput(iface, bytes) end)
    return true
  end
  if iface.noarp then return self:transmit(iface, B.MAC_BROADCAST, W.ETH_IPV4, bytes) end
  if broadcast then return self:transmit(iface, B.MAC_BROADCAST, W.ETH_IPV4, bytes) end
  local e = self:neighbour(iface, nexthop)
  if e and e.mac and (e.static or e.expires > nowOf(self)) then return self:transmit(iface, e.mac, W.ETH_IPV4, bytes) end
  -- unresolved: queue and ask
  if not e then e = {} self.neigh[iface.name][nexthop] = e end
  e.mac = nil
  e.pending = e.pending or {}
  if #e.pending >= self.sysctl.arpQueue then table.remove(e.pending, 1) end
  e.pending[#e.pending + 1] = bytes
  if not e.tries then
    e.tries = 1
    e.nextTry = nowOf(self) + self.sysctl.arpRetry
    local spa = self:primaryAddress(iface.name) or 0
    sendArp(self, iface, W.ARP_REQUEST, string.rep("\0", 6), nexthop, spa)
  end
  return true
end

local function arpInput(self, iface, payload)
  local a, err = W.arpDecode(payload)
  if not a then count(self, "ip", "arpErrors") return end
  if a.sha == iface.mac then return end
  local mine = false
  for _, addr in ipairs(iface.addrs) do if addr.ip == a.tpa then mine = true end end
  local known = self:neighbour(iface, a.spa)
  -- learn the sender when we already track it or when the message is addressed to us
  if a.spa ~= 0 and (mine or (known and not known.static)) then self:addNeighbour(iface, a.spa, a.sha) end
  if a.op == W.ARP_REQUEST then
    local answer = mine
    if not answer and iface.proxyArp and a.spa ~= a.tpa then
      -- proxy ARP: answer for addresses that are routed via another interface
      local r = self:lookup(a.tpa)
      if r and r.iface ~= iface.name and not self:isLocal(a.tpa) then answer = true end
    end
    if answer and a.spa ~= a.tpa then
      sendArp(self, iface, W.ARP_REPLY, a.sha, a.spa, a.tpa)
    end
  end
  if self.onArp then self.onArp(iface, a) end
end

---------------------------------------------------------------------------------------------------------------------
-- Frames in
---------------------------------------------------------------------------------------------------------------------

--- A frame arrived on `iface` (from the driver). Hooks for switches/bridges: iface.rxhook(frame) returning true consumes the frame.
function Stack:input(iface, frame)
  return self:run(function()
    iface.stats.rxPackets = iface.stats.rxPackets + 1
    iface.stats.rxBytes = iface.stats.rxBytes + #frame
    tap(self, "rx", iface, frame)
    if iface.rxhook and iface.rxhook(frame) then return end
    local f, err = W.ethDecode(frame)
    if not f then iface.stats.rxErrors = iface.stats.rxErrors + 1 return end
    local target = iface
    if f.vlan then
      target = iface.vlans[f.vlan]
      if not target then iface.stats.rxDropped = iface.stats.rxDropped + 1 return end
      target.stats.rxPackets = target.stats.rxPackets + 1
    elseif iface.vlanOnly then
      iface.stats.rxDropped = iface.stats.rxDropped + 1
      return
    end
    if not target.up then return end
    local mine = f.dst == target.mac or B.isBroadcastMac(f.dst) or B.isMulticastMac(f.dst) or iface.promisc
    if not mine then iface.stats.rxDropped = iface.stats.rxDropped + 1 return end
    local h = self.etherHandlers[f.type]
    if h and h(self, target, f) then return end
    if f.type == W.ETH_ARP then return arpInput(self, target, f.payload) end
    if f.type == W.ETH_IPV4 then return self:ipInput(target, f.payload) end
    iface.stats.rxDropped = iface.stats.rxDropped + 1
  end)
end

---------------------------------------------------------------------------------------------------------------------
-- IP: hooks, output, input, forwarding
---------------------------------------------------------------------------------------------------------------------

--- Register a filter at a hook point: "prerouting", "input", "forward", "output", "postrouting".
--- fn(stack, pkt, ctx) returns nil/"accept" or "drop" (and may change pkt; set pkt.dirty = true when it did). Lower `priority` runs first.
function Stack:addHook(point, name, fn, priority)
  local list = assert(self.hooks[point], "no such hook " .. tostring(point))
  for i, h in ipairs(list) do if h.name == name then table.remove(list, i) break end end
  list[#list + 1] = { name = name, fn = fn, priority = priority or 100 }
  table.sort(list, function(a, b) return a.priority < b.priority end)
end

function Stack:removeHook(point, name)
  local list = self.hooks[point]
  for i, h in ipairs(list) do if h.name == name then table.remove(list, i) return true end end
  return false
end

local function runHooks(self, point, pkt, ctx)
  local list = self.hooks[point]
  for i = 1, #list do
    local verdict = list[i].fn(self, pkt, ctx)
    if verdict == "drop" then count(self, "ip", "hookDrops") return false end
  end
  if pkt.dirty then
    local raw = W.ipEncode(pkt)
    pkt.dirty = nil
    pkt.raw = raw
  end
  return true
end

local function nextId(self)
  self.ipId = (self.ipId + 1) % 65536
  return self.ipId
end

--- Build the packet bytes for pkt and hand them to the link layer, fragmenting when they exceed the MTU.
local function emit(self, iface, nexthop, pkt, broadcast)
  local mtu = iface.mtu
  local raw = W.ipEncode(pkt)
  if #raw <= mtu then
    count(self, "ip", "outPackets")
    return self:linkSend(iface, nexthop, raw, broadcast)
  end
  if pkt.df then return false, "fragmentation needed" end
  local hl = 20
  local per = floor((mtu - hl) / 8) * 8
  if per <= 0 then return false, "mtu too small" end
  local payload = pkt.payload
  local pos = 0
  local baseFrag = pkt.frag or 0
  local origMf = pkt.mf
  while pos < #payload do
    local piece = payload:sub(pos + 1, pos + per)
    local last = pos + per >= #payload
    local frag = {
      src = pkt.src, dst = pkt.dst, proto = pkt.proto, ttl = pkt.ttl, tos = pkt.tos, id = pkt.id, df = false,
      mf = (not last) or origMf, frag = baseFrag + pos / 8, payload = piece,
      options = pos == 0 and pkt.options or nil,
    }
    local bytes = W.ipEncode(frag)
    count(self, "ip", "fragCreates")
    local ok, err = self:linkSend(iface, nexthop, bytes, broadcast)
    if not ok then return false, err end
    pos = pos + per
  end
  return true
end

--- Send an IP packet from this host. args: dst, proto, payload; optional src, ttl, tos, df, id, iface (force the interface), noroute
--- (the destination is on-link), broadcast. Returns true or nil + reason.
function Stack:ipSend(args)
  return self:run(function()
    local dst = B.ip(args.dst)
    if not dst then return nil, "bad destination address" end
    local pkt = {
      src = args.src, dst = dst, proto = args.proto, payload = args.payload, ttl = args.ttl or self.sysctl.defaultTtl, tos = args.tos or 0,
      df = args.df, id = args.id or nextId(self), options = args.options,
    }
    -- loopback and own addresses
    if self:isLocal(dst) then
      pkt.src = pkt.src or dst
      local lo = self.ifaces.lo
      if not runHooks(self, "output", pkt, { iface = lo }) then return nil, "filtered" end
      local raw = pkt.raw or W.ipEncode(pkt)
      pkt.raw = nil
      count(self, "ip", "outPackets")
      self:defer(function() self:ipInput(lo, raw) end)
      return true
    end
    local iface, nexthop, broadcast
    if args.iface then
      iface = self.ifaces[args.iface]
      if not iface or not iface.up then return nil, "no such interface" end
      if dst == B.BROADCAST or self:isBroadcastFor(iface, dst) then
        broadcast = true
        nexthop = dst
      else
        local r = self:lookup(dst, iface.name)
        nexthop = r and r.gateway or dst
      end
      pkt.src = pkt.src or (iface.addrs[1] and iface.addrs[1].ip) or 0
    else
      if dst == B.BROADCAST then
        -- no interface named: use the first one that is up and has an address
        for _, i in ipairs(self.ifaceList) do
          if i.up and i.kind ~= "loopback" and #i.addrs > 0 then iface = i break end
        end
        if not iface then count(self, "ip", "outNoRoutes") return nil, "network unreachable" end
        broadcast, nexthop = true, dst
        pkt.src = pkt.src or iface.addrs[1].ip
      else
        local r = self:lookup(dst)
        if not r then count(self, "ip", "outNoRoutes") return nil, "network unreachable" end
        iface = self.ifaces[r.iface]
        nexthop = r.gateway or dst
        if self:isBroadcastFor(iface, dst) then broadcast = true end
        pkt.src = pkt.src or self:sourceFor(r, dst)
      end
    end
    if not pkt.src then return nil, "no source address" end
    if B.isMulticast(dst) then broadcast = true end
    if not runHooks(self, "output", pkt, { iface = iface }) then return nil, "filtered" end
    if not runHooks(self, "postrouting", pkt, { iface = iface }) then return nil, "filtered" end
    local ok, err = emit(self, iface, nexthop, pkt, broadcast)
    if not ok then return nil, err end
    return true
  end)
end

local function icmpAllowed(self)
  local now = nowOf(self)
  local dt = now - (self.icmpLast or now)
  self.icmpLast = now
  self.icmpTokens = min(self.sysctl.icmpBurst, self.icmpTokens + dt * self.sysctl.icmpRate)
  if self.icmpTokens < 1 then return false end
  self.icmpTokens = self.icmpTokens - 1
  return true
end

--- Send an ICMP error about the packet `pkt` (parsed, with .header and .payload). Follows RFC 1122 3.2.2: never about errors, fragments
--- other than the first, broadcasts, or packets whose source is not a single host.
function Stack:icmpError(pkt, typ, code, rest)
  if pkt.frag and pkt.frag > 0 then return end
  if pkt.src == 0 or pkt.src == B.BROADCAST or B.isMulticast(pkt.src) or B.isLoopback(pkt.src) then return end
  if pkt.dst == B.BROADCAST or B.isMulticast(pkt.dst) then return end
  if pkt.proto == W.PROTO_ICMP then
    local t = pkt.payload:byte(1)
    if t ~= W.ICMP_ECHO and t ~= W.ICMP_ECHO_REPLY then return end      -- never an error about an error
  end
  if not icmpAllowed(self) then return end
  local data = pkt.header .. pkt.payload:sub(1, 8)
  local src
  if self:isLocal(pkt.dst) then src = pkt.dst end
  count(self, "icmp", "outErrors")
  self:ipSend({ dst = pkt.src, src = src, proto = W.PROTO_ICMP, payload = W.icmpEncode({ type = typ, code = code, rest = rest, data = data }), tos = 0xC0 })
end

--- Reassemble fragments (RFC 791 / 815). Returns the complete packet or nil while pieces are missing.
local function reassemble(self, pkt)
  local key = pkt.src .. ":" .. pkt.dst .. ":" .. pkt.proto .. ":" .. pkt.id
  local e = self.frags[key]
  if not e then
    if self.fragCount >= self.sysctl.reassemblyEntries then return nil end
    e = { pieces = {}, total = nil, expires = nowOf(self) + self.sysctl.reassemblyTimeout }
    self.frags[key] = e
    self.fragCount = self.fragCount + 1
  end
  local offset = pkt.frag * 8
  e.pieces[offset] = pkt.payload
  if pkt.frag == 0 then e.first = pkt end
  if not pkt.mf then e.total = offset + #pkt.payload end
  if not e.total then return nil end
  -- contiguous from 0 to total?
  local offsets = {}
  for o in pairs(e.pieces) do offsets[#offsets + 1] = o end
  table.sort(offsets)
  local pos, parts = 0, {}
  for _, o in ipairs(offsets) do
    if o > pos then return nil end
    local data = e.pieces[o]
    if o + #data > pos then
      parts[#parts + 1] = data:sub(pos - o + 1)
      pos = o + #data
    end
  end
  if pos < e.total or not e.first then return nil end
  self.frags[key] = nil
  self.fragCount = self.fragCount - 1
  count(self, "ip", "reasmOK")
  local whole = {}
  for k, v in pairs(e.first) do whole[k] = v end
  whole.payload = table.concat(parts):sub(1, e.total)
  whole.frag, whole.mf = 0, false
  whole.len = (whole.ihl or 5) * 4 + #whole.payload
  return whole
end

local function deliver(self, iface, pkt)
  if not runHooks(self, "input", pkt, { iface = iface }) then return end
  count(self, "ip", "inDelivers")
  local h = self.protocols[pkt.proto]
  if h then return h(self, iface, pkt) end
  if self.rawHandlers and self.rawHandlers[pkt.proto] then return self.rawHandlers[pkt.proto](self, iface, pkt) end
  count(self, "ip", "inUnknownProtos")
  self:icmpError(pkt, W.ICMP_UNREACH, W.UNREACH_PROTO)
end

local function forward(self, iface, pkt)
  if not self.forwarding and not iface.forwarding then count(self, "ip", "inAddrErrors") return end
  if B.isLoopback(pkt.dst) or pkt.dst == 0 or B.isMulticast(pkt.dst) or pkt.src == B.BROADCAST then return end
  if pkt.ttl <= 1 then
    count(self, "ip", "inTtlExceeded")
    return self:icmpError(pkt, W.ICMP_TIME_EXCEEDED, 0)
  end
  local r = self:lookup(pkt.dst)
  if not r then
    count(self, "ip", "outNoRoutes")
    return self:icmpError(pkt, W.ICMP_UNREACH, W.UNREACH_NET)
  end
  local out = self.ifaces[r.iface]
  pkt.ttl = pkt.ttl - 1
  pkt.dirty = true
  if not runHooks(self, "forward", pkt, { iface = iface, out = out }) then return end
  if not runHooks(self, "postrouting", pkt, { iface = iface, out = out }) then return end
  local nexthop = r.gateway or pkt.dst
  local raw = pkt.raw or W.ipEncode(pkt)
  if #raw > out.mtu and pkt.df then
    count(self, "ip", "fragFails")
    return self:icmpError(pkt, W.ICMP_UNREACH, W.UNREACH_FRAG, B.u16(0) .. B.u16(out.mtu))
  end
  count(self, "ip", "forwarded")
  local ok = emit(self, out, nexthop, pkt, self:isBroadcastFor(out, pkt.dst))
  if not ok then self:icmpError(pkt, W.ICMP_UNREACH, W.UNREACH_HOST) end
end

--- An IPv4 packet (bytes) arrived on `iface`.
function Stack:ipInput(iface, bytes)
  count(self, "ip", "inReceives")
  local pkt, err = W.ipDecode(bytes)
  if not pkt then count(self, "ip", "inHdrErrors") return end
  pkt.raw = nil
  if not runHooks(self, "prerouting", pkt, { iface = iface }) then return end
  local localDst = self:isLocal(pkt.dst) or self:isBroadcastFor(iface, pkt.dst) or pkt.dst == B.BROADCAST
    or (B.isMulticast(pkt.dst) and pkt.dst == 3758096385)           -- 224.0.0.1, all hosts
  -- a host that has no address yet (DHCP) still accepts broadcast and anything sent to its MAC
  if not localDst and #iface.addrs == 0 and iface.acceptAny then localDst = true end
  if not localDst then return forward(self, iface, pkt) end
  if pkt.mf or pkt.frag > 0 then
    count(self, "ip", "reasmReqds")
    pkt = reassemble(self, pkt)
    if not pkt then return end
  end
  return deliver(self, iface, pkt)
end

---------------------------------------------------------------------------------------------------------------------
-- Time
---------------------------------------------------------------------------------------------------------------------

function Stack:tick()
  local now = nowOf(self)
  -- ARP resolution retries
  for name, tbl in pairs(self.neigh) do
    local iface = self.ifaces[name]
    for ip, e in pairs(tbl) do
      if e.pending and e.tries and now >= e.nextTry then
        if e.tries >= self.sysctl.arpTries then
          local dropped = e.pending
          tbl[ip] = nil
          for _, bytes in ipairs(dropped) do
            local pkt = W.ipDecode(bytes)
            if pkt and not self:isLocal(pkt.src) then self:icmpError(pkt, W.ICMP_UNREACH, W.UNREACH_HOST) end
          end
          if self.onUnresolved then self.onUnresolved(iface, ip) end
        else
          e.tries = e.tries + 1
          e.nextTry = now + self.sysctl.arpRetry
          if iface then self:arpRequest(iface, ip) end
        end
      elseif e.mac and not e.static and e.expires and now > e.expires + 60 then
        tbl[ip] = nil
      end
    end
  end
  -- reassembly timeouts
  for key, e in pairs(self.frags) do
    if now >= e.expires then self.frags[key] = nil self.fragCount = self.fragCount - 1 count(self, "ip", "reasmFails") end
  end
  -- timers
  if #self.timers > 0 then
    local due = {}
    for i = #self.timers, 1, -1 do
      if self.timers[i].at <= now then due[#due + 1] = table.remove(self.timers, i) end
    end
    table.sort(due, function(a, b) return a.at < b.at end)
    for _, t in ipairs(due) do self:run(t.fn) end
  end
  self:run(function() require("tsr.inet.tcp").tick(self, now) end)
  self:flush()
  self.lastTick = now
end

---------------------------------------------------------------------------------------------------------------------
-- Convenience
---------------------------------------------------------------------------------------------------------------------

--- Add hosts-file style names: stack:addHost("alpha", "10.0.0.2").
function Stack:addHost(name, ip) self.hosts[name:lower()] = B.ip(ip) end

--- Turn a name or dotted quad into an address: hosts table, then stack.resolver(name) if set. Returns ip or nil + reason.
function Stack:resolve(name, timeout)
  local ip = B.ip(name)
  if ip then return ip end
  if name == "localhost" then return B.ip("127.0.0.1") end
  local h = self.hosts[name:lower()]
  if h then return h end
  if self.resolver then return self.resolver(name, timeout) end
  return nil, "cannot resolve " .. name
end

return M
