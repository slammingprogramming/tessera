-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Packet formats as they appear on the wire: Ethernet II with 802.1Q tags, ARP (RFC 826), IPv4 (RFC 791), ICMP (RFC 792), UDP (RFC 768) and
-- TCP (RFC 9293) headers. Every function turns a byte string into a table or back, and verifies what the RFCs say to verify
-- (lengths, checksums). Nothing here keeps state.
local B = require("tsr.inet.bytes")

local M = {}

local sbyte, schar, floor, concat = string.byte, string.char, math.floor, table.concat
local u16, u32, rd16, rd32 = B.u16, B.u32, B.rd16, B.rd32

M.ETH_IPV4 = 0x0800
M.ETH_ARP = 0x0806
M.ETH_VLAN = 0x8100
M.ETH_STP = 0x0026          -- stands for the 802.3 length field of an LLC frame carrying STP (BPDUs)
M.PROTO_ICMP, M.PROTO_TCP, M.PROTO_UDP = 1, 6, 17

---------------------------------------------------------------------------------------------------------------------
-- Ethernet
---------------------------------------------------------------------------------------------------------------------

--- { dst, src, type, payload, vlan (nil for untagged), pcp }. Frame = dst(6) src(6) [8100 TCI] type payload.
function M.ethEncode(f)
  local head = f.dst .. f.src
  if f.vlan then
    head = head .. u16(M.ETH_VLAN) .. u16((f.pcp or 0) * 8192 + f.vlan)
  end
  return head .. u16(f.type) .. f.payload
end

function M.ethDecode(frame)
  if #frame < 14 then return nil, "runt frame" end
  local f = { dst = frame:sub(1, 6), src = frame:sub(7, 12) }
  local t = rd16(frame, 13)
  local pos = 15
  if t == M.ETH_VLAN then
    if #frame < 18 then return nil, "truncated VLAN tag" end
    local tci = rd16(frame, 15)
    f.vlan = tci % 4096
    f.pcp = floor(tci / 8192)
    t = rd16(frame, 17)
    pos = 19
  end
  f.type = t
  f.payload = frame:sub(pos)
  return f
end

---------------------------------------------------------------------------------------------------------------------
-- ARP (Ethernet / IPv4)
---------------------------------------------------------------------------------------------------------------------

M.ARP_REQUEST, M.ARP_REPLY = 1, 2

function M.arpEncode(a)
  return u16(1) .. u16(M.ETH_IPV4) .. "\6\4" .. u16(a.op) .. a.sha .. u32(a.spa) .. a.tha .. u32(a.tpa)
end

function M.arpDecode(payload)
  if #payload < 28 then return nil, "short ARP" end
  if rd16(payload, 1) ~= 1 or rd16(payload, 3) ~= M.ETH_IPV4 or sbyte(payload, 5) ~= 6 or sbyte(payload, 6) ~= 4 then
    return nil, "not Ethernet/IPv4 ARP"
  end
  return { op = rd16(payload, 7), sha = payload:sub(9, 14), spa = rd32(payload, 15), tha = payload:sub(19, 24), tpa = rd32(payload, 25) }
end

---------------------------------------------------------------------------------------------------------------------
-- IPv4
---------------------------------------------------------------------------------------------------------------------

--- p: src, dst, proto, payload, ttl (64), tos (0), id, df (bool), mf (bool), frag (offset in 8-byte units), options (raw string, padded to 4).
function M.ipEncode(p)
  local opts = p.options or ""
  if #opts % 4 ~= 0 then opts = opts .. string.rep("\0", 4 - #opts % 4) end
  local ihl = 5 + #opts / 4
  local total = ihl * 4 + #p.payload
  local flags = (p.df and 2 or 0) + (p.mf and 1 or 0)
  local head = schar(0x40 + ihl, p.tos or 0) .. u16(total) .. u16(p.id or 0) .. u16(flags * 8192 + (p.frag or 0))
    .. schar(p.ttl or 64, p.proto) .. "\0\0" .. u32(p.src) .. u32(p.dst) .. opts
  local csum = B.checksum(head)
  return head:sub(1, 10) .. u16(csum) .. head:sub(13) .. p.payload
end

--- Parse and validate an IPv4 packet. Returns a table (see ipEncode, plus len, ihl, header) or nil + reason.
function M.ipDecode(data)
  if #data < 20 then return nil, "short IP packet" end
  local vi = sbyte(data, 1)
  if floor(vi / 16) ~= 4 then return nil, "not IPv4" end
  local ihl = vi % 16
  if ihl < 5 or ihl * 4 > #data then return nil, "bad header length" end
  local total = rd16(data, 3)
  if total < ihl * 4 or total > #data then return nil, "bad total length" end
  local header = data:sub(1, ihl * 4)
  if B.checksum(header) ~= 0 then return nil, "bad header checksum" end
  local ff = rd16(data, 7)
  local flags = floor(ff / 8192)
  return {
    tos = sbyte(data, 2), len = total, id = rd16(data, 5), df = flags % 4 >= 2, mf = flags % 2 == 1, frag = ff % 8192,
    ttl = sbyte(data, 9), proto = sbyte(data, 10), src = rd32(data, 13), dst = rd32(data, 17), ihl = ihl,
    options = ihl > 5 and header:sub(21) or nil, header = header, payload = data:sub(ihl * 4 + 1, total),
  }
end

--- The pseudo header that TCP and UDP checksums cover (RFC 793/768).
function M.pseudo(src, dst, proto, len)
  return B.sum(u32(src) .. u32(dst) .. schar(0, proto) .. u16(len))
end

---------------------------------------------------------------------------------------------------------------------
-- ICMP
---------------------------------------------------------------------------------------------------------------------

M.ICMP_ECHO_REPLY, M.ICMP_UNREACH, M.ICMP_REDIRECT, M.ICMP_ECHO, M.ICMP_TIME_EXCEEDED = 0, 3, 5, 8, 11
M.UNREACH_NET, M.UNREACH_HOST, M.UNREACH_PROTO, M.UNREACH_PORT, M.UNREACH_FRAG, M.UNREACH_ADMIN = 0, 1, 2, 3, 4, 13

--- m: type, code, rest (the 4 "rest of header" bytes as a string, default zeros), data.
function M.icmpEncode(m)
  local rest = m.rest or "\0\0\0\0"
  local body = schar(m.type, m.code or 0) .. "\0\0" .. rest .. (m.data or "")
  return body:sub(1, 2) .. u16(B.checksum(body)) .. body:sub(5)
end

function M.icmpDecode(data)
  if #data < 8 then return nil, "short ICMP" end
  if B.checksum(data) ~= 0 then return nil, "bad ICMP checksum" end
  return { type = sbyte(data, 1), code = sbyte(data, 2), rest = data:sub(5, 8), data = data:sub(9),
    id = rd16(data, 5), seq = rd16(data, 7) }
end

---------------------------------------------------------------------------------------------------------------------
-- UDP
---------------------------------------------------------------------------------------------------------------------

function M.udpEncode(src, dst, sport, dport, payload)
  local len = 8 + #payload
  local head = u16(sport) .. u16(dport) .. u16(len) .. "\0\0"
  local csum = B.checksum(head .. payload, M.pseudo(src, dst, M.PROTO_UDP, len))
  if csum == 0 then csum = 65535 end
  return head:sub(1, 6) .. u16(csum) .. payload
end

function M.udpDecode(src, dst, data)
  if #data < 8 then return nil, "short UDP" end
  local len = rd16(data, 5)
  if len < 8 or len > #data then return nil, "bad UDP length" end
  data = data:sub(1, len)
  local csum = rd16(data, 7)
  if csum ~= 0 and B.checksum(data, M.pseudo(src, dst, M.PROTO_UDP, len)) ~= 0 then return nil, "bad UDP checksum" end
  return { sport = rd16(data, 1), dport = rd16(data, 3), payload = data:sub(9) }
end

---------------------------------------------------------------------------------------------------------------------
-- TCP
---------------------------------------------------------------------------------------------------------------------

M.FIN, M.SYN, M.RST, M.PSH, M.ACK, M.URG = 1, 2, 4, 8, 16, 32

--- s: sport, dport, seq, ack, flags (number), window, mss (option on SYN), payload.
function M.tcpEncode(src, dst, s)
  local opts = ""
  if s.mss then opts = schar(2, 4) .. u16(s.mss) end
  local off = 5 + #opts / 4
  local payload = s.payload or ""
  local head = u16(s.sport) .. u16(s.dport) .. u32(s.seq) .. u32(s.ack or 0) .. schar(off * 16, s.flags) .. u16(s.window or 0) .. "\0\0\0\0" .. opts
  local len = #head + #payload
  local csum = B.checksum(head .. payload, M.pseudo(src, dst, M.PROTO_TCP, len))
  return head:sub(1, 16) .. u16(csum) .. head:sub(19) .. payload
end

function M.tcpDecode(src, dst, data)
  if #data < 20 then return nil, "short TCP" end
  local off = floor(sbyte(data, 13) / 16)
  if off < 5 or off * 4 > #data then return nil, "bad TCP data offset" end
  if B.checksum(data, M.pseudo(src, dst, M.PROTO_TCP, #data)) ~= 0 then return nil, "bad TCP checksum" end
  local s = {
    sport = rd16(data, 1), dport = rd16(data, 3), seq = rd32(data, 5), ack = rd32(data, 9), flags = sbyte(data, 14) % 64,
    window = rd16(data, 15), payload = data:sub(off * 4 + 1),
  }
  -- options: only MSS is understood, the rest is skipped
  local i = 21
  while i < off * 4 + 1 do
    local kind = sbyte(data, i)
    if kind == 0 then break end
    if kind == 1 then i = i + 1 else
      local l = sbyte(data, i + 1)
      if not l or l < 2 then break end
      if kind == 2 and l == 4 then s.mss = rd16(data, i + 2) end
      i = i + l
    end
  end
  return s
end

return M
