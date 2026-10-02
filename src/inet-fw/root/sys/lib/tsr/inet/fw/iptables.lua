-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The iptables command language (the useful subset) for tsr.inet.fw:
--   iptables [-t filter|nat] -A|-I CHAIN [n] <match...> -j TARGET [target options]      add / insert a rule
--   iptables [-t table] -D CHAIN n | <rule spec>    -F [CHAIN]   -N CHAIN   -X CHAIN   -P CHAIN ACCEPT|DROP   -Z   -L [CHAIN] [-n] [-v]   -S
-- matches:  -p tcp|udp|icmp|N  -s ADDR[/N]  -d ADDR[/N]  -i IF  -o IF  (IF may end in +)  --sport P[:Q]  --dport P[:Q]  -m multiport --dports a,b,c:d
--           -m state --state NEW,ESTABLISHED,RELATED,INVALID   (or -m conntrack --ctstate)  --syn  --tcp-flags MASK COMP  --icmp-type echo-request
--           -m limit --limit 5/second [--limit-burst 10]   -m connlimit --connlimit-above N      a leading ! negates addresses and ports
-- targets:  ACCEPT DROP REJECT [--reject-with ...] LOG [--log-prefix X] RETURN  MASQUERADE [--to-ports a]  SNAT --to-source IP[:port]
--           DNAT --to-destination IP[:port]  REDIRECT --to-ports N  or the name of a chain you made with -N
local B = require("tsr.inet.bytes")
local W = require("tsr.inet.wire")

local M = {}

local PROTOS = { tcp = 6, udp = 17, icmp = 1, all = false }
local PROTO_NAMES = { [6] = "tcp", [17] = "udp", [1] = "icmp" }
local ICMP_TYPES = { ["echo-reply"] = 0, ["destination-unreachable"] = 3, ["echo-request"] = 8, ["time-exceeded"] = 11, ["redirect"] = 5 }
local ICMP_NAMES = {}
for k, v in pairs(ICMP_TYPES) do ICMP_NAMES[v] = k end

--- Split a line into words; "double quoted" text stays together.
function M.tokenize(line)
  local out = {}
  local i = 1
  while i <= #line do
    local c = line:sub(i, i)
    if c:match("%s") then i = i + 1
    elseif c == '"' then
      local j = line:find('"', i + 1, true) or (#line + 1)
      out[#out + 1] = line:sub(i + 1, j - 1)
      i = j + 1
    else
      local j = i
      while j <= #line and not line:sub(j, j):match("%s") do j = j + 1 end
      out[#out + 1] = line:sub(i, j - 1)
      i = j
    end
  end
  return out
end

local function parsePorts(text)
  local ranges = {}
  for part in text:gmatch("[^,]+") do
    local a, b = part:match("^(%d+):(%d+)$")
    if a then ranges[#ranges + 1] = { tonumber(a), tonumber(b) }
    elseif part:match("^%d+$") then ranges[#ranges + 1] = { tonumber(part), tonumber(part) }
    else return nil end
  end
  if #ranges == 0 then return nil end
  return { ranges = ranges }
end

local function parseNet(text)
  local net, plen = B.cidr(text)
  if not net then return nil end
  return { net = net, plen = plen, text = text }
end

local function parseTo(text)
  local ip, port = text:match("^([%d%.]+):?(%d*)$")
  local a = ip and B.ip(ip)
  if not a then return nil end
  return a, port ~= "" and tonumber(port) or nil
end

--- Parse the match and target part of a rule (everything after the chain). Returns a rule table or nil + reason.
function M.parseRule(tokens, from)
  local rule = {}
  local i = from or 1
  local negate = false
  local function value()
    i = i + 1
    local v = tokens[i]
    if v == "!" then negate = true i = i + 1 v = tokens[i] end
    return v
  end
  while i <= #tokens do
    local t = tokens[i]
    if t == "!" then
      negate = true
    elseif t == "-p" or t == "--protocol" then
      local v = value()
      local n = PROTOS[v] if n == nil then n = tonumber(v) end
      if n == nil then return nil, "unknown protocol " .. tostring(v) end
      rule.proto = n or nil
      if negate then return nil, "! -p is not supported" end
    elseif t == "-s" or t == "--source" then
      local v = value()
      local n = v and parseNet(v)
      if not n then return nil, "bad source " .. tostring(v) end
      n.neg = negate
      rule.src = n
    elseif t == "-d" or t == "--destination" then
      local v = value()
      local n = v and parseNet(v)
      if not n then return nil, "bad destination " .. tostring(v) end
      n.neg = negate
      rule.dst = n
    elseif t == "-i" or t == "--in-interface" then rule.iin = value()
    elseif t == "-o" or t == "--out-interface" then rule.iout = value()
    elseif t == "--sport" or t == "--source-port" or t == "--sports" or t == "--source-ports" then
      local v = value()
      rule.sport = v and parsePorts(v)
      if not rule.sport then return nil, "bad source port " .. tostring(v) end
      rule.sport.neg = negate
    elseif t == "--dport" or t == "--destination-port" or t == "--dports" or t == "--destination-ports" then
      local v = value()
      rule.dport = v and parsePorts(v)
      if not rule.dport then return nil, "bad destination port " .. tostring(v) end
      rule.dport.neg = negate
    elseif t == "-m" or t == "--match" then
      i = i + 1                                         -- the module name: state, conntrack, tcp, udp, icmp, limit, multiport, connlimit
    elseif t == "--state" or t == "--ctstate" then
      local v = value()
      rule.state = {}
      for s in tostring(v):gmatch("[^,]+") do
        s = s:upper()
        if s ~= "NEW" and s ~= "ESTABLISHED" and s ~= "RELATED" and s ~= "INVALID" then return nil, "unknown state " .. s end
        rule.state[s] = true
      end
    elseif t == "--syn" then
      rule.tcpFlags = { mask = W.SYN + W.RST + W.ACK + W.FIN, comp = W.SYN }
    elseif t == "--tcp-flags" then
      local names = { SYN = W.SYN, ACK = W.ACK, FIN = W.FIN, RST = W.RST, PSH = W.PSH, URG = W.URG }
      local function mask(v)
        local m = 0
        if v == "ALL" then return 63 end
        if v == "NONE" then return 0 end
        for n in tostring(v):gmatch("[^,]+") do if not names[n] then return nil end m = m + names[n] end
        return m
      end
      local m, c = mask(value()), mask(value())
      if not m or not c then return nil, "bad --tcp-flags" end
      rule.tcpFlags = { mask = m, comp = c }
    elseif t == "--icmp-type" then
      local v = value()
      rule.icmpType = ICMP_TYPES[v] or tonumber(v)
      if not rule.icmpType then return nil, "unknown ICMP type " .. tostring(v) end
    elseif t == "--limit" then
      local v = value()
      local n, unit = tostring(v):match("^(%d+)/?(%a*)$")
      if not n then return nil, "bad --limit" end
      local per = ({ second = 1, sec = 1, s = 1, minute = 60, min = 60, m = 60, hour = 3600, h = 3600, day = 86400, d = 86400 })[unit == "" and "second" or unit]
      if not per then return nil, "bad --limit unit" end
      rule.limit = rule.limit or { burst = 5 }
      rule.limit.rate = tonumber(n) / per
      rule.limit.spec = v
    elseif t == "--limit-burst" then
      rule.limit = rule.limit or { rate = 1 }
      rule.limit.burst = tonumber(value()) or 5
    elseif t == "--connlimit-above" then rule.connlimit = tonumber(value())
    elseif t == "-j" or t == "--jump" or t == "-g" then
      rule.target = value()
      if not rule.target then return nil, "missing target" end
    elseif t == "--to-destination" then
      local ip, port = parseTo(value() or "")
      if not ip then return nil, "bad --to-destination" end
      rule.toIp, rule.toPort = ip, port
    elseif t == "--to-source" then
      local ip, port = parseTo(value() or "")
      if not ip then return nil, "bad --to-source" end
      rule.toIp, rule.toPort = ip, port
    elseif t == "--to-ports" then
      rule.toPort = tonumber((tostring(value()):match("^(%d+)")))
    elseif t == "--reject-with" then rule.rejectWith = value()
    elseif t == "--log-prefix" then rule.logPrefix = value()
    elseif t:sub(1, 1) == "-" then
      return nil, "unknown option " .. t
    else
      return nil, "unexpected " .. t
    end
    if t ~= "!" then negate = false end
    i = i + 1
  end
  if not rule.target then return nil, "a rule needs a target (-j)" end
  return rule
end

local function netText(n) return (n.neg and "! " or "") .. B.cidrStr(n.net, n.plen) end
local function portText(p)
  local parts = {}
  for _, r in ipairs(p.ranges) do parts[#parts + 1] = r[1] == r[2] and tostring(r[1]) or (r[1] .. ":" .. r[2]) end
  return (p.neg and "! " or "") .. table.concat(parts, ",")
end

--- The iptables text of a rule (what -S prints and what saved files contain).
function M.ruleText(rule)
  local p = {}
  if rule.proto then p[#p + 1] = "-p " .. (PROTO_NAMES[rule.proto] or rule.proto) end
  if rule.src then p[#p + 1] = "-s " .. netText(rule.src) end
  if rule.dst then p[#p + 1] = "-d " .. netText(rule.dst) end
  if rule.iin then p[#p + 1] = "-i " .. rule.iin end
  if rule.iout then p[#p + 1] = "-o " .. rule.iout end
  if rule.sport then p[#p + 1] = "--sport " .. portText(rule.sport) end
  if rule.dport then p[#p + 1] = "--dport " .. portText(rule.dport) end
  if rule.state then
    local s = {}
    for _, n in ipairs({ "NEW", "ESTABLISHED", "RELATED", "INVALID" }) do if rule.state[n] then s[#s + 1] = n end end
    p[#p + 1] = "-m state --state " .. table.concat(s, ",")
  end
  if rule.tcpFlags then p[#p + 1] = ("--tcp-flags %d %d"):format(rule.tcpFlags.mask, rule.tcpFlags.comp) end
  if rule.icmpType then p[#p + 1] = "--icmp-type " .. (ICMP_NAMES[rule.icmpType] or rule.icmpType) end
  if rule.limit then p[#p + 1] = "-m limit --limit " .. (rule.limit.spec or (rule.limit.rate .. "/second")) .. " --limit-burst " .. rule.limit.burst end
  if rule.connlimit then p[#p + 1] = "-m connlimit --connlimit-above " .. rule.connlimit end
  p[#p + 1] = "-j " .. rule.target
  if rule.target == "DNAT" then p[#p + 1] = "--to-destination " .. B.ipStr(rule.toIp) .. (rule.toPort and (":" .. rule.toPort) or "") end
  if rule.target == "SNAT" then p[#p + 1] = "--to-source " .. B.ipStr(rule.toIp) .. (rule.toPort and (":" .. rule.toPort) or "") end
  if (rule.target == "REDIRECT" or rule.target == "MASQUERADE") and rule.toPort then p[#p + 1] = "--to-ports " .. rule.toPort end
  if rule.rejectWith then p[#p + 1] = "--reject-with " .. rule.rejectWith end
  if rule.logPrefix then p[#p + 1] = '--log-prefix "' .. rule.logPrefix .. '"' end
  return table.concat(p, " ")
end

local NAT_TARGETS = { MASQUERADE = true, SNAT = true, DNAT = true, REDIRECT = true }

--- Execute one iptables command (a list of words without the leading "iptables"). ctx.say / ctx.err print. Returns true or false.
function M.exec(fw, args, ctx)
  ctx = ctx or { say = print, err = print }
  local tableName = "filter"
  local words = {}
  local i = 1
  while i <= #args do
    if args[i] == "-t" or args[i] == "--table" then tableName = args[i + 1] i = i + 2
    else words[#words + 1] = args[i] i = i + 1 end
  end
  if not fw.tables[tableName] then ctx.err("iptables: no table named " .. tostring(tableName)) return false end
  local cmd = words[1]
  local function fail(msg) ctx.err("iptables: " .. msg) return false end
  if cmd == "-A" or cmd == "--append" or cmd == "-I" or cmd == "--insert" then
    local chain = words[2]
    if not chain then return fail("missing chain") end
    local pos, from = nil, 3
    if cmd == "-I" or cmd == "--insert" then
      if tonumber(words[3]) then pos, from = tonumber(words[3]), 4 else pos = 1 end
    end
    local rule, err = M.parseRule(words, from)
    if not rule then return fail(err) end
    if NAT_TARGETS[rule.target] and tableName ~= "nat" then return fail(rule.target .. " belongs in the nat table (-t nat)") end
    if (rule.target == "DNAT" or rule.target == "REDIRECT") and chain ~= "PREROUTING" then return fail(rule.target .. " works in PREROUTING") end
    if (rule.target == "SNAT" or rule.target == "MASQUERADE") and chain ~= "POSTROUTING" then return fail(rule.target .. " works in POSTROUTING") end
    if rule.target == "DNAT" and not rule.toIp then return fail("DNAT needs --to-destination") end
    if rule.target == "SNAT" and not rule.toIp then return fail("SNAT needs --to-source") end
    if not NAT_TARGETS[rule.target] and rule.target ~= "ACCEPT" and rule.target ~= "DROP" and rule.target ~= "REJECT" and rule.target ~= "LOG" and rule.target ~= "RETURN"
      and not fw.tables[tableName][rule.target] then
      return fail("no chain/target named " .. rule.target)
    end
    rule.spec = M.ruleText(rule)
    local ok, e = fw:addRule(tableName, chain, rule, pos)
    if not ok then return fail(e) end
    return true
  elseif cmd == "-D" or cmd == "--delete" then
    local chain = words[2]
    if not chain then return fail("missing chain") end
    local which = tonumber(words[3])
    if not which then
      local rule, err = M.parseRule(words, 3)
      if not rule then return fail(err) end
      which = M.ruleText(rule)
    end
    local ok, e = fw:deleteRule(tableName, chain, which)
    if not ok then return fail(e) end
    return true
  elseif cmd == "-F" or cmd == "--flush" then
    local ok, e = fw:flush(tableName, words[2])
    if not ok then return fail(e) end
    return true
  elseif cmd == "-N" or cmd == "--new-chain" then
    local ok, e = fw:newChain(tableName, words[2] or "")
    if not ok then return fail(e) end
    return true
  elseif cmd == "-X" or cmd == "--delete-chain" then
    local ok, e = fw:deleteChain(tableName, words[2] or "")
    if not ok then return fail(e) end
    return true
  elseif cmd == "-P" or cmd == "--policy" then
    local ok, e = fw:setPolicy(tableName, words[2] or "", words[3] or "")
    if not ok then return fail(e) end
    return true
  elseif cmd == "-Z" or cmd == "--zero" then fw:zero() return true
  elseif cmd == "-S" or cmd == "--list-rules" then
    local names = {}
    for name in pairs(fw.tables[tableName]) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      local c = fw.tables[tableName][name]
      if (not words[2]) or words[2] == name then
        ctx.say(c.user and ("-N " .. name) or ("-P " .. name .. " " .. c.policy))
      end
    end
    for _, name in ipairs(names) do
      if (not words[2]) or words[2] == name then for _, r in ipairs(fw.tables[tableName][name].rules) do ctx.say("-A " .. name .. " " .. (r.spec or M.ruleText(r))) end end
    end
    return true
  elseif cmd == "-L" or cmd == "--list" then
    local verbose, numeric, only = false, true, nil
    for k = 2, #words do
      local w = words[k]
      if w == "-v" or w == "--verbose" then verbose = true
      elseif w == "-n" or w == "--numeric" then numeric = true
      elseif w == "-vn" or w == "-nv" then verbose = true
      elseif w:sub(1, 1) ~= "-" then only = w end
    end
    local names = {}
    for name in pairs(fw.tables[tableName]) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      if not only or only == name then
        local c = fw.tables[tableName][name]
        ctx.say(("Chain %s (%s)"):format(name, c.user and "1 references" or ("policy " .. c.policy .. (verbose and (" " .. c.pkts .. " packets") or ""))))
        ctx.say(("%s%-10s %-5s %-19s %-19s %s"):format(verbose and " pkts bytes " or "", "target", "prot", "source", "destination", ""))
        for n, r in ipairs(c.rules) do
          local opts = {}
          if r.state then local s = {} for _, nm in ipairs({ "NEW", "ESTABLISHED", "RELATED", "INVALID" }) do if r.state[nm] then s[#s + 1] = nm end end opts[#opts + 1] = "state " .. table.concat(s, ",") end
          if r.sport then opts[#opts + 1] = "spt:" .. portText(r.sport) end
          if r.dport then opts[#opts + 1] = "dpt:" .. portText(r.dport) end
          if r.iin then opts[#opts + 1] = "in " .. r.iin end
          if r.iout then opts[#opts + 1] = "out " .. r.iout end
          if r.icmpType then opts[#opts + 1] = "icmptype " .. (ICMP_NAMES[r.icmpType] or r.icmpType) end
          if r.limit then opts[#opts + 1] = "limit " .. (r.limit.spec or "") end
          if r.target == "DNAT" or r.target == "SNAT" then opts[#opts + 1] = "to:" .. B.ipStr(r.toIp) .. (r.toPort and (":" .. r.toPort) or "") end
          ctx.say(("%s%-10s %-5s %-19s %-19s %s"):format(verbose and ("%5d %5d "):format(r.pkts, r.bytes) or "", r.target, r.proto and (PROTO_NAMES[r.proto] or r.proto) or "all",
            r.src and netText(r.src) or "anywhere", r.dst and netText(r.dst) or "anywhere", table.concat(opts, " ")))
        end
      end
    end
    return true
  end
  return fail("unknown command " .. tostring(cmd) .. " (try -A, -I, -D, -F, -N, -X, -P, -L, -S, -Z)")
end

--- Apply a file of iptables commands ("-A INPUT ..." / "iptables -A ..."; one per line; # comments; a line "-t nat" may start a command). Returns problems.
function M.load(fw, text)
  local problems = {}
  local n = 0
  for line in ((text or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    n = n + 1
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local words = M.tokenize(line)
      if words[1] == "iptables" then table.remove(words, 1) end
      local errs = {}
      local ok = M.exec(fw, words, { say = function() end, err = function(t) errs[#errs + 1] = t end })
      if not ok then problems[#problems + 1] = ("line %d: %s"):format(n, errs[1] or "failed") end
    end
  end
  return problems
end

--- The whole rule set as text that M.load reads back.
function M.save(fw)
  local out = {}
  for _, tableName in ipairs({ "filter", "nat" }) do
    local names = {}
    for name in pairs(fw.tables[tableName]) do names[#names + 1] = name end
    table.sort(names)
    local prefix = tableName == "nat" and "-t nat " or ""
    for _, name in ipairs(names) do
      local c = fw.tables[tableName][name]
      if c.user then out[#out + 1] = prefix .. "-N " .. name elseif c.policy ~= "ACCEPT" then out[#out + 1] = prefix .. "-P " .. name .. " " .. c.policy end
    end
    for _, name in ipairs(names) do
      for _, r in ipairs(fw.tables[tableName][name].rules) do out[#out + 1] = prefix .. "-A " .. name .. " " .. (r.spec or M.ruleText(r)) end
    end
  end
  return table.concat(out, "\n") .. (#out > 0 and "\n" or "")
end

return M
