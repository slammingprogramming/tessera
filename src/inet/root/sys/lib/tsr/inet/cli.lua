-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Command line tools for the network stack. Each function takes the argument list and a context { stack, say, err, idle } (all optional: the
-- defaults print to the terminal and use the running stack), so the tools can be tested against a simulated network.
--   ip addr | link | route | neigh | save              show and change addresses, interfaces, routes, neighbours (ARP)
--   ping <host> [-c n] [-t ttl] [-s size] [-W seconds]
--   traceroute <host> [-m hops] [-w seconds] [-q probes]
--   netstat [-t] [-u] [-l] [-s] [-r] [-i]
--   tcpdump [-i iface] [-c n] [-e] [-x] [-w file | -r file] [filter...]
--   nc [-l] [-u] [-z] [-w seconds] <host> <port>        (nc -l <port> to listen)
local B = require("tsr.inet.bytes")
local W = require("tsr.inet.wire")
local ICMP = require("tsr.inet.icmp")
local dissect = require("tsr.inet.dissect")
local config = require("tsr.inet.config")
local tcpm = require("tsr.inet.tcp")

local M = {}

local function defaultCtx(ctx)
  ctx = ctx or {}
  if not ctx.say then
    ctx.say = function(t) print(t) end
    ctx.err = function(t)
      if term and term.isColor and term.isColor() then term.setTextColor(colors.red) end
      print(t)
      if term and term.setTextColor then term.setTextColor(colors.white) end
    end
  end
  ctx.err = ctx.err or ctx.say
  if not ctx.stack then
    local ok, stack = pcall(function() return require("tsr.inet.socket").default() end)
    if not ok then ctx.err(tostring(stack)) return nil end
    ctx.stack = stack
  end
  ctx.idle = ctx.idle or function(seconds)
    local timer = os.startTimer(seconds)
    while true do
      local ev, id = os.pullEvent()
      if ev == "timer" and id == timer then return end
    end
  end
  return ctx
end

local function isAdmin(ctx)
  local okAuth, auth = pcall(require, "tsr.auth")
  if not okAuth or not auth.hasUsers() then return true end
  local me = auth.current()
  if me == nil or auth.can(me, "auth.manage") then return true end
  ctx.err("only administrators can change the network configuration")
  return false
end

local function flagsOf(iface)
  local f = {}
  if iface.up then f[#f + 1] = "UP" end
  if iface.kind == "loopback" then f[#f + 1] = "LOOPBACK" else f[#f + 1] = "BROADCAST" end
  if iface.promisc then f[#f + 1] = "PROMISC" end
  if iface.proxyArp then f[#f + 1] = "PROXYARP" end
  return table.concat(f, ",")
end

---------------------------------------------------------------------------------------------------------------------
-- ip
---------------------------------------------------------------------------------------------------------------------

local function showAddr(stack, ctx, only)
  for i, iface in ipairs(stack.ifaceList) do
    if not only or iface.name == only then
      ctx.say(("%d: %s: <%s> mtu %d%s"):format(i, iface.name, flagsOf(iface), iface.mtu, iface.kind ~= "loopback" and (" link/ether " .. B.macStr(iface.mac)) or ""))
      if iface.parent then ctx.say("    vlan " .. iface.vlan .. " on " .. iface.parent) end
      for _, a in ipairs(iface.addrs) do
        local brd = a.plen < 31 and iface.kind ~= "loopback" and (" brd " .. B.ipStr(B.broadcast(B.band(a.ip, B.mask(a.plen)), a.plen))) or ""
        ctx.say(("    inet %s/%d%s"):format(B.ipStr(a.ip), a.plen, brd))
      end
    end
  end
end

local function showLink(stack, ctx, stats)
  for i, iface in ipairs(stack.ifaceList) do
    ctx.say(("%d: %s: <%s> mtu %d %s"):format(i, iface.name, flagsOf(iface), iface.mtu, iface.up and "state UP" or "state DOWN"))
    if stats then
      local s = iface.stats
      ctx.say(("    RX: %d packets %d bytes %d errors %d dropped"):format(s.rxPackets, s.rxBytes, s.rxErrors, s.rxDropped))
      ctx.say(("    TX: %d packets %d bytes %d errors"):format(s.txPackets, s.txBytes, s.txErrors))
    end
  end
end

local function routeText(r)
  local dest = r.plen == 0 and "default" or B.cidrStr(r.net, r.plen)
  local parts = { dest }
  if r.gateway then parts[#parts + 1] = "via " .. B.ipStr(r.gateway) end
  parts[#parts + 1] = "dev " .. r.iface
  parts[#parts + 1] = "proto " .. r.proto
  if r.src then parts[#parts + 1] = "src " .. B.ipStr(r.src) end
  parts[#parts + 1] = "metric " .. r.metric
  return table.concat(parts, " ")
end

local function showRoutes(stack, ctx)
  local list = {}
  for _, r in ipairs(stack.routes) do list[#list + 1] = r end
  table.sort(list, function(a, b) if a.plen ~= b.plen then return a.plen > b.plen end if a.net ~= b.net then return a.net < b.net end return a.metric < b.metric end)
  for _, r in ipairs(list) do ctx.say(routeText(r)) end
end

local function findOpt(args, name, from)
  for i = from or 3, #args do
    if args[i] == name then return args[i + 1] end
  end
end

function M.ip(args, ctx)
  ctx = defaultCtx(ctx)
  if not ctx then return false end
  local stack = ctx.stack
  local stats = false
  local plain = {}
  for _, a in ipairs(args) do if a == "-s" then stats = true else plain[#plain + 1] = a end end
  args = plain
  local obj = args[1] or "addr"
  local verb = args[2] or "show"
  if obj == "addr" or obj == "address" or obj == "a" then
    if verb == "show" or verb == "list" then return showAddr(stack, ctx, findOpt(args, "dev")) or true end
    if not isAdmin(ctx) then return false end
    local cidr, dev = args[3], findOpt(args, "dev")
    local addr, plen = tostring(cidr):match("^([%d%.]+)/(%d+)$")
    if not (addr and dev and B.ip(addr)) then ctx.err("usage: ip addr add|del <a.b.c.d/n> dev <interface>") return false end
    if not stack.ifaces[dev] then ctx.err("no such interface: " .. dev) return false end
    if verb == "add" then stack:setAddress(dev, addr, tonumber(plen)) return true end
    if verb == "del" then
      if not stack:removeAddress(dev, addr) then ctx.err("that address is not on " .. dev) return false end
      return true
    end
  elseif obj == "link" or obj == "l" then
    if verb == "show" or verb == "list" then showLink(stack, ctx, stats) return true end
    if not isAdmin(ctx) then return false end
    if verb == "set" then
      local dev, state = args[3], args[4]
      if not (dev and stack.ifaces[dev]) then ctx.err("no such interface: " .. tostring(dev)) return false end
      if state == "up" or state == "down" then stack:setUp(dev, state == "up") return true end
      if state == "mtu" then stack.ifaces[dev].mtu = tonumber(args[5]) or 1500 return true end
      if state == "promisc" then stack.ifaces[dev].promisc = args[5] == "on" return true end
      ctx.err("usage: ip link set <dev> up|down|mtu <n>|promisc on|off") return false
    elseif verb == "add" and args[3] == "vlan" then
      local parent, vid = findOpt(args, "link"), tonumber(findOpt(args, "id"))
      if not (parent and vid and stack.ifaces[parent]) then ctx.err("usage: ip link add vlan link <parent> id <vid>") return false end
      stack:addVlan(parent, vid)
      return true
    elseif verb == "del" then
      return stack:removeInterface(args[3] or "") or (ctx.err("no such interface") and false)
    end
  elseif obj == "route" or obj == "r" then
    if verb == "show" or verb == "list" then showRoutes(stack, ctx) return true end
    if not isAdmin(ctx) then return false end
    local dest = args[3]
    if verb == "add" or verb == "replace" then
      local via, dev, metric = findOpt(args, "via"), findOpt(args, "dev"), tonumber(findOpt(args, "metric"))
      local r, err = stack:addRoute(dest, via, { iface = dev, metric = metric })
      if not r then ctx.err(tostring(err)) return false end
      return true
    elseif verb == "del" then
      if not stack:delRoute(dest, findOpt(args, "via")) then ctx.err("no such route") return false end
      return true
    end
  elseif obj == "neigh" or obj == "neighbour" or obj == "n" then
    if verb == "show" or verb == "list" then
      local now = stack.clock()
      for _, iface in ipairs(stack.ifaceList) do
        local ips = {}
        for ip in pairs(stack.neigh[iface.name] or {}) do ips[#ips + 1] = ip end
        table.sort(ips)
        for _, ip in ipairs(ips) do
          local e = stack.neigh[iface.name][ip]
          local state = e.static and "PERMANENT" or (e.mac and (e.expires > now and "REACHABLE" or "STALE") or "INCOMPLETE")
          ctx.say(("%s dev %s lladdr %s %s"):format(B.ipStr(ip), iface.name, e.mac and B.macStr(e.mac) or "(none)", state))
        end
      end
      return true
    end
    if not isAdmin(ctx) then return false end
    if verb == "add" then
      local ip, mac, dev = B.ip(args[3] or ""), B.mac(findOpt(args, "lladdr") or ""), findOpt(args, "dev")
      if not (ip and mac and dev and stack.ifaces[dev]) then ctx.err("usage: ip neigh add <ip> lladdr <mac> dev <interface>") return false end
      stack:addNeighbour(stack.ifaces[dev], ip, mac, true)
      return true
    elseif verb == "del" then
      local ip = B.ip(args[3] or "")
      for _, iface in ipairs(stack.ifaceList) do if ip and stack.neigh[iface.name] then stack.neigh[iface.name][ip] = nil end end
      return true
    elseif verb == "flush" then
      for _, iface in ipairs(stack.ifaceList) do
        for ip, e in pairs(stack.neigh[iface.name] or {}) do if not e.static then stack.neigh[iface.name][ip] = nil end end
      end
      return true
    end
  elseif obj == "save" then
    if not isAdmin(ctx) then return false end
    local ok, err = config.save(config.snapshot(stack))
    if not ok then ctx.err("could not save: " .. tostring(err)) return false end
    ctx.say("configuration saved to " .. config.PATH)
    return true
  elseif obj == "forward" then
    if not isAdmin(ctx) then return false end
    stack.forwarding = verb == "on" or verb == "1"
    ctx.say("IP forwarding " .. (stack.forwarding and "on" or "off"))
    return true
  end
  ctx.err("usage: ip addr|link|route|neigh|save|forward ... (see `thelp network`)")
  return false
end

---------------------------------------------------------------------------------------------------------------------
-- ping, traceroute
---------------------------------------------------------------------------------------------------------------------

function M.ping(args, ctx)
  ctx = defaultCtx(ctx)
  if not ctx then return false end
  local stack = ctx.stack
  local host, count, ttl, size, timeout, interval = nil, 4, nil, 32, 2, 1
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "-c" then i = i + 1 count = tonumber(args[i]) or 4
    elseif a == "-t" then i = i + 1 ttl = tonumber(args[i])
    elseif a == "-s" then i = i + 1 size = tonumber(args[i]) or 32
    elseif a == "-W" then i = i + 1 timeout = tonumber(args[i]) or 2
    elseif a == "-i" then i = i + 1 interval = tonumber(args[i]) or 1
    else host = a end
    i = i + 1
  end
  if not host then ctx.err("usage: ping <host> [-c count] [-t ttl] [-s size] [-W timeout]") return false end
  local ip, why = stack:resolve(host, 5)
  if not ip then ctx.err("ping: " .. tostring(why)) return false end
  ctx.say(("PING %s (%s): %d data bytes"):format(host, B.ipStr(ip), size))
  local sent, got, total, lo, hi = 0, 0, 0, math.huge, 0
  for n = 1, count do
    local started = stack.clock()
    local r, err = ICMP.probe(stack, ip, { ttl = ttl, size = size, timeout = timeout })
    sent = sent + 1
    if not r then ctx.err("ping: " .. tostring(err)) break end
    if r.ok then
      got = got + 1
      local ms = r.rtt * 1000
      total, lo, hi = total + ms, math.min(lo, ms), math.max(hi, ms)
      ctx.say(("%d bytes from %s: seq=%d ttl=%d time=%.1f ms"):format(r.bytes, B.ipStr(r.from), n, r.ttl, ms))
    elseif r.reason == "timeout" then
      ctx.say(("Request timeout for seq %d"):format(n))
    else
      ctx.say(("From %s: seq=%d %s"):format(B.ipStr(r.from), n, r.reason == "ttl exceeded" and "Time to live exceeded" or "Destination unreachable"))
    end
    if n < count then
      local left = interval - (stack.clock() - started)
      if left > 0 then ctx.idle(left) end
    end
  end
  ctx.say(("--- %s ping statistics ---"):format(host))
  ctx.say(("%d packets transmitted, %d received, %d%% packet loss"):format(sent, got, sent > 0 and math.floor((sent - got) * 100 / sent) or 0))
  if got > 0 then ctx.say(("round-trip min/avg/max = %.1f/%.1f/%.1f ms"):format(lo, total / got, hi)) end
  return got > 0
end

function M.traceroute(args, ctx)
  ctx = defaultCtx(ctx)
  if not ctx then return false end
  local stack = ctx.stack
  local host, maxHops, timeout, probes = nil, 30, 1.5, 2
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "-m" then i = i + 1 maxHops = tonumber(args[i]) or 30
    elseif a == "-w" then i = i + 1 timeout = tonumber(args[i]) or 1.5
    elseif a == "-q" then i = i + 1 probes = tonumber(args[i]) or 2
    else host = a end
    i = i + 1
  end
  if not host then ctx.err("usage: traceroute <host> [-m maxhops] [-w seconds] [-q probes]") return false end
  local ip, why = stack:resolve(host, 5)
  if not ip then ctx.err("traceroute: " .. tostring(why)) return false end
  ctx.say(("traceroute to %s (%s), %d hops max"):format(host, B.ipStr(ip), maxHops))
  for ttl = 1, maxHops do
    local parts, reached, who = {}, false, nil
    for _ = 1, probes do
      local r = ICMP.probe(stack, ip, { ttl = ttl, timeout = timeout })
      if not r or r.reason == "timeout" then parts[#parts + 1] = "*"
      else
        who = who or r.from
        parts[#parts + 1] = ("%.1f ms"):format(r.rtt * 1000)
        if r.ok then reached = true end
        if r.kind == "unreach" then reached = true end
      end
    end
    ctx.say(("%2d  %s  %s"):format(ttl, who and B.ipStr(who) or "*", table.concat(parts, "  ")))
    if reached then return true end
  end
  return false
end

---------------------------------------------------------------------------------------------------------------------
-- netstat
---------------------------------------------------------------------------------------------------------------------

function M.netstat(args, ctx)
  ctx = defaultCtx(ctx)
  if not ctx then return false end
  local stack = ctx.stack
  local want = {}
  for _, a in ipairs(args) do
    if a:sub(1, 1) == "-" then for ch in a:sub(2):gmatch(".") do want[ch] = true end end
  end
  local function addr(ip, port) return (ip == 0 and "*" or B.ipStr(ip)) .. ":" .. (port == 0 and "*" or port) end
  if want.r then
    showRoutes(stack, ctx)
    return true
  end
  if want.i then
    ctx.say("Iface    MTU  RX-packets  RX-err  TX-packets  TX-err")
    for _, iface in ipairs(stack.ifaceList) do
      local s = iface.stats
      ctx.say(("%-8s %-4d %-11d %-7d %-11d %d"):format(iface.name, iface.mtu, s.rxPackets, s.rxErrors, s.txPackets, s.txErrors))
    end
    return true
  end
  if want.s then
    for _, group in ipairs({ "ip", "icmp", "udp", "tcp" }) do
      ctx.say(group:upper() .. ":")
      local names = {}
      for name in pairs(stack.stats[group]) do names[#names + 1] = name end
      table.sort(names)
      for _, name in ipairs(names) do ctx.say(("  %-18s %d"):format(name, stack.stats[group][name])) end
    end
    return true
  end
  local showT, showU = want.t or not want.u, want.u or not want.t
  ctx.say("Proto  Local Address          Foreign Address        State")
  if showT then
    local rows = {}
    for _, l in pairs(stack.tcpListeners) do rows[#rows + 1] = { ("tcp    %-22s %-22s %s"):format(addr(l.laddr, l.lport), "*:*", "LISTEN"), l.lport } end
    if not want.l then
      for _, t in pairs(stack.tcpTable) do
        rows[#rows + 1] = { ("tcp    %-22s %-22s %s"):format(addr(t.laddr, t.lport), addr(t.raddr, t.rport), t.state), t.lport }
      end
    end
    table.sort(rows, function(a, b) if a[2] ~= b[2] then return a[2] < b[2] end return a[1] < b[1] end)
    for _, r in ipairs(rows) do ctx.say(r[1]) end
  end
  if showU then
    for _, s in ipairs(stack.udpSockets) do
      ctx.say(("udp    %-22s %-22s %s"):format(addr(s.laddr, s.lport or 0), s.raddr and addr(s.raddr, s.rport) or "*:*", ""))
    end
  end
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- tcpdump
---------------------------------------------------------------------------------------------------------------------

function M.tcpdump(args, ctx)
  ctx = defaultCtx(ctx)
  if not ctx then return false end
  local stack = ctx.stack
  local iface, count, writePath, readPath, showMac, hex = nil, nil, nil, nil, false, false
  local words = {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "-i" then i = i + 1 iface = args[i]
    elseif a == "-c" then i = i + 1 count = tonumber(args[i])
    elseif a == "-w" then i = i + 1 writePath = args[i]
    elseif a == "-r" then i = i + 1 readPath = args[i]
    elseif a == "-e" then showMac = true
    elseif a == "-x" then hex = true
    elseif a == "-t" then i = i + 1
    else words[#words + 1] = a end
    i = i + 1
  end
  local pred, err = dissect.filter(words)
  if not pred then ctx.err("tcpdump: " .. tostring(err)) return false end
  local vfs = require("tsr.vfs")
  local function show(ts, ifname, frame)
    local info = dissect.parse(frame)
    if not pred(info) then return false end
    local line = ("%9.3f %s%s"):format(ts, showMac and info.eth and (B.macStr(info.eth.src) .. " > " .. B.macStr(info.eth.dst) .. " ") or "", dissect.describe(info))
    if ifname and iface == "any" then line = ifname .. " " .. line end
    ctx.say(line)
    if hex then ctx.say("    " .. B.hex(frame, 96)) end
    return true
  end
  if readPath then
    local text = vfs.readFile(vfs.normalize(readPath))
    if not text then ctx.err("tcpdump: cannot read " .. readPath) return false end
    local n = 0
    for line in text:gmatch("[^\n]+") do
      local ts, ifname, h = line:match("^(%S+)\t(%S+)\t(%x+)$")
      if ts then
        local frame = (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end))
        if show(tonumber(ts), ifname, frame) then n = n + 1 end
        if count and n >= count then break end
      end
    end
    return true
  end
  if iface and iface ~= "any" and not stack.ifaces[iface] then ctx.err("tcpdump: no such interface: " .. iface) return false end
  local shown, saved = 0, {}
  local start = stack.clock()
  local remove = stack:addTap(function(dir, ifc, frame)
    if iface and iface ~= "any" and ifc.name ~= iface then return end
    if show(stack.clock() - start, ifc.name, frame) then
      shown = shown + 1
      if writePath then saved[#saved + 1] = ("%.3f\t%s\t%s"):format(stack.clock() - start, ifc.name, B.hex(frame)) end
    end
  end)
  ctx.say("tcpdump: listening on " .. (iface or "all interfaces") .. ", press Ctrl+T to stop")
  local deadline = ctx.seconds and (stack.clock() + ctx.seconds)
  while not (count and shown >= count) and not (deadline and stack.clock() >= deadline) do
    if ctx.idle(0.2) == "stop" then break end
  end
  remove()
  if writePath then vfs.writeFile(vfs.normalize(writePath), table.concat(saved, "\n") .. "\n") ctx.say(#saved .. " packets written to " .. writePath) end
  ctx.say(shown .. " packets captured")
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- nc
---------------------------------------------------------------------------------------------------------------------

function M.nc(args, ctx)
  ctx = defaultCtx(ctx)
  if not ctx then return false end
  local socket = require("tsr.inet.socket")
  local listen, useUdp, scan, timeout, rest = false, false, false, 5, {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "-l" then listen = true elseif a == "-u" then useUdp = true elseif a == "-z" then scan = true
    elseif a == "-w" then i = i + 1 timeout = tonumber(args[i]) or 5
    else rest[#rest + 1] = a end
    i = i + 1
  end
  local stack = ctx.stack
  if scan then
    local host, port = rest[1], tonumber(rest[2])
    if not (host and port) then ctx.err("usage: nc -z <host> <port>") return false end
    local s = socket.tcp(stack)
    local ok, err = s:connect(host, port, timeout)
    if ok then s:close() ctx.say(("connection to %s %d port [tcp] succeeded"):format(host, port)) return true end
    ctx.err(("connection to %s %d port failed: %s"):format(host, port, tostring(err)))
    return false
  end
  local lines = ctx.inputLines
  local function nextLine()
    if lines then return table.remove(lines, 1) end
    return read()
  end
  if listen then
    local port = tonumber(rest[1])
    if not port then ctx.err("usage: nc -l <port>") return false end
    if useUdp then
      local u = socket.udp(stack)
      u:bind(nil, port)
      while true do
        local data, ip, p = u:receivefrom(timeout)
        if not data then return true end
        ctx.say(data)
      end
    end
    local srv = socket.tcp(stack)
    srv:bind(nil, port)
    assert(srv:listen(1))
    local c = srv:accept(timeout)
    if not c then srv:close() ctx.err("nc: nobody connected") return false end
    while true do
      local line, err = c:receive("*l", 1)
      if line then ctx.say(line) elseif err == "closed" then break end
      local out = lines and #lines > 0 and nextLine()
      if out then c:send(out .. "\n") end
      if err == "timeout" and ctx.stopWhenIdle then break end
    end
    c:close() srv:close()
    return true
  end
  local host, port = rest[1], tonumber(rest[2])
  if not (host and port) then ctx.err("usage: nc [-u] <host> <port>") return false end
  if useUdp then
    local u = socket.udp(stack)
    assert(u:connect(host, port))
    while true do
      local line = nextLine()
      if not line then break end
      u:send(line)
      local data = u:receivefrom(timeout)
      if data then ctx.say(data) end
    end
    return true
  end
  local c = socket.tcp(stack)
  local ok, err = c:connect(host, port, timeout)
  if not ok then ctx.err("nc: " .. tostring(err)) return false end
  while true do
    local line = nextLine()
    if not line then break end
    c:send(line .. "\n")
    local reply = c:receive("*l", timeout)
    if reply then ctx.say(reply) end
  end
  c:close()
  return true
end

return M
