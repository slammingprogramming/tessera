-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The DHCP client (RFC 2131): asks for an address on an interface, applies the lease (address, default route, DNS servers, search domain, MTU,
-- time servers) and keeps it alive: renew at T1 (half the lease) with the server, rebind at T2 (7/8) with anybody, start again when it runs out.
--   client.run(stack, "eth0", opts)      blocks forever (run it in its own process or thread); opts: hostname, onBound(lease), onLost(), tries
--   client.acquire(stack, "eth0", opts)  one DISCOVER/OFFER/REQUEST/ACK exchange; returns a lease table or nil + reason
local B = require("tsr.inet.bytes")
local socket = require("tsr.inet.socket")
local W = require("tsr.dhcp.wire")

local M = {}

M.RETRY_DELAYS = { 4, 8, 16, 32 }
M.DECLINE_WAIT = 10

local function waitFor(stack, seconds)
  stack.wait(function() return false end, seconds)
end

local function newSocket(stack, ifname)
  local u = socket.udp(stack)
  u:setoption("broadcast", true)
  u:setoption("reuse", true)
  u:setoption("iface", ifname)
  local ok, err = u:bind(nil, W.CLIENT_PORT)
  if not ok then return nil, err end
  return u
end

local function send(stack, u, ifname, m, dst, src)
  local data = W.encode(m)
  return u:sendto(data, dst or "255.255.255.255", W.SERVER_PORT, { iface = (dst == nil or dst == "255.255.255.255") and ifname or nil, src = src or 0 })
end

local function xidFor(stack) return stack.random(65535) * 65536 + stack.random(65535) end

local function request(stack, ifname, mac, xid, opts, fields)
  local o = { type = fields.type, paramList = "\1\3\6\15\26\28\42\51\58\59\119" }
  if opts.hostname then o.hostname = opts.hostname end
  for k, v in pairs(fields.options or {}) do o[k] = v end
  return { op = 1, xid = xid, secs = 0, broadcast = true, ciaddr = fields.ciaddr, chaddr = mac, options = o }
end

--- Wait up to `timeout` seconds for a message of one of `types` with our xid.
local function await(stack, u, xid, types, timeout)
  local deadline = stack.clock() + timeout
  while true do
    local left = deadline - stack.clock()
    if left <= 0 then return nil end
    local data, ip, port, info = u:receivefrom(left)
    if not data then return nil end
    local m = W.decode(data)
    if m and m.op == 2 and m.xid == xid and types[m.options.type] then return m, ip end
  end
end

--- Turn an ACK into a lease table.
local function leaseFrom(m, now)
  local o = m.options
  local t = o.leaseTime or 3600
  return {
    address = m.yiaddr, mask = o.subnetMask or B.mask(24), routers = o.routers or {}, dns = o.dns or {}, domain = o.domain, mtu = o.mtu, ntp = o.ntp or {},
    server = o.serverId, leaseTime = t, t1 = o.renewalTime or t / 2, t2 = o.rebindingTime or t * 7 / 8, obtained = now, searchList = o.searchList,
  }
end

--- One full exchange. opts: hostname, tries (number of DISCOVER rounds), probe (check the offered address with ARP, default true).
function M.acquire(stack, ifname, opts)
  opts = opts or {}
  local iface = stack.ifaces[ifname]
  if not iface then return nil, "no such interface" end
  local u, err = newSocket(stack, ifname)
  if not u then return nil, err end
  iface.acceptAny = true
  local mac = iface.mac
  local result, reason
  for round = 1, opts.tries or (#M.RETRY_DELAYS + 1) do
    local xid = xidFor(stack)
    send(stack, u, ifname, request(stack, ifname, mac, xid, opts, { type = W.DISCOVER, ciaddr = 0 }))
    local delay = M.RETRY_DELAYS[round] or M.RETRY_DELAYS[#M.RETRY_DELAYS]
    local offer = await(stack, u, xid, { [W.OFFER] = true }, delay)
    if offer then
      local want = { requestedIp = offer.yiaddr, serverId = offer.options.serverId }
      -- address conflict detection (RFC 5227 style probe)
      local conflict = false
      if opts.probe ~= false then
        local before = stack.onArp
        stack.onArp = function(i, a) if a.spa == offer.yiaddr then conflict = true end if before then before(i, a) end end
        stack:arpRequest(iface, offer.yiaddr, 0)
        waitFor(stack, 0.5)
        stack.onArp = before
      end
      if conflict then
        send(stack, u, ifname, request(stack, ifname, mac, xid, opts, { type = W.DECLINE, ciaddr = 0, options = want }))
        waitFor(stack, M.DECLINE_WAIT)
      else
        send(stack, u, ifname, request(stack, ifname, mac, xid, opts, { type = W.REQUEST, ciaddr = 0, options = want }))
        local reply = await(stack, u, xid, { [W.ACK] = true, [W.NAK] = true }, 3)
        if reply and reply.options.type == W.ACK then
          result = leaseFrom(reply, stack.clock())
          break
        elseif reply then
          reason = "the server refused: " .. tostring(reply.options.message or "NAK")
        else
          reason = "no answer to the request"
        end
      end
    else
      reason = "no DHCP server answered"
    end
  end
  u:close()
  iface.acceptAny = nil
  if not result then return nil, reason end
  return result
end

--- Put a lease into effect on the stack.
function M.apply(stack, ifname, lease)
  local iface = stack.ifaces[ifname]
  local plen = B.maskToPrefix(B.ipStr(lease.mask)) or 24
  stack:clearAddresses(ifname)
  stack:removeRoutes(function(r) return r.iface == ifname and r.proto == "dhcp" end)
  stack:setAddress(ifname, lease.address, plen)
  if lease.mtu and lease.mtu >= 576 and lease.mtu <= 1500 then iface.mtu = lease.mtu end
  for i, gw in ipairs(lease.routers) do stack:addRoute("default", gw, { iface = ifname, proto = "dhcp", metric = 10 + i }) end
  stack.dnsServers = {}
  for _, d in ipairs(lease.dns) do stack.dnsServers[#stack.dnsServers + 1] = d end
  if lease.domain then stack.searchDomains = { lease.domain } end
  stack.ntpServers = lease.ntp
  iface.lease = lease
end

function M.remove(stack, ifname)
  stack:clearAddresses(ifname)
  stack:removeRoutes(function(r) return r.iface == ifname and r.proto == "dhcp" end)
  local iface = stack.ifaces[ifname]
  if iface then iface.lease = nil end
end

--- Renew (unicast to the server) or rebind (broadcast). Returns the new lease or nil.
local function renew(stack, u, ifname, lease, broadcast, opts)
  local iface = stack.ifaces[ifname]
  local xid = xidFor(stack)
  local m = request(stack, ifname, iface.mac, xid, opts, { type = W.REQUEST, ciaddr = lease.address })
  m.broadcast = false
  if broadcast then send(stack, u, ifname, m, nil, lease.address)
  else u:sendto(W.encode(m), B.ipStr(lease.server), W.SERVER_PORT, { src = lease.address }) end
  local reply = await(stack, u, xid, { [W.ACK] = true, [W.NAK] = true }, 3)
  if reply and reply.options.type == W.ACK then return leaseFrom(reply, stack.clock()), false end
  return nil, reply ~= nil
end

--- Keep an interface configured forever.
function M.run(stack, ifname, opts)
  opts = opts or {}
  stack.dhcpWanted = stack.dhcpWanted or {}
  while stack.ifaces[ifname] do
    local lease, why = M.acquire(stack, ifname, opts)
    if not lease then
      if opts.onFail then opts.onFail(why) end
      waitFor(stack, opts.retryAfter or 30)
    else
      M.apply(stack, ifname, lease)
      if opts.onBound then opts.onBound(lease) end
      local u = newSocket(stack, ifname)
      local lost = false
      while not lost and stack.ifaces[ifname] do
        local t0 = lease.obtained
        waitFor(stack, math.max(0, t0 + lease.t1 - stack.clock()))
        local new, nak = renew(stack, u, ifname, lease, false, opts)
        while not new and not nak and stack.clock() < t0 + lease.t2 do
          waitFor(stack, math.max(1, (t0 + lease.t2 - stack.clock()) / 2))
          new, nak = renew(stack, u, ifname, lease, false, opts)
        end
        while not new and not nak and stack.clock() < t0 + lease.leaseTime do
          new, nak = renew(stack, u, ifname, lease, true, opts)
          if not new then waitFor(stack, math.max(1, math.min(10, (t0 + lease.leaseTime - stack.clock()) / 2))) end
        end
        if new then
          if new.address ~= lease.address then M.apply(stack, ifname, new) else stack.ifaces[ifname].lease = new end
          lease = new
        else
          lost = true
        end
      end
      u:close()
      M.remove(stack, ifname)
      if opts.onLost then opts.onLost() end
    end
  end
end

--- Say goodbye: tell the server we no longer need the address, and take it down.
function M.release(stack, ifname)
  local iface = stack.ifaces[ifname]
  local lease = iface and iface.lease
  if not lease then return false end
  local u = newSocket(stack, ifname)
  if u then
    local m = request(stack, ifname, iface.mac, xidFor(stack), {}, { type = W.RELEASE, ciaddr = lease.address, options = { serverId = lease.server } })
    m.broadcast = false
    u:sendto(W.encode(m), B.ipStr(lease.server), W.SERVER_PORT, { src = lease.address })
    u:close()
  end
  M.remove(stack, ifname)
  return true
end

return M
