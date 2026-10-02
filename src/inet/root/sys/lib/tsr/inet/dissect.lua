-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Reading captured frames: parse a frame into a table (parse), one line of text for tcpdump (describe), and capture filters
-- ("host 10.0.0.2 and not port 22", "tcp", "arp", "icmp or udp") compiled into functions (filter).
-- Other packages add decoders for their protocols: dissect.udp[port] = function(info, payload) -> text.
local B = require("tsr.inet.bytes")
local W = require("tsr.inet.wire")

local M = {}

M.udp = {}                 -- port -> function(info, payload) -> description
M.tcp = {}

local FLAG_NAMES = { { W.SYN, "S" }, { W.FIN, "F" }, { W.RST, "R" }, { W.PSH, "P" }, { W.URG, "U" } }

--- Parse a frame. Returns a table: eth, kind ("arp" | "ip" | "other"), plus for ip: ip, proto, src, dst, sport, dport, tcp/udp/icmp details.
function M.parse(frame)
  local eth, err = W.ethDecode(frame)
  if not eth then return { kind = "bad", error = err } end
  local info = { eth = eth, kind = "other", length = #frame }
  if eth.type == W.ETH_ARP then
    info.kind = "arp"
    info.arp = W.arpDecode(eth.payload)
  elseif eth.type == W.ETH_IPV4 then
    info.kind = "ip"
    local ip, why = W.ipDecode(eth.payload)
    if not ip then info.kind, info.error = "badip", why return info end
    info.ip, info.src, info.dst, info.proto = ip, ip.src, ip.dst, ip.proto
    if ip.frag == 0 then
      if ip.proto == W.PROTO_TCP then
        info.tcp = W.tcpDecode(ip.src, ip.dst, ip.payload)
        if info.tcp then info.sport, info.dport = info.tcp.sport, info.tcp.dport end
      elseif ip.proto == W.PROTO_UDP then
        info.udp = W.udpDecode(ip.src, ip.dst, ip.payload)
        if info.udp then info.sport, info.dport = info.udp.sport, info.udp.dport end
      elseif ip.proto == W.PROTO_ICMP then
        info.icmp = W.icmpDecode(ip.payload)
      end
    end
  end
  return info
end

local function flagText(flags)
  local out = ""
  for _, f in ipairs(FLAG_NAMES) do if flags % (f[1] * 2) >= f[1] then out = out .. f[2] end end
  if flags % 32 >= 16 then out = out .. "." end
  return out == "" and "none" or out
end

local ICMP_TYPES = { [0] = "echo reply", [3] = "destination unreachable", [5] = "redirect", [8] = "echo request", [11] = "time exceeded" }
local UNREACH = { [0] = "net unreachable", [1] = "host unreachable", [2] = "protocol unreachable", [3] = "port unreachable", [4] = "fragmentation needed", [13] = "administratively prohibited" }

--- One line of text for a parsed frame.
function M.describe(info)
  local vlan = info.eth and info.eth.vlan and ("vlan " .. info.eth.vlan .. ", ") or ""
  if info.kind == "bad" then return "malformed frame: " .. tostring(info.error) end
  if info.kind == "arp" then
    local a = info.arp
    if not a then return vlan .. "ARP, malformed" end
    if a.op == W.ARP_REQUEST then
      if a.spa == a.tpa then return vlan .. "ARP, announcement " .. B.ipStr(a.spa) .. " is-at " .. B.macStr(a.sha) end
      return vlan .. "ARP, Request who-has " .. B.ipStr(a.tpa) .. " tell " .. B.ipStr(a.spa)
    end
    return vlan .. "ARP, Reply " .. B.ipStr(a.spa) .. " is-at " .. B.macStr(a.sha)
  end
  if info.kind == "badip" then return vlan .. "IP, bad packet: " .. tostring(info.error) end
  if info.kind == "other" then return vlan .. ("ethertype 0x%04x, length %d, %s > %s"):format(info.eth.type, info.length, B.macStr(info.eth.src), B.macStr(info.eth.dst)) end
  local ip = info.ip
  local frag = ""
  if ip.frag > 0 or ip.mf then frag = (" (frag id %d, offset %d%s)"):format(ip.id, ip.frag * 8, ip.mf and ", more" or "") end
  local head = vlan .. "IP " .. B.ipStr(ip.src)
  if ip.proto == W.PROTO_ICMP and info.icmp then
    local m = info.icmp
    local text = ICMP_TYPES[m.type] or ("type " .. m.type)
    if m.type == 3 then text = text .. ", " .. (UNREACH[m.code] or ("code " .. m.code)) end
    if m.type == 0 or m.type == 8 then text = ("%s, id %d, seq %d"):format(text, m.id, m.seq) end
    return ("%s > %s: ICMP %s, length %d, ttl %d%s"):format(head, B.ipStr(ip.dst), text, #ip.payload, ip.ttl, frag)
  elseif ip.proto == W.PROTO_UDP and info.udp then
    local u = info.udp
    local extra = M.udp[u.dport] and M.udp[u.dport](info, u.payload) or (M.udp[u.sport] and M.udp[u.sport](info, u.payload)) or nil
    return ("%s.%d > %s.%d: UDP, length %d%s%s"):format(head, u.sport, B.ipStr(ip.dst), u.dport, #u.payload, extra and (": " .. extra) or "", frag)
  elseif ip.proto == W.PROTO_TCP and info.tcp then
    local t = info.tcp
    local extra = M.tcp[t.dport] and #t.payload > 0 and M.tcp[t.dport](info, t.payload) or (M.tcp[t.sport] and #t.payload > 0 and M.tcp[t.sport](info, t.payload)) or nil
    return ("%s.%d > %s.%d: Flags [%s], seq %d%s, win %d%s, length %d%s%s"):format(head, t.sport, B.ipStr(ip.dst), t.dport, flagText(t.flags), t.seq,
      t.flags % 32 >= 16 and (", ack " .. t.ack) or "", t.window, t.mss and (", mss " .. t.mss) or "", #t.payload, extra and (": " .. extra) or "", frag)
  end
  return ("%s > %s: proto %d, length %d%s"):format(head, B.ipStr(ip.dst), ip.proto, #ip.payload, frag)
end

---------------------------------------------------------------------------------------------------------------------
-- Capture filters
---------------------------------------------------------------------------------------------------------------------

local function hasHost(info, ip, which)
  if info.kind == "arp" and info.arp then
    if which == "src" then return info.arp.spa == ip end
    if which == "dst" then return info.arp.tpa == ip end
    return info.arp.spa == ip or info.arp.tpa == ip
  end
  if not info.src then return false end
  if which == "src" then return info.src == ip end
  if which == "dst" then return info.dst == ip end
  return info.src == ip or info.dst == ip
end

--- Compile a filter given as a list of words, e.g. { "host", "10.0.0.2", "and", "port", "80" }. Returns a function(info) -> bool, or nil + reason.
--- Words: tcp udp icmp arp ip | host A | src A | dst A | net CIDR | port N | vlan N | not, and, or | ( ) is not supported (keep it simple).
function M.filter(words)
  if #words == 0 then return function() return true end end
  local pos = 1
  local function atom()
    local w = words[pos]
    if not w then return nil, "unexpected end of filter" end
    pos = pos + 1
    if w == "not" or w == "!" then
      local inner, err = atom()
      if not inner then return nil, err end
      return function(i) return not inner(i) end
    elseif w == "tcp" then return function(i) return i.proto == W.PROTO_TCP end
    elseif w == "udp" then return function(i) return i.proto == W.PROTO_UDP end
    elseif w == "icmp" then return function(i) return i.proto == W.PROTO_ICMP end
    elseif w == "arp" then return function(i) return i.kind == "arp" end
    elseif w == "ip" then return function(i) return i.kind == "ip" end
    elseif w == "host" or w == "src" or w == "dst" then
      local which = (w ~= "host") and w or nil
      if which and words[pos] == "host" then pos = pos + 1 end
      local ip = B.ip(words[pos] or "")
      if not ip then return nil, "bad address after " .. w end
      pos = pos + 1
      return function(i) return hasHost(i, ip, which) end
    elseif w == "net" then
      local net, plen = B.cidr(words[pos] or "")
      if not net then return nil, "bad network after net" end
      pos = pos + 1
      return function(i) return i.src ~= nil and (B.inNet(i.src, net, plen) or B.inNet(i.dst, net, plen)) end
    elseif w == "port" then
      local n = tonumber(words[pos])
      if not n then return nil, "bad port" end
      pos = pos + 1
      return function(i) return i.sport == n or i.dport == n end
    elseif w == "vlan" then
      local n = tonumber(words[pos])
      pos = pos + 1
      return function(i) return i.eth and i.eth.vlan == n end
    end
    return nil, "unknown filter word '" .. tostring(w) .. "'"
  end
  local function conj()
    local left, err = atom()
    if not left then return nil, err end
    while words[pos] == "and" or (words[pos] and words[pos] ~= "or") do
      if words[pos] == "and" then pos = pos + 1 end
      local right, e2 = atom()
      if not right then return nil, e2 end
      local l, r = left, right
      left = function(i) return l(i) and r(i) end
    end
    return left
  end
  local expr, err = conj()
  if not expr then return nil, err end
  while words[pos] == "or" do
    pos = pos + 1
    local right, e2 = conj()
    if not right then return nil, e2 end
    local l, r = expr, right
    expr = function(i) return l(i) or r(i) end
  end
  if pos <= #words then return nil, "unexpected '" .. words[pos] .. "'" end
  return expr
end

return M
