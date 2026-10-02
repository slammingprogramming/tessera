-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The DHCP server (RFC 2131): hands out addresses from pools, remembers leases across restarts, honours reservations and requests for a
-- particular address, answers renewals, releases, declines and informs, and serves clients behind a relay agent (giaddr).
--
-- Configuration (/etc/tsr/inet/dhcpd.lua):
--   return { pools = {
--     { name = "lan", iface = "eth1", network = "10.2.0.0/24", range = { "10.2.0.100", "10.2.0.200" }, router = "10.2.0.1",
--       dns = { "10.2.0.1" }, domain = "lan", lease = 3600, ntp = { "10.2.0.1" }, mtu = 1500,
--       reservations = { ["02:54:00:01:00:05"] = "10.2.0.50" } },
--   } }
local B = require("tsr.inet.bytes")
local socket = require("tsr.inet.socket")
local W = require("tsr.dhcp.wire")
local vfs = require("tsr.vfs")

local M = {}
local Server = {}
Server.__index = Server

M.CONFIG = "/etc/tsr/inet/dhcpd.lua"
M.LEASES = "/var/lib/tsr/inet/dhcpd.leases"
M.OFFER_HOLD = 60               -- seconds an offered address stays reserved for the client
M.DECLINE_HOLD = 3600           -- seconds an address that a client reported as in use is avoided

local function parsePool(p)
  local pool = { name = p.name or "pool", iface = p.iface, lease = p.lease or 3600, dns = {}, ntp = {}, reservations = {}, mtu = p.mtu, domain = p.domain }
  local net, plen = B.cidr(p.network or "")
  if not net then return nil, "pool " .. tostring(p.name) .. ": bad network" end
  pool.net, pool.plen = net, plen
  pool.mask = B.mask(plen)
  pool.first, pool.last = B.ip(p.range and p.range[1] or ""), B.ip(p.range and p.range[2] or "")
  if not pool.first or not pool.last or pool.last < pool.first then return nil, "pool " .. tostring(p.name) .. ": bad range" end
  if not (B.inNet(pool.first, net, plen) and B.inNet(pool.last, net, plen)) then return nil, "pool " .. tostring(p.name) .. ": the range is outside the network" end
  pool.router = p.router and B.ip(p.router) or nil
  for _, d in ipairs(p.dns or {}) do pool.dns[#pool.dns + 1] = B.ip(d) end
  for _, d in ipairs(p.ntp or {}) do pool.ntp[#pool.ntp + 1] = B.ip(d) end
  for mac, ip in pairs(p.reservations or {}) do
    local m, a = B.mac(mac), B.ip(ip)
    if m and a then pool.reservations[m] = a end
  end
  pool.broadcast = B.broadcast(net, plen)
  return pool
end

--- stack, config table. Returns a server object (call :serve() to run it, or feed it messages with :handle for tests).
function M.new(stack, cfg)
  local self = setmetatable({ stack = stack, pools = {}, leases = {}, offers = {}, bad = {}, stats = { discover = 0, offer = 0, request = 0, ack = 0, nak = 0, release = 0, decline = 0, inform = 0 } }, Server)
  local problems = {}
  for _, p in ipairs(cfg.pools or {}) do
    local pool, err = parsePool(p)
    if pool then self.pools[#self.pools + 1] = pool else problems[#problems + 1] = err end
  end
  self.persist = cfg.persist ~= false
  self.clock = cfg.clock or function() return os.epoch and os.epoch("utc") / 1000 or stack.clock() end
  self.leasePath = cfg.leasePath or M.LEASES
  return self, problems
end

function Server:load()
  local t = vfs.readTable and vfs.readTable(self.leasePath)
  if type(t) == "table" then
    for macHex, l in pairs(t) do
      self.leases[B.mac(macHex)] = { ip = l.ip, expires = l.expires, pool = l.pool }
    end
  end
end

function Server:save()
  if not self.persist then return end
  local t = {}
  for mac, l in pairs(self.leases) do t[B.macStr(mac)] = { ip = l.ip, expires = l.expires, pool = l.pool } end
  if vfs.writeTable then vfs.writeTable(self.leasePath, t) end
end

--- Leases are kept in real (UTC) seconds so that they survive a restart of the computer; tests pass the simulated clock instead.
local function now(self) return self.clock() end

function Server:poolFor(iface, giaddr, ciaddr)
  local probe
  if giaddr and giaddr ~= 0 then probe = giaddr
  elseif ciaddr and ciaddr ~= 0 then probe = ciaddr end
  for _, pool in ipairs(self.pools) do
    if probe then
      if B.inNet(probe, pool.net, pool.plen) then return pool end
    elseif pool.iface == iface then return pool end
  end
  if not probe then
    -- an interface without its own pool: use the pool whose network contains the interface address
    local i = self.stack.ifaces[iface]
    for _, pool in ipairs(self.pools) do
      if i then for _, a in ipairs(i.addrs) do if B.inNet(a.ip, pool.net, pool.plen) then return pool end end end
    end
  end
  return nil
end

local function taken(self, pool, ip, exceptMac)
  local t = now(self)
  for mac, l in pairs(self.leases) do
    if l.ip == ip and mac ~= exceptMac and l.expires > t then return true end
  end
  for mac, o in pairs(self.offers) do
    if o.ip == ip and mac ~= exceptMac and o.expires > t then return true end
  end
  if self.bad[ip] and self.bad[ip] > t then return true end
  for mac, r in pairs(pool.reservations) do if r == ip and mac ~= exceptMac then return true end end
  for _, i in pairs(self.stack.ifaces) do for _, a in ipairs(i.addrs) do if a.ip == ip then return true end end end
  return false
end

--- Pick an address for `mac`: reservation, existing lease, the one it asked for, or the first free one.
function Server:choose(pool, mac, requested)
  if pool.reservations[mac] then return pool.reservations[mac] end
  local old = self.leases[mac]
  if old and old.pool == pool.name and B.inNet(old.ip, pool.net, pool.plen) and not taken(self, pool, old.ip, mac) then return old.ip end
  if requested and requested >= pool.first and requested <= pool.last and not taken(self, pool, requested, mac) then return requested end
  for ip = pool.first, pool.last do
    if not taken(self, pool, ip, mac) then return ip end
  end
  return nil
end

local function replyOptions(pool, serverId, typ, leaseTime)
  local o = { type = typ, serverId = serverId }
  if typ == W.OFFER or typ == W.ACK then
    o.subnetMask, o.broadcast = pool.mask, pool.broadcast
    o.leaseTime = leaseTime
    o.renewalTime, o.rebindingTime = math.floor(leaseTime / 2), math.floor(leaseTime * 7 / 8)
    if pool.router then o.routers = { pool.router } end
    if #pool.dns > 0 then o.dns = pool.dns end
    if pool.domain then o.domain = pool.domain end
    if #pool.ntp > 0 then o.ntp = pool.ntp end
    if pool.mtu then o.mtu = pool.mtu end
  end
  return o
end

--- Handle one request message. Returns a reply message table (not encoded) or nil, and the pool used.
function Server:handle(m, ifname)
  local t = m.options.type
  local mac = m.chaddr
  local pool = self:poolFor(ifname, m.giaddr, m.ciaddr)
  if not pool then return nil end
  local iface = self.stack.ifaces[ifname]
  local serverId = (iface and iface.addrs[1] and iface.addrs[1].ip) or pool.router or pool.first
  if m.options.serverId and m.options.serverId ~= serverId and t ~= W.INFORM then return nil end      -- the client picked another server
  local function reply(typ, ip, leaseTime)
    return { op = 2, xid = m.xid, broadcast = m.broadcast, ciaddr = (typ == W.ACK and t == W.INFORM) and m.ciaddr or 0, yiaddr = ip or 0, siaddr = serverId, giaddr = m.giaddr, chaddr = mac,
      options = replyOptions(pool, serverId, typ, leaseTime or pool.lease), hops = 0 }
  end
  if t == W.DISCOVER then
    self.stats.discover = self.stats.discover + 1
    local ip = self:choose(pool, mac, m.options.requestedIp)
    if not ip then return nil end
    self.offers[mac] = { ip = ip, expires = now(self) + M.OFFER_HOLD }
    self.stats.offer = self.stats.offer + 1
    return reply(W.OFFER, ip), pool
  elseif t == W.REQUEST then
    self.stats.request = self.stats.request + 1
    local wanted = m.options.requestedIp or (m.ciaddr ~= 0 and m.ciaddr) or nil
    local nak = function(why)
      self.stats.nak = self.stats.nak + 1
      local r = reply(W.NAK, 0)
      r.options = { type = W.NAK, serverId = serverId, message = why }
      r.broadcast = true
      return r
    end
    if not wanted then return nak("no address requested") end
    if not B.inNet(wanted, pool.net, pool.plen) then return nak("wrong network") end
    local reserved = pool.reservations[mac]
    if reserved and reserved ~= wanted then return nak("address is reserved for another computer") end
    if taken(self, pool, wanted, mac) then return nak("address not available") end
    if not reserved and (wanted < pool.first or wanted > pool.last) then return nak("address outside the pool") end
    self.leases[mac] = { ip = wanted, expires = now(self) + pool.lease, pool = pool.name }
    self.offers[mac] = nil
    self:save()
    self.stats.ack = self.stats.ack + 1
    local r = reply(W.ACK, wanted)
    if m.ciaddr ~= 0 then r.broadcast = false end
    return r, pool
  elseif t == W.RELEASE then
    self.stats.release = self.stats.release + 1
    local l = self.leases[mac]
    if l and l.ip == m.ciaddr then self.leases[mac] = nil self:save() end
    return nil
  elseif t == W.DECLINE then
    self.stats.decline = self.stats.decline + 1
    local ip = m.options.requestedIp
    if ip then self.bad[ip] = now(self) + M.DECLINE_HOLD end
    self.offers[mac] = nil
    return nil
  elseif t == W.INFORM then
    self.stats.inform = self.stats.inform + 1
    local r = reply(W.ACK, 0, 0)
    r.options.leaseTime, r.options.renewalTime, r.options.rebindingTime = nil, nil, nil
    return r, pool
  end
  return nil
end

--- Active leases: list of { mac, ip, expires, pool }.
function Server:active()
  local out, t = {}, now(self)
  for mac, l in pairs(self.leases) do
    if l.expires > t then out[#out + 1] = { mac = mac, ip = l.ip, expires = l.expires, pool = l.pool } end
  end
  table.sort(out, function(a, b) return a.ip < b.ip end)
  return out
end

--- Run the server: receive on port 67, answer on the interface the request came from. Blocks forever (or until `self.stop`).
function Server:serve()
  local stack = self.stack
  local u = socket.udp(stack)
  u:setoption("broadcast", true)
  local ok, err = u:bind(nil, W.SERVER_PORT)
  if not ok then return nil, err end
  self.socket = u
  while not self.stop do
    local data, ip, port, info = u:receivefrom(1)
    if data then
      local m = W.decode(data)
      if m and m.op == 1 then
        local reply, pool = self:handle(m, info.iface)
        if reply then self:send(reply, info.iface, ip, port, m) end
      end
    end
  end
  u:close()
end

function Server:send(reply, ifname, clientIp, clientPort, request)
  local stack = self.stack
  local iface = stack.ifaces[ifname]
  local bytes = W.encode(reply)
  local u = self.socket
  local src = iface and iface.addrs[1] and iface.addrs[1].ip
  if request.giaddr ~= 0 then
    -- via a relay: unicast to the relay agent on the server port
    u:sendto(bytes, B.ipStr(request.giaddr), W.SERVER_PORT, { src = src })
  elseif reply.broadcast or reply.yiaddr == 0 or request.ciaddr == 0 and request.broadcast then
    u:sendto(bytes, "255.255.255.255", W.CLIENT_PORT, { iface = ifname, src = src })
  else
    if reply.yiaddr ~= 0 then stack:addNeighbour(iface, reply.yiaddr, request.chaddr) end
    u:sendto(bytes, B.ipStr(reply.yiaddr ~= 0 and reply.yiaddr or request.ciaddr), W.CLIENT_PORT, { iface = ifname, src = src })
  end
end

return M
