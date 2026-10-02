-- SPDX-License-Identifier: AGPL-3.0-or-later
-- ICMP (RFC 792): echo (ping), destination unreachable, time exceeded. Errors that name a TCP or UDP packet are passed on to the transport
-- layer (stack.icmpHandlers[proto]). `probe` sends one echo with a chosen TTL, which is all ping and traceroute need.
local B = require("tsr.inet.bytes")
local W = require("tsr.inet.wire")

local M = {}

function M.attach(stack)
  stack.protocols[W.PROTO_ICMP] = M.input
  stack.echoWaiters = {}
  stack.icmpHandlers = stack.icmpHandlers or {}
  stack.pingId = stack.random(65535)
  stack.pingSeq = 0
end

--- The packet that an ICMP error quotes: returns { proto, src, dst, ihl, transport (first 8 bytes) } or nil.
local function quoted(data)
  if #data < 20 then return nil end
  local vi = data:byte(1)
  if math.floor(vi / 16) ~= 4 then return nil end
  local ihl = (vi % 16) * 4
  if #data < ihl then return nil end
  return { proto = data:byte(10), src = B.rd32(data, 13), dst = B.rd32(data, 17), ihl = ihl, transport = data:sub(ihl + 1) }
end
M.quoted = quoted

function M.input(stack, iface, pkt)
  local m, err = W.icmpDecode(pkt.payload)
  if not m then stack:count("icmp", "inErrors") return end
  stack:count("icmp", "inMsgs")
  local t = m.type
  if t == W.ICMP_ECHO then
    local toBroadcast = pkt.dst == B.BROADCAST or stack:isBroadcastFor(iface, pkt.dst)
    if toBroadcast and not stack.sysctl.icmpEchoBroadcast then return end
    stack:count("icmp", "outEchoReps")
    local src = (not toBroadcast) and pkt.dst or nil
    stack:ipSend({ dst = pkt.src, src = src, proto = W.PROTO_ICMP, payload = W.icmpEncode({ type = W.ICMP_ECHO_REPLY, rest = m.rest, data = m.data }) })
  elseif t == W.ICMP_ECHO_REPLY then
    local key = m.id .. ":" .. m.seq
    local w = stack.echoWaiters[key]
    if w then
      w.result = { ok = true, from = pkt.src, rtt = stack.clock() - w.sent, ttl = pkt.ttl, bytes = #m.data, seq = m.seq }
      stack.echoWaiters[key] = nil
      stack:wake()
    end
  elseif t == W.ICMP_UNREACH or t == W.ICMP_TIME_EXCEEDED or t == W.ICMP_REDIRECT then
    local q = quoted(m.data)
    if not q then return end
    stack:count("icmp", t == W.ICMP_UNREACH and "inDestUnreachs" or "inTimeExcds")
    if q.proto == W.PROTO_ICMP and #q.transport >= 8 and q.transport:byte(1) == W.ICMP_ECHO then
      local id, seq = B.rd16(q.transport, 5), B.rd16(q.transport, 7)
      local w = stack.echoWaiters[id .. ":" .. seq]
      if w then
        w.result = { ok = false, from = pkt.src, rtt = stack.clock() - w.sent, seq = seq,
          reason = t == W.ICMP_TIME_EXCEEDED and "ttl exceeded" or "unreachable", code = m.code, kind = t == W.ICMP_TIME_EXCEEDED and "ttl" or "unreach" }
        stack.echoWaiters[id .. ":" .. seq] = nil
        stack:wake()
      end
    else
      local h = stack.icmpHandlers[q.proto]
      if h then h(stack, { type = t, code = m.code, from = pkt.src, rest = m.rest }, q) end
    end
  end
end

--- Send one echo request and wait for the answer. opts: ttl, size (payload bytes, 32), timeout (2), df, src, id, seq.
--- Returns { ok = true, from, rtt, ttl, bytes } | { ok = false, reason = "timeout" | "ttl exceeded" | "unreachable", from } | nil + error.
function M.probe(stack, dst, opts)
  opts = opts or {}
  local ip = B.ip(dst)
  if not ip then
    local why
    ip, why = stack:resolve(dst, opts.timeout)
    if not ip then return nil, why end
  end
  stack.pingSeq = (stack.pingSeq + 1) % 65536
  local id, seq = opts.id or stack.pingId, opts.seq or stack.pingSeq
  local data = string.rep("tessera!", math.ceil((opts.size or 32) / 8)):sub(1, opts.size or 32)
  local payload = W.icmpEncode({ type = W.ICMP_ECHO, rest = B.u16(id) .. B.u16(seq), data = data })
  local w = { sent = stack.clock() }
  stack.echoWaiters[id .. ":" .. seq] = w
  local ok, err = stack:ipSend({ dst = ip, src = opts.src, proto = W.PROTO_ICMP, payload = payload, ttl = opts.ttl, df = opts.df })
  stack:count("icmp", "outEchos")
  if not ok then stack.echoWaiters[id .. ":" .. seq] = nil return nil, err end
  stack.wait(function() return w.result ~= nil end, opts.timeout or 2)
  stack.echoWaiters[id .. ":" .. seq] = nil
  return w.result or { ok = false, reason = "timeout" }
end

return M
