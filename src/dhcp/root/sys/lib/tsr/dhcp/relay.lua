-- SPDX-License-Identifier: AGPL-3.0-or-later
-- A DHCP relay agent (RFC 3046 in spirit): broadcasts do not cross routers, so a router that sits between clients and a DHCP server passes the
-- clients' requests to the server as unicast (adding its own address on the client's network as giaddr, so the server knows which pool to use) and
-- hands the server's answers back to the client.
--   relay.new(stack, { interfaces = { "eth0" }, servers = { "10.0.0.1" } }):run()
local B = require("tsr.inet.bytes")
local socket = require("tsr.inet.socket")
local W = require("tsr.dhcp.wire")

local M = {}
local Relay = {}
Relay.__index = Relay

M.MAX_HOPS = 4

function M.new(stack, cfg)
  local self = setmetatable({ stack = stack, cfg = cfg, servers = {}, ifaces = {}, stats = { requests = 0, replies = 0, dropped = 0 } }, Relay)
  for _, s in ipairs(cfg.servers or {}) do self.servers[#self.servers + 1] = B.ip(s) end
  for _, n in ipairs(cfg.interfaces or {}) do self.ifaces[n] = true end
  return self
end

function Relay:ifaceByAddress(ip)
  for _, i in ipairs(self.stack.ifaceList) do
    for _, a in ipairs(i.addrs) do if a.ip == ip then return i end end
  end
end

function Relay:handle(data, srcIp, info)
  local m = W.decode(data)
  if not m then return end
  local stack = self.stack
  if m.op == 1 then
    -- from a client (or another relay): only on the interfaces we serve
    if not self.ifaces[info.iface] and m.giaddr == 0 then return end
    if m.hops >= M.MAX_HOPS then self.stats.dropped = self.stats.dropped + 1 return end
    local iface = stack.ifaces[info.iface]
    if m.giaddr == 0 then m.giaddr = iface.addrs[1].ip end
    m.hops = m.hops + 1
    self.stats.requests = self.stats.requests + 1
    local bytes = W.encode(m)
    for _, server in ipairs(self.servers) do
      self.socket:sendto(bytes, B.ipStr(server), W.SERVER_PORT, { src = m.giaddr })
    end
  elseif m.op == 2 then
    local iface = self:ifaceByAddress(m.giaddr)
    if not iface then return end
    self.stats.replies = self.stats.replies + 1
    m.hops = 0
    local bytes = W.encode(m)
    local src = m.giaddr
    if m.broadcast or m.yiaddr == 0 then
      self.socket:sendto(bytes, "255.255.255.255", W.CLIENT_PORT, { iface = iface.name, src = src })
    else
      stack:addNeighbour(iface, m.yiaddr, m.chaddr)
      self.socket:sendto(bytes, B.ipStr(m.yiaddr), W.CLIENT_PORT, { iface = iface.name, src = src })
    end
  end
end

function Relay:run()
  local u = socket.udp(self.stack)
  u:setoption("broadcast", true)
  local ok, err = u:bind(nil, W.SERVER_PORT)
  if not ok then return nil, err end
  self.socket = u
  while not self.stop do
    local data, ip, port, info = u:receivefrom(1)
    if data then self:handle(data, B.ip(ip), info) end
  end
  u:close()
end

return M
