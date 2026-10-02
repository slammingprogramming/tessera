-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Connection tracking: remembers every flow that passes through (or to or from) this computer, in both directions, so that a stateful firewall can
-- tell "a reply to something we started" from "somebody knocking", and so that NAT can translate the packets of a flow consistently.
--   flow  = (protocol, source, source port, destination, destination port); ICMP echo uses the identifier as the port
--   state = NEW (no reply yet), ESTABLISHED (a reply was seen), RELATED (an ICMP error about a known flow), INVALID (a TCP packet that fits no flow)
-- Also here: rewriting a packet's addresses and ports and repairing its checksums (what NAT needs).
local B = require("tsr.inet.bytes")
local W = require("tsr.inet.wire")

local M = {}
local Table = {}
Table.__index = Table

M.TIMEOUTS = {
  udpNew = 30, udpStream = 120, icmp = 30, other = 60,
  tcpSynSent = 30, tcpSynRecv = 30, tcpEstablished = 3600, tcpFin = 30, tcpTimeWait = 15, tcpClose = 5,
}
M.MAX_ENTRIES = 2048

local function key(proto, src, sport, dst, dport) return proto .. ":" .. src .. ":" .. sport .. ">" .. dst .. ":" .. dport end

local function has(flags, bit) return flags % (bit * 2) >= bit end

--- The tuple of a parsed IP packet (nil for fragments without ports and other things we cannot follow). Returns { proto, src, sport, dst, dport, flags, icmpType }.
function M.tuple(pkt)
  local p = pkt.proto
  local pl = pkt.payload
  if pkt.frag and pkt.frag > 0 then return nil end
  if p == W.PROTO_TCP and #pl >= 20 then
    return { proto = p, src = pkt.src, dst = pkt.dst, sport = B.rd16(pl, 1), dport = B.rd16(pl, 3), flags = pl:byte(14) % 64 }
  elseif p == W.PROTO_UDP and #pl >= 8 then
    return { proto = p, src = pkt.src, dst = pkt.dst, sport = B.rd16(pl, 1), dport = B.rd16(pl, 3) }
  elseif p == W.PROTO_ICMP and #pl >= 8 then
    local t = pl:byte(1)
    if t == W.ICMP_ECHO or t == W.ICMP_ECHO_REPLY then
      local id = B.rd16(pl, 5)
      -- an echo request flows with the identifier as source port; its reply has the same identifier
      return { proto = p, src = pkt.src, dst = pkt.dst, sport = id, dport = id, icmpType = t }
    end
    return { proto = p, src = pkt.src, dst = pkt.dst, sport = 0, dport = 0, icmpType = t, error = true }
  end
  return { proto = p, src = pkt.src, dst = pkt.dst, sport = 0, dport = 0 }
end

--- Rewrite addresses and ports of `pkt` in place (any of src, dst, sport, dport) and fix the checksums. Sets pkt.dirty.
function M.rewrite(pkt, c)
  local pl = pkt.payload
  if c.src then pkt.src = c.src end
  if c.dst then pkt.dst = c.dst end
  local p = pkt.proto
  if p == W.PROTO_TCP and #pl >= 20 then
    if c.sport then pl = B.u16(c.sport) .. pl:sub(3) end
    if c.dport then pl = pl:sub(1, 2) .. B.u16(c.dport) .. pl:sub(5) end
    pl = pl:sub(1, 16) .. "\0\0" .. pl:sub(19)
    pl = pl:sub(1, 16) .. B.u16(B.checksum(pl, W.pseudo(pkt.src, pkt.dst, p, #pl))) .. pl:sub(19)
  elseif p == W.PROTO_UDP and #pl >= 8 then
    if c.sport then pl = B.u16(c.sport) .. pl:sub(3) end
    if c.dport then pl = pl:sub(1, 2) .. B.u16(c.dport) .. pl:sub(5) end
    pl = pl:sub(1, 6) .. "\0\0" .. pl:sub(9)
    local csum = B.checksum(pl, W.pseudo(pkt.src, pkt.dst, p, #pl))
    if csum == 0 then csum = 65535 end
    pl = pl:sub(1, 6) .. B.u16(csum) .. pl:sub(9)
  elseif p == W.PROTO_ICMP and #pl >= 8 and c.sport and (pl:byte(1) == W.ICMP_ECHO or pl:byte(1) == W.ICMP_ECHO_REPLY) then
    pl = pl:sub(1, 4) .. B.u16(c.sport) .. pl:sub(7)
    pl = pl:sub(1, 2) .. "\0\0" .. pl:sub(5)
    pl = pl:sub(1, 2) .. B.u16(B.checksum(pl)) .. pl:sub(5)
  end
  pkt.payload = pl
  pkt.dirty = true
end

---------------------------------------------------------------------------------------------------------------------
-- The table
---------------------------------------------------------------------------------------------------------------------

function M.new(stack)
  return setmetatable({ stack = stack, byOrig = {}, byReply = {}, count = 0, stats = { created = 0, evicted = 0, invalid = 0, expired = 0 } }, Table)
end

local function now(self) return self.stack.clock() end

--- Find the flow of a tuple: returns entry, direction ("orig" | "reply") or nil.
function Table:lookup(t)
  local k = key(t.proto, t.src, t.sport, t.dst, t.dport)
  local e = self.byOrig[k]
  if e then return e, "orig" end
  e = self.byReply[k]
  if e then return e, "reply" end
  return nil
end

--- A new (unconfirmed) entry for the first packet of a flow.
function Table:track(t)
  return { proto = t.proto, orig = { src = t.src, sport = t.sport, dst = t.dst, dport = t.dport }, reply = { src = t.dst, sport = t.dport, dst = t.src, dport = t.sport },
    state = "NEW", created = now(self), expires = now(self) + 30, packets = 0, bytes = 0, tcp = "NONE", confirmed = false }
end

function Table:confirm(e)
  if e.confirmed then return true end
  local ko = key(e.proto, e.orig.src, e.orig.sport, e.orig.dst, e.orig.dport)
  local kr = key(e.proto, e.reply.src, e.reply.sport, e.reply.dst, e.reply.dport)
  if self.byOrig[ko] or self.byReply[kr] or self.byOrig[kr] or self.byReply[ko] then return false end          -- a clash (NAT port reuse)
  if self.count >= M.MAX_ENTRIES then self:evictOldest() end
  e.ko, e.kr = ko, kr
  self.byOrig[ko] = e
  self.byReply[kr] = e
  e.confirmed = true
  self.count = self.count + 1
  self.stats.created = self.stats.created + 1
  return true
end

function Table:remove(e)
  if not e.confirmed then return end
  self.byOrig[e.ko] = nil
  self.byReply[e.kr] = nil
  e.confirmed = false
  self.count = self.count - 1
end

function Table:evictOldest()
  local oldest
  for _, e in pairs(self.byOrig) do if not oldest or e.expires < oldest.expires then oldest = e end end
  if oldest then self:remove(oldest) self.stats.evicted = self.stats.evicted + 1 end
end

--- Is a reply tuple free (for NAT port allocation)?
function Table:replyFree(proto, src, sport, dst, dport)
  local k = key(proto, src, sport, dst, dport)
  return not self.byReply[k] and not self.byOrig[k]
end

local T = M.TIMEOUTS

--- Update the entry with a packet that belongs to it. dir: "orig" | "reply".
function Table:update(e, t, dir, len)
  local n = now(self)
  e.packets = e.packets + 1
  e.bytes = e.bytes + (len or 0)
  if dir == "reply" then e.replied = true end
  if e.proto == W.PROTO_TCP then
    local f = t.flags or 0
    if has(f, W.RST) then e.tcp = "CLOSE" e.expires = n + T.tcpClose
    elseif has(f, W.SYN) and has(f, W.ACK) and dir == "reply" then e.tcp = "SYN_RECV" e.expires = n + T.tcpSynRecv
    elseif has(f, W.SYN) then e.tcp = "SYN_SENT" e.expires = n + T.tcpSynSent
    elseif has(f, W.FIN) then
      e.finDirs = e.finDirs or {}
      e.finDirs[dir] = true
      if e.finDirs.orig and e.finDirs.reply then e.tcp = "TIME_WAIT" e.expires = n + T.tcpTimeWait
      else e.tcp = "FIN_WAIT" e.expires = n + T.tcpFin end
    elseif e.tcp == "SYN_RECV" and dir == "orig" and has(f, W.ACK) then e.tcp = "ESTABLISHED" e.expires = n + T.tcpEstablished
    elseif e.tcp == "ESTABLISHED" then e.expires = n + T.tcpEstablished
    elseif e.tcp == "NONE" then e.tcp = "ESTABLISHED" e.expires = n + T.tcpEstablished
    end
  elseif e.proto == W.PROTO_UDP then
    e.expires = n + (e.replied and T.udpStream or T.udpNew)
  elseif e.proto == W.PROTO_ICMP then
    e.expires = n + T.icmp
    -- an echo request and its reply are one exchange: the entry ends with the reply (like Linux), so the next request is NEW again
    if dir == "reply" and not e.error then e.state = "ESTABLISHED" self:remove(e) return end
  else
    e.expires = n + T.other
  end
  e.state = e.replied and "ESTABLISHED" or "NEW"
end

--- Drop expired flows.
function Table:gc()
  local n = now(self)
  for _, e in pairs(self.byOrig) do
    if e.expires <= n then self:remove(e) self.stats.expired = self.stats.expired + 1 end
  end
end

function Table:list()
  local out = {}
  for _, e in pairs(self.byOrig) do out[#out + 1] = e end
  table.sort(out, function(a, b) return a.created < b.created end)
  return out
end

--- How many flows start at `src` (for connection limits).
function Table:countFrom(src)
  local n = 0
  for _, e in pairs(self.byOrig) do if e.orig.src == src then n = n + 1 end end
  return n
end

return M
