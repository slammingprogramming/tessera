-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The files that the "Home router" use case writes are put to work on a simulated network: provider (DHCP, DNS, a web server) -- router -- home computer.
-- If a rule blocks DHCP, if the name server cannot find the provider's resolver or if NAT does not work, this test fails.
local E = dofile("/tests/lib/testenv.lua")
local usecases = require("tsr.setup.usecases")
local B = require("tsr.inet.bytes")
local dhcpClient = require("tsr.dhcp.client")
local dhcpServer = require("tsr.dhcp.server")
local dnsServer = require("tsr.inet.dns.server")
local dnsClient = require("tsr.inet.dns.client")
local fwMod = require("tsr.inet.fw")
local iptables = require("tsr.inet.fw.iptables")
local ICMP = require("tsr.inet.icmp")
local socket = require("tsr.inet.socket")
local Sim = dofile("/tests/lib/inetsim.lua")

local function fakeVfs()
  local files = {}
  local v = { files = files, json = {} }
  v.fs = { exists = function(p) return files[p] ~= nil end }
  function v.mkdirp() end
  function v.writeFile(p, text) files[p] = text return true end
  function v.writeJSON(p, t) v.json[p] = t return true end
  return v
end

local PROVIDER_ZONE = [[
$ORIGIN example.lan.
$TTL 300
@        IN SOA ns hostmaster 1 3600 600 86400 300
@        IN NS  ns
ns       IN A   10.255.0.1
www      IN A   10.255.0.1
]]

test("a home router built by the installer gives a home computer an address, names and a path to the provider, and keeps the provider out", function()
  -- the files the installer writes for a router with two wired modems
  local probe = E.fakeProbe({ peripherals = { { type = "modem", name = "back" }, { type = "modem", name = "left" } } })
  local fv = fakeVfs()
  local result = usecases.apply("router-home", probe, { vfs = fv, config = { set = function() end, save = function() end }, svc = { enable = function() return true end }, hostname = "gw" })
  eq(result.problems, {})
  local function load_(path) return assert(load(fv.files[path], "=" .. path, "t", {}))() end

  local sim = Sim.new()
  local wan, lan = sim:segment("wan"), sim:segment("lan")
  local trace = {}
  local dissect = require("tsr.inet.dissect")
  wan.drop = function(frame) trace[#trace + 1] = "wan " .. dissect.describe(dissect.parse(frame)) return false end
  lan.drop = function(frame) trace[#trace + 1] = "lan " .. dissect.describe(dissect.parse(frame)) return false end
  local isp = sim:host("isp", { forwarding = true })
  local gw = sim:host("gw", { forwarding = true })
  local pc = sim:host("pc")
  sim:plug(isp, "eth0", wan, "10.255.0.1/24")
  sim:plug(gw, "eth0", wan)                       -- no address: the router asks the provider (DHCP)
  sim:plug(gw, "eth1", lan, "192.168.1.1/24")     -- the home network, as network.lua says
  sim:plug(pc, "eth0", lan)
  local net = load_("/etc/tsr/inet/network.lua")
  eq(net.interfaces.eth0.dhcp, true)
  eq(net.interfaces.eth1.addresses, { "192.168.1.1/24" })

  -- the provider: DHCP, a name server with a zone, a web server and an ssh port
  local ispDhcp = dhcpServer.new(isp, { pools = { { name = "wan", iface = "eth0", network = "10.255.0.0/24", range = { "10.255.0.50", "10.255.0.60" }, router = "10.255.0.1", dns = { "10.255.0.1" }, lease = 600 } }, persist = false, clock = function() return sim.now end })
  sim:spawn(function() ispDhcp:serve() end)
  local ispDns = dnsServer.new(isp, { zones = { { origin = "example.lan", text = PROVIDER_ZONE } } })
  eq(ispDns:loadZones(), {})
  for _, job in ipairs(assert(ispDns:workers(1))) do local t = sim:spawn(job) t.daemon = true end
  local seen = {}
  local function listener(host, port, tag)
    local t = sim:spawn(function()
      local l = socket.tcp(host) l:bind(nil, port) l:listen(4)
      while true do
        local c = l:accept(600)
        if not c then return end
        seen[#seen + 1] = tag .. " from " .. tostring(c:getpeername())
        c:send(tag .. "\n") c:close()
      end
    end)
    t.daemon = true
  end
  listener(isp, 80, "isp-web")
  listener(gw, 22, "router-ssh")
  sim:run(0.2)

  -- the router: firewall first (as at boot), then DHCP client, DHCP server for the home, name server
  local fw = fwMod.install(gw)
  eq(iptables.load(fw, fv.files["/etc/tsr/inet/iptables.rules"]), {})
  local gwLease
  sim:spawn(function() dhcpClient.run(gw, "eth0", { hostname = "gw", onBound = function(l) gwLease = l end }) end)
  sim:run(3)
  ok(gwLease, "the router got an address from the provider although INPUT is closed")
  eq(B.ipStr(gwLease.address):match("^10%.255%.0%.%d+$") ~= nil, true)
  local homeDhcp = dhcpServer.new(gw, { pools = load_("/etc/tsr/inet/dhcpd.lua").pools, persist = false, clock = function() return sim.now end })
  sim:spawn(function() homeDhcp:serve() end)
  local named = dnsServer.new(gw, load_("/etc/tsr/inet/named.lua"))
  for _, job in ipairs(assert(named:workers(2))) do local t = sim:spawn(job) t.daemon = true end
  dnsClient.install(gw)
  sim:run(0.5)

  -- the home computer
  local lease
  sim:spawn(function() dhcpClient.run(pc, "eth0", { hostname = "pc", onBound = function(l) lease = l end }) end)
  sim:run(3)
  ok(lease, "the home computer got an address")
  ok(lease.address >= B.ip("192.168.1.100") and lease.address <= B.ip("192.168.1.199"), B.ipStr(lease.address))
  eq(pc.dnsServers, { B.ip("192.168.1.1") })
  eq(pc:lookup(B.ip("10.255.0.1")).gateway, B.ip("192.168.1.1"), "default route via the router")
  dnsClient.install(pc)

  -- names: the router asks the provider's name server for the home computer
  local addr
  sim:spawn(function() addr = pc:resolve("www.example.lan") end)
  sim:run(3)
  eq(addr, B.ip("10.255.0.1"), "www.example.lan, answered by the provider's name server through the router")

  -- a connection to the provider's web server works and the provider sees the router's address, not the home address
  local reply, cerr
  sim:spawn(function()
    local c = socket.tcp(pc)
    local okC, why = c:connect("www.example.lan", 80, 5)
    cerr = "connect returned " .. tostring(okC) .. " " .. tostring(why)
    if okC then local l, e = c:receive("*l", 3) reply = l cerr = cerr .. "; receive: " .. tostring(l) .. " " .. tostring(e) .. "; state " .. tostring(c:state()) c:close() end
  end)
  sim:run(12)
  if reply ~= "isp-web" then
    local last = {}
    for i = math.max(1, #trace - 14), #trace do last[#last + 1] = trace[i] end
    error(tostring(cerr) .. "\n" .. table.concat(last, "\n"))
  end
  ok(seen[1] and seen[1]:find("isp-web from " .. B.ipStr(gwLease.address), 1, true), tostring(seen[1]))
  ok(not seen[1]:find("192.168.1.", 1, true), "the provider never sees the private address")

  -- ping works both ways to the router's outside address (limited), and through the router
  local r1 = ICMP.probe(pc, "10.255.0.1", { timeout = 2 })
  ok(r1.ok, "a home computer can ping the provider: " .. tostring(r1.reason))
  local r2 = ICMP.probe(isp, B.ipStr(gwLease.address), { timeout = 2 })
  ok(r2.ok, "the provider can ping the router's outside address")

  -- the provider cannot get in: not to the router's ssh port, not to the home network
  local blocked
  sim:spawn(function()
    local c = socket.tcp(isp)
    blocked = not c:connect(B.ipStr(gwLease.address), 22, 3)
  end)
  sim:run(5)
  ok(blocked, "the router's ssh port is closed to the outside")
  eq(#seen, 1, "nothing else reached a server")
  local inside
  sim:spawn(function()
    local c = socket.tcp(isp)
    inside = not c:connect(B.ipStr(lease.address), 80, 3)
  end)
  sim:run(5)
  ok(inside, "a home address cannot be reached from the provider")
  -- the home router only offers DHCP, DNS and ping to the home network: any other port of the router itself is closed to the home computers too
  local viaLan
  sim:spawn(function()
    local c = socket.tcp(pc)
    if c:connect("192.168.1.1", 22, 3) then viaLan = c:receive("*l", 2) c:close() end
  end)
  sim:run(4)
  eq(viaLan, nil, "no other service of the router is open, not even to the inside")
end)
