-- SPDX-License-Identifier: AGPL-3.0-or-later
-- A stateful packet filter and NAT in the manner of Linux netfilter / iptables, for the IP stack of this computer.
--
--   tables:  filter (INPUT: packets to this computer, FORWARD: packets routed through it, OUTPUT: packets it sends)
--            nat    (PREROUTING: before routing, destination NAT / port forwarding;  POSTROUTING: after routing, source NAT / masquerading)
--   rules:   match on protocol, addresses, ports, interfaces, connection state, TCP flags, ICMP type, rate and connections per source; the first rule
--            that matches decides (ACCEPT, DROP, REJECT, LOG, jump to your own chain, ...); no match = the chain's policy.
--   state:   the connection tracker (tsr.inet.fw.conntrack) follows every flow, so `-m state --state ESTABLISHED,RELATED -j ACCEPT` lets replies in
--            without opening the door to anything else, and NAT translates both directions of a flow consistently.
local B = require("tsr.inet.bytes")
local W = require("tsr.inet.wire")
local ct = require("tsr.inet.fw.conntrack")

local M = {}
local FW = {}
FW.__index = FW

M.FILTER_CHAINS = { "INPUT", "FORWARD", "OUTPUT" }
M.NAT_CHAINS = { "PREROUTING", "POSTROUTING" }

local function newChain(policy) return { policy = policy, rules = {}, pkts = 0, bytes = 0 } end

--- Create the firewall for a stack and install its hooks.
function M.install(stack)
  if stack.fw then return stack.fw end
  local self = setmetatable({ stack = stack, ct = ct.new(stack), tables = { filter = {}, nat = {} }, log = {}, stats = { accepted = 0, dropped = 0, rejected = 0, nat = 0 } }, FW)
  for _, c in ipairs(M.FILTER_CHAINS) do self.tables.filter[c] = newChain("ACCEPT") end
  for _, c in ipairs(M.NAT_CHAINS) do self.tables.nat[c] = newChain("ACCEPT") end
  stack.fw = self
  stack:addHook("prerouting", "fw-prerouting", function(s, pkt, ctx) return self:prerouting(pkt, ctx) end, 20)
  stack:addHook("input", "fw-input", function(s, pkt, ctx) return self:filterHook("INPUT", pkt, ctx) end, 50)
  stack:addHook("input", "fw-input-confirm", function(s, pkt, ctx) return self:confirm(pkt) end, 200)
  stack:addHook("forward", "fw-forward", function(s, pkt, ctx) return self:filterHook("FORWARD", pkt, ctx) end, 50)
  stack:addHook("output", "fw-output-track", function(s, pkt, ctx) return self:outputTrack(pkt, ctx) end, 10)
  stack:addHook("output", "fw-output", function(s, pkt, ctx) return self:filterHook("OUTPUT", pkt, ctx) end, 50)
  stack:addHook("postrouting", "fw-postrouting", function(s, pkt, ctx) return self:postrouting(pkt, ctx) end, 20)
  local function gc()
    if stack.fw ~= self then return end
    self.ct:gc()
    stack:after(10, gc)
  end
  stack:after(10, gc)
  return self
end

function M.uninstall(stack)
  if not stack.fw then return end
  for _, h in ipairs({ { "prerouting", "fw-prerouting" }, { "input", "fw-input" }, { "input", "fw-input-confirm" }, { "forward", "fw-forward" },
    { "output", "fw-output-track" }, { "output", "fw-output" }, { "postrouting", "fw-postrouting" } }) do stack:removeHook(h[1], h[2]) end
  stack.fw = nil
end

---------------------------------------------------------------------------------------------------------------------
-- Rules and chains
---------------------------------------------------------------------------------------------------------------------

function FW:chain(tableName, chainName)
  local t = self.tables[tableName]
  return t and t[chainName]
end

function FW:newChain(tableName, name)
  local t = self.tables[tableName]
  if not t then return nil, "no such table " .. tostring(tableName) end
  if t[name] then return nil, "chain " .. name .. " exists already" end
  t[name] = newChain(nil)
  t[name].user = true
  return t[name]
end

function FW:deleteChain(tableName, name)
  local c = self:chain(tableName, name)
  if not c or not c.user then return nil, "cannot delete " .. tostring(name) end
  if #c.rules > 0 then return nil, "chain " .. name .. " is not empty" end
  for _, other in pairs(self.tables[tableName]) do
    for _, r in ipairs(other.rules) do if r.target == name then return nil, "chain " .. name .. " is still referenced" end end
  end
  self.tables[tableName][name] = nil
  return true
end

function FW:setPolicy(tableName, chainName, policy)
  local c = self:chain(tableName, chainName)
  if not c or c.user then return nil, "policy applies to the built-in chains only" end
  if policy ~= "ACCEPT" and policy ~= "DROP" then return nil, "policy is ACCEPT or DROP" end
  c.policy = policy
  return true
end

--- Add a rule (position nil = append, number = insert before that rule number, 1-based).
function FW:addRule(tableName, chainName, rule, position)
  local c = self:chain(tableName, chainName)
  if not c then return nil, "no such chain " .. tostring(chainName) end
  rule.pkts, rule.bytes = 0, 0
  if position then table.insert(c.rules, math.max(1, math.min(position, #c.rules + 1)), rule) else c.rules[#c.rules + 1] = rule end
  return rule
end

function FW:deleteRule(tableName, chainName, which)
  local c = self:chain(tableName, chainName)
  if not c then return nil, "no such chain " .. tostring(chainName) end
  if type(which) == "number" then
    if not c.rules[which] then return nil, "no rule " .. which end
    table.remove(c.rules, which)
    return true
  end
  for i, r in ipairs(c.rules) do
    if r.spec == which then table.remove(c.rules, i) return true end
  end
  return nil, "no matching rule"
end

function FW:flush(tableName, chainName)
  local t = self.tables[tableName]
  if not t then return nil, "no such table" end
  for name, c in pairs(t) do if not chainName or chainName == name then c.rules = {} end end
  return true
end

function FW:zero()
  for _, t in pairs(self.tables) do for _, c in pairs(t) do c.pkts, c.bytes = 0, 0 for _, r in ipairs(c.rules) do r.pkts, r.bytes = 0, 0 end end end
end

---------------------------------------------------------------------------------------------------------------------
-- Matching
---------------------------------------------------------------------------------------------------------------------

local function ifaceMatches(pattern, name)
  if not pattern then return true end
  if not name then return false end
  if pattern:sub(-1) == "+" then return name:sub(1, #pattern - 1) == pattern:sub(1, -2) end
  return pattern == name
end

local function netMatches(spec, ip)
  if not spec then return true end
  local hit = B.inNet(ip, spec.net, spec.plen)
  if spec.neg then return not hit end
  return hit
end

local function portMatches(spec, port)
  if not spec then return true end
  local hit = false
  for _, r in ipairs(spec.ranges) do if port >= r[1] and port <= r[2] then hit = true break end end
  if spec.neg then return not hit end
  return hit
end

local function limitOk(self, rule)
  local l = rule.limit
  if not l then return true end
  local t = self.stack.clock()
  l.tokens = l.tokens or l.burst
  l.at = l.at or t
  l.tokens = math.min(l.burst, l.tokens + (t - l.at) * l.rate)
  l.at = t
  if l.tokens < 1 then return false end
  l.tokens = l.tokens - 1
  return true
end

local function ruleMatches(self, rule, pkt, ctx, t, state)
  if rule.proto and rule.proto ~= pkt.proto then return false end
  if not netMatches(rule.src, pkt.src) or not netMatches(rule.dst, pkt.dst) then return false end
  if rule.iin and not ifaceMatches(rule.iin, ctx.iface and ctx.iface.name) then return false end
  if rule.iout and not ifaceMatches(rule.iout, ctx.out and ctx.out.name or (ctx.iface and ctx.iface.name)) then return false end
  if rule.sport or rule.dport then
    if not t or (pkt.proto ~= W.PROTO_TCP and pkt.proto ~= W.PROTO_UDP) then return false end
    if not portMatches(rule.sport, t.sport) or not portMatches(rule.dport, t.dport) then return false end
  end
  if rule.state and not rule.state[state or "INVALID"] then return false end
  if rule.tcpFlags then
    if not t or pkt.proto ~= W.PROTO_TCP then return false end
    if bit32.band(t.flags or 0, rule.tcpFlags.mask) ~= rule.tcpFlags.comp then return false end
  end
  if rule.icmpType then
    if pkt.proto ~= W.PROTO_ICMP or #pkt.payload < 1 or pkt.payload:byte(1) ~= rule.icmpType then return false end
  end
  if rule.connlimit then
    if self.ct:countFrom(pkt.src) <= rule.connlimit then return false end
  end
  if rule.limit and not limitOk(self, rule) then return false end
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- Targets
---------------------------------------------------------------------------------------------------------------------

local function reject(self, pkt, how)
  self.stats.rejected = self.stats.rejected + 1
  local stack = self.stack
  if pkt.proto == W.PROTO_TCP and #pkt.payload >= 20 and (how == nil or how == "tcp-reset") then
    local pl = pkt.payload
    local flags = pl:byte(14) % 64
    if flags % 8 >= 4 then return end                                    -- never answer a reset
    local seq, ack = B.rd32(pl, 5), B.rd32(pl, 9)
    local dataLen = #pl - math.floor(pl:byte(13) / 16) * 4
    local len = dataLen + (flags % 4 >= 2 and 1 or 0) + (flags % 2 >= 1 and 1 or 0)
    local seg
    if flags % 32 >= 16 then
      seg = { sport = B.rd16(pl, 3), dport = B.rd16(pl, 1), seq = ack, ack = 0, flags = W.RST, window = 0 }
    else
      seg = { sport = B.rd16(pl, 3), dport = B.rd16(pl, 1), seq = 0, ack = B.seqAdd(seq, len), flags = W.RST + W.ACK, window = 0 }
    end
    stack:ipSend({ src = pkt.dst, dst = pkt.src, proto = W.PROTO_TCP, payload = W.tcpEncode(pkt.dst, pkt.src, seg) })
    return
  end
  local code = W.UNREACH_PORT
  if how == "icmp-host-unreachable" then code = W.UNREACH_HOST elseif how == "icmp-net-unreachable" then code = W.UNREACH_NET
  elseif how == "icmp-admin-prohibited" then code = W.UNREACH_ADMIN elseif how == "icmp-proto-unreachable" then code = W.UNREACH_PROTO end
  if pkt.header == nil then pkt.header = W.ipEncode(pkt):sub(1, (pkt.ihl or 5) * 4) end
  stack:icmpError(pkt, W.ICMP_UNREACH, code)
end

local function logPacket(self, rule, pkt, t, chain)
  local line = ("%s%s IN=%s SRC=%s DST=%s PROTO=%d%s"):format(rule.logPrefix or "", chain, "", B.ipStr(pkt.src), B.ipStr(pkt.dst), pkt.proto,
    t and t.dport ~= 0 and (" SPT=" .. t.sport .. " DPT=" .. t.dport) or "")
  self.log[#self.log + 1] = line
  if #self.log > 200 then table.remove(self.log, 1) end
  if self.stack.logger then self.stack.logger("firewall: " .. line) end
end

--- Walk a chain. Returns "ACCEPT", "DROP" or nil (fell off the end: use the policy of the calling built-in chain).
local function walk(self, tableName, chainName, pkt, ctx, t, state, depth)
  if depth > 8 then return "DROP" end
  local chain = self.tables[tableName][chainName]
  if not chain then return nil end
  chain.pkts = chain.pkts + 1
  for _, rule in ipairs(chain.rules) do
    if ruleMatches(self, rule, pkt, ctx, t, state) then
      rule.pkts = rule.pkts + 1
      rule.bytes = rule.bytes + #pkt.payload + 20
      local target = rule.target
      if target == "ACCEPT" then return "ACCEPT"
      elseif target == "DROP" then return "DROP"
      elseif target == "REJECT" then reject(self, pkt, rule.rejectWith) return "DROP"
      elseif target == "LOG" then logPacket(self, rule, pkt, t, chainName)
      elseif target == "RETURN" then return nil
      elseif target ~= nil and self.tables[tableName][target] then
        local r = walk(self, tableName, target, pkt, ctx, t, state, depth + 1)
        if r then return r end
      else
        -- nat targets are handled by the nat hooks; a rule with an unknown target does nothing
        return nil, rule
      end
    end
  end
  return nil
end

---------------------------------------------------------------------------------------------------------------------
-- Hooks
---------------------------------------------------------------------------------------------------------------------

--- Rewrite the quoted packet inside an ICMP error that belongs to a source-NATed flow, so that the sender behind the NAT understands it.
local function untranslateIcmpError(self, pkt, entry)
  local pl = pkt.payload
  if #pl < 8 + 20 then return end
  local ihl = (pl:byte(9) % 16) * 4
  local inner = pl:sub(9)
  if #inner < ihl + 4 then return end
  local newSrc, newSport = entry.orig.src, entry.orig.sport
  local innerIp = inner:sub(1, ihl)
  innerIp = innerIp:sub(1, 12) .. B.u32(newSrc) .. innerIp:sub(17)
  innerIp = innerIp:sub(1, 10) .. "\0\0" .. innerIp:sub(13)
  innerIp = innerIp:sub(1, 10) .. B.u16(B.checksum(innerIp)) .. innerIp:sub(13)
  local transport = inner:sub(ihl + 1)
  if entry.proto == W.PROTO_TCP or entry.proto == W.PROTO_UDP then transport = B.u16(newSport) .. transport:sub(3)
  elseif entry.proto == W.PROTO_ICMP and #transport >= 8 then transport = transport:sub(1, 4) .. B.u16(newSport) .. transport:sub(7) end
  local body = pl:sub(1, 8):sub(1, 2) .. "\0\0" .. pl:sub(5, 8) .. innerIp .. transport
  body = body:sub(1, 2) .. B.u16(B.checksum(body)) .. body:sub(5)
  pkt.payload = body
  pkt.dst = entry.orig.src
  pkt.dirty = true
end

--- Work out the state of a packet and apply the translation of an existing flow. Sets pkt.fw = { entry, dir, state, t }.
function FW:trackIncoming(pkt, ctx, fromOutput)
  local t = ct.tuple(pkt)
  local info = { t = t, state = "INVALID" }
  pkt.fw = info
  if not t then
    info.state = "NEW"
    return info
  end
  -- ICMP errors belong to the flow they talk about
  if t.error then
    local pl = pkt.payload
    if #pl >= 8 + 20 and (t.icmpType == W.ICMP_UNREACH or t.icmpType == W.ICMP_TIME_EXCEEDED or t.icmpType == W.ICMP_REDIRECT) then
      local q = require("tsr.inet.icmp").quoted(pl:sub(9))
      if q and #q.transport >= 4 then
        local sp, dp = B.rd16(q.transport, 1), B.rd16(q.transport, 3)
        if q.proto == W.PROTO_ICMP and #q.transport >= 8 then sp = B.rd16(q.transport, 5) dp = sp end
        local entry = self.ct:lookup({ proto = q.proto, src = q.dst, sport = dp, dst = q.src, dport = sp })
          or self.ct:lookup({ proto = q.proto, src = q.src, sport = sp, dst = q.dst, dport = dp })
        if entry then
          info.state = "RELATED"
          info.entry = entry
          if entry.snat and not fromOutput then untranslateIcmpError(self, pkt, entry) end
          return info
        end
      end
    end
    info.state = "INVALID"
    return info
  end
  local entry, dir = self.ct:lookup(t)
  if entry then
    info.entry, info.dir = entry, dir
    self.ct:update(entry, t, dir, #pkt.payload)
    info.state = entry.state
    if dir == "reply" then
      -- undo the translations on the way back (also for packets this computer itself sends in reply to a redirected flow)
      local c = {}
      if entry.snat and not fromOutput then c.dst, c.dport = entry.orig.src, entry.orig.sport end
      if entry.dnat then c.src, c.sport = entry.orig.dst, entry.orig.dport end
      if next(c) then ct.rewrite(pkt, c) end
    elseif entry.dnat and not fromOutput then
      ct.rewrite(pkt, { dst = entry.dnat.ip, dport = entry.dnat.port })
    end
    return info
  end
  -- a new flow: a TCP flow must start with a SYN
  if t.proto == W.PROTO_TCP and not (t.flags % 4 >= 2 and t.flags % 32 < 16) then
    self.ct.stats.invalid = self.ct.stats.invalid + 1
    info.state = "INVALID"
    return info
  end
  info.state = "NEW"
  info.entry = self.ct:track(t)
  info.dir = "orig"
  info.fresh = true
  self.ct:update(info.entry, t, "orig", #pkt.payload)
  info.entry.state = "NEW"
  return info
end

function FW:prerouting(pkt, ctx)
  local lo = ctx.iface and ctx.iface.kind == "loopback"
  if lo then pkt.fw = { state = "NEW", t = ct.tuple(pkt), loopback = true } return end
  local info = self:trackIncoming(pkt, ctx, false)
  if info.fresh and info.entry then
    -- destination NAT for new flows
    local chain = self.tables.nat.PREROUTING
    for _, rule in ipairs(chain.rules) do
      if (rule.target == "DNAT" or rule.target == "REDIRECT") and ruleMatches(self, rule, pkt, ctx, info.t, "NEW") then
        rule.pkts = rule.pkts + 1
        local ip, port
        if rule.target == "REDIRECT" then
          ip = ctx.iface.addrs[1] and ctx.iface.addrs[1].ip or pkt.dst
          port = rule.toPort
        else
          ip, port = rule.toIp, rule.toPort
        end
        local e = info.entry
        e.dnat = { ip = ip, port = port or info.t.dport }
        e.reply.src, e.reply.sport = e.dnat.ip, e.dnat.port
        ct.rewrite(pkt, { dst = e.dnat.ip, dport = port })
        self.stats.nat = self.stats.nat + 1
        break
      end
    end
  end
end

function FW:filterHook(chainName, pkt, ctx)
  local info = pkt.fw or { state = "NEW", t = ct.tuple(pkt) }
  local verdict = walk(self, "filter", chainName, pkt, ctx, info.t, info.state, 0)
  local chain = self.tables.filter[chainName]
  if not verdict then verdict = chain.policy end
  if verdict == "DROP" then
    self.stats.dropped = self.stats.dropped + 1
    if info.entry and info.fresh then self.ct:remove(info.entry) end
    return "drop"
  end
  self.stats.accepted = self.stats.accepted + 1
end

function FW:confirm(pkt)
  local info = pkt.fw
  if info and info.entry and info.fresh and not info.loopback then
    if not self.ct:confirm(info.entry) then return "drop" end
    info.fresh = false
  end
end

function FW:outputTrack(pkt, ctx)
  if ctx.iface and ctx.iface.kind == "loopback" then pkt.fw = { state = "NEW", t = ct.tuple(pkt), loopback = true } return end
  local info = self:trackIncoming(pkt, ctx, true)
  if info.state == "INVALID" and not info.entry then info.state = "NEW" end       -- locally generated packets are never invalid
end

--- Pick a source port for SNAT that does not clash with another flow to the same destination.
local function allocPort(self, e, ip, want)
  local function free(p) return self.ct:replyFree(e.proto, e.reply.src, e.reply.sport, ip, p) end
  if want and free(want) then return want end
  local base = 1024 + (self.nextNatPort or 0)
  for i = 0, 64511 do
    local p = 1024 + (base - 1024 + i) % 64512
    if free(p) then self.nextNatPort = (p - 1024 + 1) % 64512 return p end
  end
  return nil
end

function FW:postrouting(pkt, ctx)
  local info = pkt.fw
  if not info or info.loopback or not info.entry then return end
  local e = info.entry
  if info.fresh then
    for _, rule in ipairs(self.tables.nat.POSTROUTING.rules) do
      if (rule.target == "MASQUERADE" or rule.target == "SNAT") and ruleMatches(self, rule, pkt, ctx, info.t, "NEW") then
        rule.pkts = rule.pkts + 1
        local ip
        if rule.target == "MASQUERADE" then ip = ctx.out and ctx.out.addrs[1] and ctx.out.addrs[1].ip else ip = rule.toIp end
        if not ip then break end
        local port = nil
        if e.proto == W.PROTO_TCP or e.proto == W.PROTO_UDP or e.proto == W.PROTO_ICMP then
          port = allocPort(self, e, ip, e.orig.sport)
          if not port then return "drop" end
        end
        if ip ~= e.orig.src or port ~= e.orig.sport then
          e.snat = { ip = ip, port = port or e.orig.sport }
          e.reply.dst, e.reply.dport = ip, port or e.orig.sport
          ct.rewrite(pkt, { src = ip, sport = port })
          self.stats.nat = self.stats.nat + 1
        end
        break
      end
    end
    if not self.ct:confirm(e) then return "drop" end
    info.fresh = false
  elseif info.dir == "orig" and e.snat then
    ct.rewrite(pkt, { src = e.snat.ip, sport = e.snat.port })
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Listing
---------------------------------------------------------------------------------------------------------------------

function FW:flows()
  local out = {}
  for _, e in ipairs(self.ct:list()) do
    out[#out + 1] = {
      proto = e.proto == W.PROTO_TCP and "tcp" or e.proto == W.PROTO_UDP and "udp" or e.proto == W.PROTO_ICMP and "icmp" or tostring(e.proto),
      state = e.proto == W.PROTO_TCP and e.tcp or (e.replied and "ESTABLISHED" or "UNREPLIED"), orig = e.orig, reply = e.reply, snat = e.snat, dnat = e.dnat,
      packets = e.packets, expires = math.floor(e.expires - self.stack.clock()),
    }
  end
  return out
end

return M
