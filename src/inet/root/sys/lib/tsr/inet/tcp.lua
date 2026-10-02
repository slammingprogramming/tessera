-- SPDX-License-Identifier: AGPL-3.0-or-later
-- TCP (RFC 9293, the 793 successor): the connection state machine with SYN/FIN handshakes, sliding window, retransmission timer from
-- RFC 6298, slow start / congestion avoidance / fast retransmit and recovery in the style of RFC 5681 and NewReno (RFC 6582), zero-window
-- probing, out-of-order reassembly, RST handling and TIME-WAIT. Left out on purpose: window scaling, SACK, timestamps, urgent data and
-- delayed ACKs (every data segment is acknowledged at once, which suits a network whose round trip is measured in game ticks).
--
-- A connection is a table (a "TCB"). tsr.inet.socket wraps it in a friendlier API.
local B = require("tsr.inet.bytes")
local W = require("tsr.inet.wire")

local M = {}

local seqLt, seqLe, seqAdd, seqDiff = B.seqLt, B.seqLe, B.seqAdd, B.seqDiff
local FIN, SYN, RST, PSH, ACK = W.FIN, W.SYN, W.RST, W.PSH, W.ACK
local min, max, floor = math.min, math.max, math.floor

M.INIT_RTO = 1.0
M.MIN_RTO = 0.4
M.MAX_RTO = 30
M.SYN_RETRIES = 5
M.DATA_RETRIES = 8
M.TIME_WAIT = 8             -- seconds; the RFC says 2 x MSL (minutes) - a game does not need that long
M.BUFFER = 16384
M.INIT_CWND_SEGMENTS = 3
M.CLOCK_G = 0.05

local function has(flags, bit) return flags % (bit * 2) >= bit end
M.has = has

local STATES = { "CLOSED", "LISTEN", "SYN_SENT", "SYN_RCVD", "ESTABLISHED", "FIN_WAIT_1", "FIN_WAIT_2", "CLOSE_WAIT", "CLOSING", "LAST_ACK", "TIME_WAIT" }
M.STATES = STATES

function M.attach(stack)
  stack.protocols[W.PROTO_TCP] = M.input
  stack.tcpTable = {}
  stack.tcpListeners = {}
  stack.nextTcpPort = 49152 + stack.random(1000)
  stack.icmpHandlers[W.PROTO_TCP] = M.icmpError
end

local function key(laddr, lport, raddr, rport) return laddr .. ":" .. lport .. ":" .. raddr .. ":" .. rport end

local function newIss(stack)
  return (stack.random(65536) * 65536 + stack.random(65536) + floor(stack.clock() * 250000)) % B.TWO32
end

---------------------------------------------------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------------------------------------------------

local function advWindow(tcb)
  local space = tcb.rcvMax - tcb.rcvLen
  for _, o in ipairs(tcb.ooo) do space = space - #o.data end
  tcb.rcv_wnd = max(0, min(65535, space))
  return tcb.rcv_wnd
end

local function xmit(tcb, flags, seq, payload, withMss)
  local stack = tcb.stack
  local seg = {
    sport = tcb.lport, dport = tcb.rport, seq = seq, ack = has(flags, ACK) and tcb.rcv_nxt or 0, flags = flags,
    window = advWindow(tcb), payload = payload or "", mss = withMss and tcb.ourMss or nil,
  }
  tcb.lastAdvertised = tcb.rcv_nxt + tcb.rcv_wnd
  stack:count("tcp", "outSegs")
  return stack:ipSend({ src = tcb.laddr, dst = tcb.raddr, proto = W.PROTO_TCP, payload = W.tcpEncode(tcb.laddr, tcb.raddr, seg) })
end

local function sendAck(tcb) xmit(tcb, ACK, tcb.snd_nxt) end

--- A reset in answer to a segment that belongs to no connection (RFC 9293 3.10.7.1).
local function sendReset(stack, pkt, seg)
  if has(seg.flags, RST) then return end
  local len = #seg.payload + (has(seg.flags, SYN) and 1 or 0) + (has(seg.flags, FIN) and 1 or 0)
  local out
  if has(seg.flags, ACK) then
    out = { sport = seg.dport, dport = seg.sport, seq = seg.ack, ack = 0, flags = RST, window = 0 }
  else
    out = { sport = seg.dport, dport = seg.sport, seq = 0, ack = seqAdd(seg.seq, len), flags = RST + ACK, window = 0 }
  end
  stack:count("tcp", "outRsts")
  stack:ipSend({ src = pkt.dst, dst = pkt.src, proto = W.PROTO_TCP, payload = W.tcpEncode(pkt.dst, pkt.src, out) })
end

--- snd_max is the highest sequence number ever sent; snd_nxt can fall back below it after a timeout (go-back-N).
local function bump(tcb)
  if seqLt(tcb.snd_max, tcb.snd_nxt) then tcb.snd_max = tcb.snd_nxt end
end

local function armRtx(tcb)
  if not tcb.rtxAt then tcb.rtxAt = tcb.stack.clock() + tcb.rto end
end

local function restartRtx(tcb)
  tcb.rtxAt = tcb.stack.clock() + tcb.rto
end

local function setState(tcb, state)
  tcb.state = state
  tcb.stack:wake()
end

local function destroy(tcb, err)
  local stack = tcb.stack
  if err and not tcb.err then tcb.err = err end
  if tcb.state == "ESTABLISHED" or tcb.state == "CLOSE_WAIT" then stack:count("tcp", "estabResets") end
  tcb.rtxAt, tcb.persistAt, tcb.twAt = nil, nil, nil
  if tcb.k then stack.tcpTable[tcb.k] = nil end
  if tcb.parent then tcb.parent.pending = max(0, (tcb.parent.pending or 1) - 1) end
  if tcb.listening then stack.tcpListeners[tcb.lport .. ":" .. tcb.laddr] = nil end
  setState(tcb, "CLOSED")
end
M.destroy = destroy

--- Send as much new data as the windows allow, then the FIN when everything is out.
local function output(tcb)
  local st = tcb.state
  if st ~= "ESTABLISHED" and st ~= "CLOSE_WAIT" and st ~= "FIN_WAIT_1" and st ~= "CLOSING" and st ~= "LAST_ACK" then return end
  local stack = tcb.stack
  while true do
    local inflight = seqDiff(tcb.snd_nxt, tcb.snd_una)
    local wnd = min(tcb.snd_wnd, tcb.cwnd)
    local sentData = seqDiff(tcb.snd_nxt, tcb.sbase)
    local avail = max(0, #tcb.sendBuf - sentData)
    local room = wnd - inflight
    if avail > 0 and room > 0 and not tcb.finSent then
      local len = min(avail, room, tcb.mss)
      local nagle = (not tcb.noDelay) and len < tcb.mss and inflight > 0 and not tcb.finQueued
      if nagle then break end
      local flags = ACK + ((len == avail) and PSH or 0)
      xmit(tcb, flags, tcb.snd_nxt, tcb.sendBuf:sub(sentData + 1, sentData + len))
      tcb.snd_nxt = seqAdd(tcb.snd_nxt, len)
      bump(tcb)
      if not tcb.rttSeq then tcb.rttSeq, tcb.rttAt = tcb.snd_nxt, stack.clock() end
      armRtx(tcb)
      tcb.persistAt = nil
    elseif avail == 0 and tcb.finQueued and not tcb.finSent and (room > 0 or inflight == 0) then
      xmit(tcb, FIN + ACK, tcb.snd_nxt)
      tcb.finSeq = tcb.snd_nxt
      tcb.finSent = true
      tcb.snd_nxt = seqAdd(tcb.snd_nxt, 1)
      bump(tcb)
      armRtx(tcb)
    else
      if avail > 0 and tcb.snd_wnd == 0 and inflight == 0 and not tcb.persistAt then
        tcb.persistAt = stack.clock() + tcb.rto
        tcb.persistTries = 0
      end
      break
    end
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Creating connections
---------------------------------------------------------------------------------------------------------------------

local function newTcb(stack)
  return {
    stack = stack, state = "CLOSED", rcv_nxt = 0, irs = 0, ooo = {}, rcvQ = {}, rcvLen = 0, rcvMax = M.BUFFER, sendBuf = "", sendMax = M.BUFFER,
    snd_wnd = 0, snd_wl1 = 0, snd_wl2 = 0, rcv_wnd = M.BUFFER, mss = 536, peerMss = 536, ourMss = 536,
    cwnd = 536, ssthresh = 65535, dupacks = 0, rto = M.INIT_RTO, rtxCount = 0, finQueued = false, finSent = false, finRcvd = false,
    created = stack.clock(), noDelay = false, bytesIn = 0, bytesOut = 0,
  }
end

local function initSend(tcb, iss)
  tcb.iss = iss
  tcb.snd_una = iss
  tcb.snd_nxt = iss
  tcb.snd_max = iss
  tcb.sbase = seqAdd(iss, 1)
end

local function initCwnd(tcb)
  tcb.cwnd = M.INIT_CWND_SEGMENTS * tcb.mss
end

local function allocPort(stack, laddr)
  for _ = 1, 20000 do
    stack.nextTcpPort = stack.nextTcpPort + 1
    if stack.nextTcpPort > 65535 then stack.nextTcpPort = 49152 end
    local p = stack.nextTcpPort
    if not stack.tcpListeners[p .. ":0"] and not stack.tcpListeners[p .. ":" .. laddr] then
      local busy = false
      for _, t in pairs(stack.tcpTable) do if t.lport == p then busy = true break end end
      if not busy then return p end
    end
  end
  return nil
end

--- Open a connection (active open). opts: src (address), sport, noDelay. Returns the TCB (state SYN_SENT) or nil + reason.
function M.connect(stack, raddr, rport, opts)
  opts = opts or {}
  raddr = B.ip(raddr)
  if not raddr then return nil, "bad address" end
  local laddr = opts.src and B.ip(opts.src)
  local mtu = 1500
  if stack:isLocal(raddr) then
    laddr = laddr or raddr
    mtu = 1500
  else
    local r = stack:lookup(raddr)
    if not r then return nil, "network unreachable" end
    laddr = laddr or stack:sourceFor(r, raddr)
    mtu = stack.ifaces[r.iface].mtu
  end
  if not laddr then return nil, "no source address" end
  local sport = opts.sport or allocPort(stack, laddr)
  if not sport then return nil, "no free port" end
  local k = key(laddr, sport, raddr, rport)
  if stack.tcpTable[k] then return nil, "address in use" end
  local tcb = newTcb(stack)
  tcb.laddr, tcb.lport, tcb.raddr, tcb.rport, tcb.k = laddr, sport, raddr, rport, k
  tcb.ourMss = min(mtu - 40, 1460)
  tcb.mss = min(tcb.ourMss, 536)
  tcb.noDelay = opts.noDelay or false
  initCwnd(tcb)
  initSend(tcb, newIss(stack))
  stack.tcpTable[k] = tcb
  stack:count("tcp", "activeOpens")
  setState(tcb, "SYN_SENT")
  stack:run(function()
    xmit(tcb, SYN, tcb.iss, nil, true)
    tcb.snd_nxt = seqAdd(tcb.iss, 1)
    bump(tcb)
    tcb.synAt = stack.clock()
    armRtx(tcb)
  end)
  return tcb
end

--- Listen on laddr (0 = every address):port. Returns the listening TCB.
function M.listen(stack, laddr, lport, backlog)
  laddr = laddr and B.ip(laddr) or 0
  if stack.tcpListeners[lport .. ":" .. laddr] or stack.tcpListeners[lport .. ":0"] then return nil, "address in use" end
  local tcb = newTcb(stack)
  tcb.laddr, tcb.lport, tcb.raddr, tcb.rport = laddr, lport, 0, 0
  tcb.listening = true
  tcb.state = "LISTEN"
  tcb.acceptQ = {}
  tcb.backlog = backlog or 8
  tcb.pending = 0
  stack.tcpListeners[lport .. ":" .. laddr] = tcb
  return tcb
end

local function findListener(stack, laddr, lport)
  return stack.tcpListeners[lport .. ":" .. laddr] or stack.tcpListeners[lport .. ":0"]
end

---------------------------------------------------------------------------------------------------------------------
-- Timers
---------------------------------------------------------------------------------------------------------------------

local function sampleRtt(tcb, r)
  if not tcb.srtt then
    tcb.srtt = r
    tcb.rttvar = r / 2
  else
    tcb.rttvar = 0.75 * tcb.rttvar + 0.25 * math.abs(tcb.srtt - r)
    tcb.srtt = 0.875 * tcb.srtt + 0.125 * r
  end
  tcb.rto = min(M.MAX_RTO, max(M.MIN_RTO, tcb.srtt + max(M.CLOCK_G, 4 * tcb.rttvar)))
end

local function retransmitFirst(tcb)
  local stack = tcb.stack
  stack:count("tcp", "retransSegs")
  local unacked = seqDiff(tcb.snd_nxt, tcb.snd_una)
  local dataLen = #tcb.sendBuf
  local offset = seqDiff(tcb.snd_una, tcb.sbase)
  if seqLt(tcb.snd_una, tcb.sbase) then
    return nil      -- only the SYN is outstanding: handled by the caller
  end
  if offset < dataLen then
    local len = min(tcb.mss, dataLen - offset)
    xmit(tcb, ACK, tcb.snd_una, tcb.sendBuf:sub(offset + 1, offset + len))
  elseif tcb.finSent then
    xmit(tcb, FIN + ACK, tcb.finSeq)
  end
end

local function onRtx(tcb)
  local stack = tcb.stack
  tcb.rtxAt = nil
  tcb.rttSeq = nil           -- Karn: a retransmitted segment gives no RTT sample
  tcb.rtxCount = tcb.rtxCount + 1
  local limit = (tcb.state == "SYN_SENT" or tcb.state == "SYN_RCVD") and M.SYN_RETRIES or M.DATA_RETRIES
  if tcb.rtxCount > limit then
    stack:count("tcp", "attemptFails")
    return destroy(tcb, tcb.state == "SYN_SENT" and "connection timed out" or "connection timed out")
  end
  tcb.rto = min(M.MAX_RTO, tcb.rto * 2)
  if tcb.state == "SYN_SENT" then
    stack:count("tcp", "retransSegs")
    xmit(tcb, SYN, tcb.iss, nil, true)
  elseif tcb.state == "SYN_RCVD" then
    stack:count("tcp", "retransSegs")
    xmit(tcb, SYN + ACK, tcb.iss, nil, true)
  else
    local flight = seqDiff(tcb.snd_nxt, tcb.snd_una)
    tcb.ssthresh = max(floor(flight / 2), 2 * tcb.mss)
    tcb.cwnd = tcb.mss
    tcb.inRecovery = false
    tcb.dupacks = 0
    retransmitFirst(tcb)
    -- go back: everything after the first unacknowledged segment is sent again as the window opens
    local sentData = seqDiff(tcb.snd_nxt, tcb.sbase)
    if tcb.finSent and #tcb.sendBuf <= seqDiff(tcb.snd_una, tcb.sbase) then
      -- only the FIN is outstanding; it was just retransmitted
    else
      local firstLen = min(tcb.mss, #tcb.sendBuf - seqDiff(tcb.snd_una, tcb.sbase))
      tcb.snd_nxt = seqAdd(tcb.snd_una, max(0, firstLen))
      bump(tcb)               -- the retransmitted segment may reach beyond what was sent before (a probe was one byte)
      if tcb.finSent then tcb.finSent = false end
    end
  end
  tcb.rtxAt = stack.clock() + tcb.rto
end

local function onPersist(tcb)
  tcb.persistAt = nil
  if tcb.snd_wnd > 0 then return output(tcb) end
  local sentData = seqDiff(tcb.snd_nxt, tcb.sbase)
  if #tcb.sendBuf > sentData and seqDiff(tcb.snd_nxt, tcb.snd_una) == 0 then
    xmit(tcb, ACK, tcb.snd_nxt, tcb.sendBuf:sub(sentData + 1, sentData + 1))
    tcb.snd_nxt = seqAdd(tcb.snd_nxt, 1)
    bump(tcb)
    armRtx(tcb)
  end
  tcb.persistTries = (tcb.persistTries or 0) + 1
  tcb.persistAt = tcb.stack.clock() + min(60, tcb.rto * 2 ^ tcb.persistTries)
end

function M.tick(stack, now)
  for k, tcb in pairs(stack.tcpTable) do
    if tcb.twAt and now >= tcb.twAt then
      destroy(tcb)
    else
      if tcb.rtxAt and now >= tcb.rtxAt then onRtx(tcb) end
      if tcb.persistAt and now >= tcb.persistAt and tcb.state ~= "CLOSED" then onPersist(tcb) end
      if tcb.keepalive and tcb.state == "ESTABLISHED" and now - (tcb.lastRx or tcb.created) > tcb.keepalive then
        tcb.lastRx = now
        xmit(tcb, ACK, seqAdd(tcb.snd_una, -1))
      end
    end
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------------------------------------------------

local function enterTimeWait(tcb)
  tcb.rtxAt, tcb.persistAt = nil, nil
  tcb.twAt = tcb.stack.clock() + M.TIME_WAIT
  setState(tcb, "TIME_WAIT")
end

local function finReceived(tcb)
  tcb.finRcvd = true
  tcb.rcv_nxt = seqAdd(tcb.rcv_nxt, 1)
  local st = tcb.state
  if st == "ESTABLISHED" or st == "SYN_RCVD" then setState(tcb, "CLOSE_WAIT")
  elseif st == "FIN_WAIT_1" then
    if seqLt(tcb.finSeq, tcb.snd_una) then enterTimeWait(tcb) else setState(tcb, "CLOSING") end
  elseif st == "FIN_WAIT_2" then enterTimeWait(tcb)
  elseif st == "TIME_WAIT" then enterTimeWait(tcb) end
  tcb.stack:wake()
end

--- Queue received bytes at rcv_nxt, then everything out of order that has become contiguous.
local function absorb(tcb)
  while #tcb.ooo > 0 do
    local o = tcb.ooo[1]
    if seqLt(tcb.rcv_nxt, o.seq) then break end
    table.remove(tcb.ooo, 1)
    local skip = seqDiff(tcb.rcv_nxt, o.seq)
    if skip < #o.data then
      local piece = o.data:sub(skip + 1)
      tcb.rcvQ[#tcb.rcvQ + 1] = piece
      tcb.rcvLen = tcb.rcvLen + #piece
      tcb.bytesIn = tcb.bytesIn + #piece
      tcb.rcv_nxt = seqAdd(tcb.rcv_nxt, #piece)
    end
  end
  if tcb.oooFin and tcb.oooFin == tcb.rcv_nxt and not tcb.finRcvd then
    tcb.oooFin = nil
    finReceived(tcb)
  end
end

local function storeOoo(tcb, seq, data)
  if #data == 0 then return end
  for _, o in ipairs(tcb.ooo) do if o.seq == seq and #o.data >= #data then return end end
  local list = tcb.ooo
  local at = #list + 1
  for i, o in ipairs(list) do
    if seqLt(seq, o.seq) then at = i break end
  end
  table.insert(list, at, { seq = seq, data = data })
end

local function processAck(tcb, seg)
  local stack = tcb.stack
  local ack = seg.ack
  if seqLt(tcb.snd_max, ack) then
    sendAck(tcb)
    return false
  end
  if seqLt(tcb.snd_una, ack) then
    local acked = seqDiff(ack, tcb.snd_una)
    -- round trip sample (Karn: only for segments sent once)
    if tcb.rttSeq and seqLe(tcb.rttSeq, ack) then
      sampleRtt(tcb, stack.clock() - tcb.rttAt)
      tcb.rttSeq = nil
    end
    -- drop acknowledged data from the send buffer
    local dataAcked = 0
    if seqLt(tcb.sbase, ack) then
      dataAcked = min(#tcb.sendBuf, seqDiff(ack, tcb.sbase))
      tcb.sendBuf = tcb.sendBuf:sub(dataAcked + 1)
      tcb.sbase = seqAdd(tcb.sbase, dataAcked)
      tcb.bytesOut = tcb.bytesOut + dataAcked
    end
    tcb.snd_una = ack
    if seqLt(tcb.snd_nxt, ack) then tcb.snd_nxt = ack end
    tcb.rtxCount = 0
    -- congestion control
    if tcb.inRecovery then
      if seqLe(tcb.recover, ack) then
        tcb.inRecovery = false
        tcb.cwnd = min(tcb.ssthresh, max(seqDiff(tcb.snd_nxt, tcb.snd_una), tcb.mss) + tcb.mss)
        tcb.dupacks = 0
      else
        -- partial acknowledgement: the next hole is lost too
        retransmitFirst(tcb)
        tcb.cwnd = max(tcb.mss, tcb.cwnd - dataAcked + tcb.mss)
      end
    else
      tcb.dupacks = 0
      if tcb.cwnd < tcb.ssthresh then tcb.cwnd = tcb.cwnd + min(dataAcked, tcb.mss)
      else tcb.cwnd = tcb.cwnd + max(1, floor(tcb.mss * tcb.mss / tcb.cwnd)) end
    end
    if tcb.snd_una == tcb.snd_nxt then tcb.rtxAt = nil else restartRtx(tcb) end
    -- window update
    if seqLt(tcb.snd_wl1, seg.seq) or (tcb.snd_wl1 == seg.seq and seqLe(tcb.snd_wl2, ack)) then
      tcb.snd_wnd, tcb.snd_wl1, tcb.snd_wl2 = seg.window, seg.seq, ack
    end
    stack:wake()
    return true, acked
  elseif ack == tcb.snd_una then
    -- duplicate acknowledgement?
    local len = #seg.payload + (has(seg.flags, FIN) and 1 or 0)
    if len == 0 and seg.window == tcb.snd_wnd and tcb.snd_una ~= tcb.snd_nxt and not has(seg.flags, SYN) then
      tcb.dupacks = tcb.dupacks + 1
      if tcb.dupacks == 3 and not tcb.inRecovery then
        local flight = seqDiff(tcb.snd_nxt, tcb.snd_una)
        tcb.ssthresh = max(floor(flight / 2), 2 * tcb.mss)
        tcb.recover = tcb.snd_nxt
        tcb.inRecovery = true
        tcb.rttSeq = nil
        retransmitFirst(tcb)
        tcb.cwnd = tcb.ssthresh + 3 * tcb.mss
        stack:count("tcp", "fastRetrans")
      elseif tcb.dupacks > 3 and tcb.inRecovery then
        tcb.cwnd = tcb.cwnd + tcb.mss
      end
    end
    if seqLt(tcb.snd_wl1, seg.seq) or (tcb.snd_wl1 == seg.seq and seqLe(tcb.snd_wl2, ack)) then
      tcb.snd_wnd, tcb.snd_wl1, tcb.snd_wl2 = seg.window, seg.seq, ack
    end
    return true, 0
  end
  return true, 0          -- an old acknowledgement: ignore
end

--- A segment arrived for an established-or-later connection (everything except LISTEN and SYN_SENT).
local function segmentArrives(tcb, pkt, seg)
  local stack = tcb.stack
  local flags = seg.flags
  local len = #seg.payload + (has(flags, SYN) and 1 or 0) + (has(flags, FIN) and 1 or 0)
  tcb.lastRx = stack.clock()
  -- 1. acceptable sequence number?
  local wnd = tcb.rcv_wnd
  local okSeq
  if len == 0 then
    if wnd == 0 then okSeq = seg.seq == tcb.rcv_nxt
    else okSeq = seqLe(tcb.rcv_nxt, seg.seq) and seqLt(seg.seq, seqAdd(tcb.rcv_nxt, wnd)) end
  else
    if wnd == 0 then okSeq = false
    else
      local last = seqAdd(seg.seq, len - 1)
      okSeq = (seqLe(tcb.rcv_nxt, seg.seq) and seqLt(seg.seq, seqAdd(tcb.rcv_nxt, wnd)))
        or (seqLe(tcb.rcv_nxt, last) and seqLt(last, seqAdd(tcb.rcv_nxt, wnd)))
        or (seqLt(seg.seq, tcb.rcv_nxt) and seqLe(tcb.rcv_nxt, last))
    end
  end
  if not okSeq then
    if not has(flags, RST) then sendAck(tcb) end
    return
  end
  -- 2. RST
  if has(flags, RST) then
    local st = tcb.state
    if st == "SYN_RCVD" then return destroy(tcb, "connection refused") end
    if st == "TIME_WAIT" then return destroy(tcb) end
    return destroy(tcb, "connection reset by peer")
  end
  -- 4. SYN inside the window is an error (RFC 5961: challenge ACK)
  if has(flags, SYN) then
    if tcb.state == "SYN_RCVD" and seg.seq == tcb.irs then return end       -- the SYN was retransmitted
    sendAck(tcb)
    return
  end
  -- 5. ACK
  if not has(flags, ACK) then return end
  local st = tcb.state
  if st == "SYN_RCVD" then
    if seqLt(tcb.snd_una, seg.ack) and seqLe(seg.ack, tcb.snd_nxt) then
      tcb.snd_una = seg.ack
      tcb.snd_wnd, tcb.snd_wl1, tcb.snd_wl2 = seg.window, seg.seq, seg.ack
      tcb.rtxAt, tcb.rtxCount = nil, 0
      if tcb.synAt then sampleRtt(tcb, stack.clock() - tcb.synAt) end
      setState(tcb, "ESTABLISHED")
      stack:count("tcp", "passiveOpens")
      local parent = tcb.parent
      if parent then
        parent.pending = max(0, (parent.pending or 1) - 1)
        parent.acceptQ[#parent.acceptQ + 1] = tcb
        stack:wake()
      end
      st = "ESTABLISHED"
    else
      return sendReset(stack, pkt, seg)
    end
  end
  local advanced = processAck(tcb, seg)
  if advanced == false then return end
  if st == "FIN_WAIT_1" and tcb.finSent and seqLt(tcb.finSeq, tcb.snd_una) then setState(tcb, "FIN_WAIT_2") st = "FIN_WAIT_2"
  elseif st == "CLOSING" and tcb.finSent and seqLt(tcb.finSeq, tcb.snd_una) then enterTimeWait(tcb) return
  elseif st == "LAST_ACK" and tcb.finSent and seqLt(tcb.finSeq, tcb.snd_una) then return destroy(tcb) end
  -- 7. data and FIN
  local data, seq, fin = seg.payload, seg.seq, has(flags, FIN)
  local acceptsData = st == "ESTABLISHED" or st == "FIN_WAIT_1" or st == "FIN_WAIT_2"
  if (#data > 0 or fin) and (acceptsData or st == "CLOSE_WAIT" or st == "CLOSING" or st == "LAST_ACK" or st == "TIME_WAIT") then
    if not acceptsData then
      if st == "TIME_WAIT" and fin then enterTimeWait(tcb) end
      sendAck(tcb)
      return
    end
    -- trim what we already have
    if seqLt(seq, tcb.rcv_nxt) then
      local dup = seqDiff(tcb.rcv_nxt, seq)
      if dup >= #data then
        if dup > #data and fin then fin = false end        -- the FIN was already counted
        data = ""
        seq = tcb.rcv_nxt
        if fin and seqAdd(seg.seq, #seg.payload) ~= tcb.rcv_nxt then fin = false end
      else
        data = data:sub(dup + 1)
        seq = tcb.rcv_nxt
      end
    end
    -- trim what does not fit in the window
    local space = max(0, tcb.rcv_wnd - seqDiff(seq, tcb.rcv_nxt))
    if #data > space then data = data:sub(1, space) fin = false end
    if seq == tcb.rcv_nxt then
      if #data > 0 then
        tcb.rcvQ[#tcb.rcvQ + 1] = data
        tcb.rcvLen = tcb.rcvLen + #data
        tcb.bytesIn = tcb.bytesIn + #data
        tcb.rcv_nxt = seqAdd(tcb.rcv_nxt, #data)
      end
      absorb(tcb)
      if fin and seqAdd(seq, #data) == tcb.rcv_nxt and not tcb.finRcvd then finReceived(tcb) end
    else
      storeOoo(tcb, seq, data)
      if fin then tcb.oooFin = seqAdd(seq, #data) end
    end
    sendAck(tcb)
    stack:wake()
  end
  output(tcb)
end

local function listenInput(stack, listener, pkt, seg)
  local flags = seg.flags
  if has(flags, RST) then return end
  if has(flags, ACK) then return sendReset(stack, pkt, seg) end
  if not has(flags, SYN) then return end
  if (listener.pending or 0) + #listener.acceptQ >= listener.backlog then
    stack:count("tcp", "listenDrops")
    return                                  -- the client will retry its SYN
  end
  local tcb = newTcb(stack)
  tcb.laddr, tcb.lport, tcb.raddr, tcb.rport = pkt.dst, seg.dport, pkt.src, seg.sport
  tcb.k = key(tcb.laddr, tcb.lport, tcb.raddr, tcb.rport)
  if stack.tcpTable[tcb.k] then return end
  tcb.parent = listener
  listener.pending = (listener.pending or 0) + 1
  tcb.irs = seg.seq
  tcb.rcv_nxt = seqAdd(seg.seq, 1)
  tcb.peerMss = seg.mss or 536
  local r = stack:lookup(pkt.src)
  local mtu = r and stack.ifaces[r.iface].mtu or 1500
  tcb.ourMss = min(mtu - 40, 1460)
  tcb.mss = min(tcb.peerMss, tcb.ourMss)
  initCwnd(tcb)
  initSend(tcb, newIss(stack))
  tcb.snd_wnd, tcb.snd_wl1, tcb.snd_wl2 = seg.window, seg.seq, tcb.iss
  tcb.noDelay = listener.noDelay
  stack.tcpTable[tcb.k] = tcb
  setState(tcb, "SYN_RCVD")
  xmit(tcb, SYN + ACK, tcb.iss, nil, true)
  tcb.snd_nxt = seqAdd(tcb.iss, 1)
  bump(tcb)
  tcb.synAt = stack.clock()
  armRtx(tcb)
end

local function synSentInput(tcb, pkt, seg)
  local stack = tcb.stack
  local flags = seg.flags
  local ackOk = false
  if has(flags, ACK) then
    if seqLe(seg.ack, tcb.iss) or seqLt(tcb.snd_nxt, seg.ack) then
      if not has(flags, RST) then sendReset(stack, pkt, seg) end
      return
    end
    ackOk = true
  end
  if has(flags, RST) then
    if ackOk then
      stack:count("tcp", "attemptFails")
      destroy(tcb, "connection refused")
    end
    return
  end
  if has(flags, SYN) then
    tcb.irs = seg.seq
    tcb.rcv_nxt = seqAdd(seg.seq, 1)
    tcb.peerMss = seg.mss or 536
    tcb.mss = min(tcb.peerMss, tcb.ourMss)
    initCwnd(tcb)
    if ackOk then
      tcb.snd_una = seg.ack
      tcb.rtxAt, tcb.rtxCount = nil, 0
    end
    tcb.snd_wnd, tcb.snd_wl1, tcb.snd_wl2 = seg.window, seg.seq, seg.ack
    if seqLt(tcb.iss, tcb.snd_una) then
      if tcb.synAt and tcb.rtxCount == 0 then sampleRtt(tcb, stack.clock() - tcb.synAt) end
      setState(tcb, "ESTABLISHED")
      sendAck(tcb)
      if #seg.payload > 0 then segmentArrives(tcb, pkt, { seq = seqAdd(seg.seq, 1), ack = seg.ack, flags = flags - SYN, window = seg.window, payload = seg.payload }) end
      output(tcb)
    else
      -- simultaneous open
      setState(tcb, "SYN_RCVD")
      xmit(tcb, SYN + ACK, tcb.iss, nil, true)
    end
  end
end

--- A TCP segment arrived in an IP packet.
function M.input(stack, iface, pkt)
  if pkt.dst == B.BROADCAST or stack:isBroadcastFor(iface, pkt.dst) or B.isMulticast(pkt.dst) then return end
  local seg, err = W.tcpDecode(pkt.src, pkt.dst, pkt.payload)
  if not seg then stack:count("tcp", "inErrs") return end
  stack:count("tcp", "inSegs")
  local tcb = stack.tcpTable[key(pkt.dst, seg.dport, pkt.src, seg.sport)]
  if tcb then
    if tcb.state == "SYN_SENT" then return synSentInput(tcb, pkt, seg) end
    return segmentArrives(tcb, pkt, seg)
  end
  local listener = findListener(stack, pkt.dst, seg.dport)
  if listener then return listenInput(stack, listener, pkt, seg) end
  return sendReset(stack, pkt, seg)
end

--- ICMP said that a segment of ours did not get through.
function M.icmpError(stack, msg, q)
  if #q.transport < 4 then return end
  local sport, dport = B.rd16(q.transport, 1), B.rd16(q.transport, 3)
  local tcb = stack.tcpTable[key(q.src, sport, q.dst, dport)]
  if not tcb then return end
  if msg.type == W.ICMP_UNREACH and (tcb.state == "SYN_SENT" or tcb.state == "SYN_RCVD") then
    destroy(tcb, msg.code == W.UNREACH_PORT and "connection refused" or "network unreachable")
  end
end

---------------------------------------------------------------------------------------------------------------------
-- User operations
---------------------------------------------------------------------------------------------------------------------

--- Queue data for sending. Returns how many bytes were accepted (0 when the buffer is full) or nil + reason.
function M.write(tcb, data)
  local stack = tcb.stack
  if tcb.err and tcb.state == "CLOSED" then return nil, tcb.err end
  local st = tcb.state
  if st ~= "ESTABLISHED" and st ~= "CLOSE_WAIT" and st ~= "SYN_SENT" and st ~= "SYN_RCVD" then return nil, "connection closed" end
  if tcb.finQueued then return nil, "connection closed for writing" end
  local room = tcb.sendMax - #tcb.sendBuf
  if room <= 0 then return 0 end
  local n = min(room, #data)
  tcb.sendBuf = tcb.sendBuf .. data:sub(1, n)
  stack:run(output, tcb)
  return n
end

--- Take up to `max` bytes of received data. Returns the data, "" when none is there yet, or nil + reason once the peer has closed and
--- everything was read ("closed") or the connection failed.
function M.read(tcb, maxBytes)
  local stack = tcb.stack
  if tcb.rcvLen > 0 then
    local parts, got = {}, 0
    while #tcb.rcvQ > 0 and got < maxBytes do
      local piece = tcb.rcvQ[1]
      if got + #piece <= maxBytes then
        parts[#parts + 1] = piece
        got = got + #piece
        table.remove(tcb.rcvQ, 1)
      else
        local take = maxBytes - got
        parts[#parts + 1] = piece:sub(1, take)
        tcb.rcvQ[1] = piece:sub(take + 1)
        got = got + take
      end
    end
    tcb.rcvLen = tcb.rcvLen - got
    -- tell the sender when the window has opened up noticeably
    local st = tcb.state
    if (st == "ESTABLISHED" or st == "FIN_WAIT_1" or st == "FIN_WAIT_2") and tcb.lastAdvertised then
      local newEdge = seqAdd(tcb.rcv_nxt, min(65535, tcb.rcvMax - tcb.rcvLen))
      if seqDiff(newEdge, tcb.lastAdvertised) >= min(tcb.mss, floor(tcb.rcvMax / 2)) then stack:run(sendAck, tcb) end
    end
    return table.concat(parts)
  end
  if tcb.err then return nil, tcb.err end
  if tcb.finRcvd or tcb.state == "CLOSED" or tcb.state == "TIME_WAIT" then return nil, "closed" end
  return ""
end

--- No more data from us: sends FIN after the queued data.
function M.shutdownWrite(tcb)
  local stack = tcb.stack
  if tcb.finQueued then return true end
  local st = tcb.state
  if st == "ESTABLISHED" then tcb.finQueued = true setState(tcb, "FIN_WAIT_1")
  elseif st == "CLOSE_WAIT" then tcb.finQueued = true setState(tcb, "LAST_ACK")
  elseif st == "SYN_RCVD" then tcb.finQueued = true setState(tcb, "FIN_WAIT_1")
  elseif st == "SYN_SENT" or st == "LISTEN" then destroy(tcb) return true
  else return false end
  stack:run(output, tcb)
  return true
end

--- Reset the connection at once.
function M.abort(tcb)
  local stack = tcb.stack
  local st = tcb.state
  if st == "ESTABLISHED" or st == "CLOSE_WAIT" or st == "FIN_WAIT_1" or st == "FIN_WAIT_2" or st == "SYN_RCVD" or st == "CLOSING" then
    stack:run(function() xmit(tcb, RST + ACK, tcb.snd_nxt) end)
  end
  if tcb.listening then
    for _, c in ipairs(tcb.acceptQ) do M.abort(c) end
  end
  destroy(tcb)
end

--- Orderly close. A listener just stops listening.
function M.close(tcb)
  if tcb.listening then return M.abort(tcb) end
  if tcb.state == "CLOSED" then return end
  if tcb.state == "TIME_WAIT" then return end
  tcb.closedByUser = true
  M.shutdownWrite(tcb)
end

--- One line about a connection (netstat).
function M.describe(tcb)
  return { state = tcb.state, laddr = tcb.laddr, lport = tcb.lport, raddr = tcb.raddr, rport = tcb.rport, sendQ = #tcb.sendBuf, recvQ = tcb.rcvLen,
    cwnd = tcb.cwnd, rto = tcb.rto, srtt = tcb.srtt, bytesIn = tcb.bytesIn, bytesOut = tcb.bytesOut }
end

return M
