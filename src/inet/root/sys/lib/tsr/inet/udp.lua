-- SPDX-License-Identifier: AGPL-3.0-or-later
-- UDP (RFC 768): datagram sockets. A socket is a table; use tsr.inet.socket for the friendly API.
local B = require("tsr.inet.bytes")
local W = require("tsr.inet.wire")

local M = {}

M.QUEUE_LIMIT = 64

function M.attach(stack)
  stack.protocols[W.PROTO_UDP] = M.input
  stack.udpSockets = {}
  stack.icmpHandlers[W.PROTO_UDP] = M.icmpError
  stack.nextUdpPort = 49152 + stack.random(1000)
end

function M.new(stack)
  local s = { stack = stack, kind = "udp", queue = {}, laddr = 0, lport = nil, closed = false }
  return s
end

--- Is (addr, port) taken for socket `me`? Two sockets may share a port when both set the reuse option, or when they are tied to different interfaces.
local function inUse(stack, addr, port, me)
  for _, s in ipairs(stack.udpSockets) do
    if s ~= me and s.lport == port and (s.laddr == 0 or addr == 0 or s.laddr == addr) then
      local shared = me and ((s.reuse and me.reuse) or (s.iface and me.iface and s.iface ~= me.iface))
      if not shared then return true end
    end
  end
  return false
end

local function ephemeral(stack)
  for _ = 1, 20000 do
    stack.nextUdpPort = stack.nextUdpPort + 1
    if stack.nextUdpPort > 65535 then stack.nextUdpPort = 49152 end
    if not inUse(stack, 0, stack.nextUdpPort) then return stack.nextUdpPort end
  end
  return nil
end

--- Bind to an address (0 = any) and port (0 or nil = pick one).
function M.bind(s, addr, port)
  local stack = s.stack
  addr = addr and B.ip(addr) or 0
  if not port or port == 0 then
    port = ephemeral(stack)
    if not port then return nil, "no free port" end
  elseif inUse(stack, addr, port, s) then
    return nil, "address in use"
  end
  if addr ~= 0 and not stack:isLocal(addr) then return nil, "cannot assign requested address" end
  s.laddr, s.lport = addr, port
  if not s.registered then stack.udpSockets[#stack.udpSockets + 1] = s s.registered = true end
  return true
end

function M.close(s)
  if s.closed then return end
  s.closed = true
  local list = s.stack.udpSockets
  for i, x in ipairs(list) do if x == s then table.remove(list, i) break end end
  s.stack:wake()
end

--- Send a datagram. opts: iface (send out of this interface), src (source address), ttl, tos.
function M.sendto(s, data, dst, dport, opts)
  opts = opts or {}
  local stack = s.stack
  if s.closed then return nil, "socket closed" end
  if not s.lport then local ok, err = M.bind(s, 0, 0) if not ok then return nil, err end end
  local ip = B.ip(dst)
  if not ip then return nil, "bad destination" end
  if ip == B.BROADCAST and not s.broadcast then return nil, "permission denied (set the broadcast option)" end
  local src = opts.src or (s.laddr ~= 0 and s.laddr) or nil
  local srcForChecksum = src
  if not srcForChecksum then
    local r = (opts.iface and stack:lookup(ip, opts.iface)) or stack:lookup(ip)
    if opts.iface and not r then
      local i = stack.ifaces[opts.iface]
      srcForChecksum = i and i.addrs[1] and i.addrs[1].ip or 0
    elseif r then
      srcForChecksum = stack:sourceFor(r, ip)
    elseif stack:isLocal(ip) then srcForChecksum = ip
    elseif ip == B.BROADCAST then
      local first
      for _, i in ipairs(stack.ifaceList) do if i.up and i.kind ~= "loopback" then first = i break end end
      srcForChecksum = first and first.addrs[1] and first.addrs[1].ip or 0
    else
      return nil, "network unreachable"
    end
  end
  local payload = W.udpEncode(srcForChecksum or 0, ip, s.lport, dport, data)
  stack:count("udp", "outDatagrams")
  return stack:ipSend({ dst = ip, src = srcForChecksum, proto = W.PROTO_UDP, payload = payload, iface = opts.iface or s.iface, ttl = opts.ttl or s.ttl, tos = opts.tos })
end

function M.input(stack, iface, pkt)
  local d, err = W.udpDecode(pkt.src, pkt.dst, pkt.payload)
  if not d then stack:count("udp", "inErrors") return end
  stack:count("udp", "inDatagrams")
  local isBcast = pkt.dst == B.BROADCAST or stack:isBroadcastFor(iface, pkt.dst)
  local delivered = false
  for _, s in ipairs(stack.udpSockets) do
    if s.lport == d.dport and (s.laddr == 0 or s.laddr == pkt.dst or (isBcast and s.laddr == 0)) and (not s.iface or s.iface == iface.name) then
      if not s.rport or (s.rport == d.sport and s.raddr == pkt.src) then
        if #s.queue < M.QUEUE_LIMIT then
          s.queue[#s.queue + 1] = { data = d.payload, src = pkt.src, sport = d.sport, dst = pkt.dst, iface = iface.name, ttl = pkt.ttl, broadcast = isBcast }
        else
          stack:count("udp", "rcvbufErrors")
        end
        delivered = true
        if not (s.reuse and isBcast) then break end
      end
    end
  end
  if delivered then stack:wake() return end
  stack:count("udp", "noPorts")
  if not isBcast then stack:icmpError(pkt, W.ICMP_UNREACH, W.UNREACH_PORT) end
end

--- ICMP unreachable about a datagram we sent: remember it for the connected socket.
function M.icmpError(stack, msg, q)
  if #q.transport < 4 then return end
  local sport, dport = B.rd16(q.transport, 1), B.rd16(q.transport, 3)
  for _, s in ipairs(stack.udpSockets) do
    if s.lport == sport and s.rport == dport and s.raddr == q.dst then
      s.err = msg.type == W.ICMP_UNREACH and (msg.code == W.UNREACH_PORT and "connection refused" or "unreachable") or "ttl exceeded"
      stack:wake()
    end
  end
end

--- Take the next datagram, waiting up to `timeout` seconds (nil = forever, 0 = do not wait). Returns the datagram table or nil + reason.
function M.receive(s, timeout)
  local stack = s.stack
  if #s.queue == 0 and not s.closed and not s.err then
    if timeout == 0 then return nil, "timeout" end
    stack.wait(function() return #s.queue > 0 or s.closed or s.err ~= nil end, timeout)
  end
  if #s.queue > 0 then return table.remove(s.queue, 1) end
  if s.err then local e = s.err s.err = nil return nil, e end
  if s.closed then return nil, "closed" end
  return nil, "timeout"
end

return M
