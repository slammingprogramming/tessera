-- SPDX-License-Identifier: AGPL-3.0-or-later
local B = require("tsr.inet.bytes")
local W = require("tsr.dhcp.wire")
local client = require("tsr.dhcp.client")
local serverMod = require("tsr.dhcp.server")
local dhcpcli = require("tsr.dhcp.cli")
local ICMP = require("tsr.inet.icmp")
local Sim = dofile("/tests/lib/inetsim.lua")

local function net(poolOverrides)
  local sim = Sim.new()
  local seg = sim:segment("lan")
  local router = sim:host("router", { forwarding = true })
  sim:plug(router, "eth0", seg, "10.2.0.1/24")
  local pool = { name = "lan", iface = "eth0", network = "10.2.0.0/24", range = { "10.2.0.100", "10.2.0.110" }, router = "10.2.0.1", dns = { "10.2.0.1", "10.2.0.2" },
    domain = "lan", lease = 40, ntp = { "10.2.0.1" }, mtu = 1400 }
  for k, v in pairs(poolOverrides or {}) do pool[k] = v end
  local server = serverMod.new(router, { pools = { pool }, persist = false, clock = function() return sim.now end })
  sim:spawn(function() server:serve() end)
  sim:run(0.1)
  return sim, seg, router, server
end

local function newClient(sim, seg, name)
  local h = sim:host(name)
  sim:plug(h, "eth0", seg)
  return h
end

test("messages: encode and decode all option types", function()
  local m = { op = 2, xid = 0xdeadbeef, broadcast = true, yiaddr = B.ip("10.0.0.5"), siaddr = B.ip("10.0.0.1"), chaddr = B.makeMac(1, 2, 3),
    options = { type = W.OFFER, subnetMask = B.mask(24), routers = { B.ip("10.0.0.1") }, dns = { B.ip("10.0.0.1"), B.ip("8.8.8.8") }, domain = "lan",
      leaseTime = 3600, serverId = B.ip("10.0.0.1"), mtu = 1400, hostname = "pc1", ntp = { B.ip("10.0.0.1") } } }
  local bytes = W.encode(m)
  ok(#bytes >= 300)
  eq(bytes:sub(237, 240), W.COOKIE)
  local d = assert(W.decode(bytes))
  eq(d.xid, 0xdeadbeef) ok(d.broadcast) eq(d.yiaddr, m.yiaddr) eq(d.chaddr, m.chaddr)
  eq(d.options.type, W.OFFER) eq(d.options.dns, { B.ip("10.0.0.1"), B.ip("8.8.8.8") }) eq(d.options.domain, "lan")
  eq(d.options.leaseTime, 3600) eq(d.options.mtu, 1400) eq(d.options.hostname, "pc1") eq(d.options.subnetMask, B.mask(24))
  eq(select(2, W.decode(bytes:sub(1, 100))), "short DHCP message")
  eq(select(2, W.decode(bytes:sub(1, 236) .. "XXXX" .. bytes:sub(241))), "no DHCP cookie")
end)

test("a client gets address, router, DNS, MTU and domain; two clients get different addresses", function()
  local sim, seg, router, server = net()
  local a, b = newClient(sim, seg, "a"), newClient(sim, seg, "b")
  local bound = {}
  sim:spawn(function() client.run(a, "eth0", { hostname = "a", onBound = function(l) bound.a = l end }) end)
  sim:spawn(function() client.run(b, "eth0", { hostname = "b", onBound = function(l) bound.b = l end }) end)
  sim:run(4)
  ok(bound.a and bound.b, "both clients are configured")
  ok(a:isLocal(bound.a.address) and b:isLocal(bound.b.address))
  ok(bound.a.address ~= bound.b.address)
  ok(bound.a.address >= B.ip("10.2.0.100") and bound.a.address <= B.ip("10.2.0.110"))
  eq(a:lookup(B.ip("8.8.8.8")).gateway, B.ip("10.2.0.1"), "default route via the router")
  eq(a.dnsServers, { B.ip("10.2.0.1"), B.ip("10.2.0.2") })
  eq(a.searchDomains, { "lan" })
  eq(a:iface("eth0").mtu, 1400)
  eq(a.ntpServers, { B.ip("10.2.0.1") })
  -- the clients can talk to each other and to the router
  ok(ICMP.probe(a, B.ipStr(bound.b.address), { timeout = 3 }).ok)
  ok(ICMP.probe(b, "10.2.0.1", { timeout = 3 }).ok)
  eq(#server:active(), 2)
  eq(server.stats.discover, 2) eq(server.stats.ack, 2)
  -- the cli
  local lines = {}
  ok(dhcpcli.run({ "status" }, { stack = a, say = function(t) lines[#lines + 1] = t end, err = function(t) lines[#lines + 1] = t end }))
  ok(table.concat(lines, "\n"):find("eth0: 10.2.0.", 1, true) and table.concat(lines, "\n"):find("dns 10.2.0.1, 10.2.0.2 (domain lan)", 1, true), table.concat(lines, "\n"))
end)

test("a lease is renewed at T1 and the address stays; the server forgets it after release", function()
  local sim, seg, router, server = net()
  local a = newClient(sim, seg, "a")
  local first
  sim:spawn(function() client.run(a, "eth0", { onBound = function(l) first = first or l end }) end)
  sim:run(3)
  ok(first)
  local ip = first.address
  local obtained = a:iface("eth0").lease.obtained
  sim:run(30)                                    -- past T1 (20 s) of the 40 s lease
  local lease = a:iface("eth0").lease
  ok(lease.obtained > obtained, "the lease was renewed")
  eq(lease.address, ip)
  ok(a:isLocal(ip))
  eq(#server:active(), 1)
  ok(client.release(a, "eth0"))
  sim:run(1)
  eq(#server:active(), 0)
  ok(not a:isLocal(ip))
end)

test("when the server is gone the lease runs out, the address is removed, and a new server is found", function()
  local sim, seg, router, server = net()
  local a = newClient(sim, seg, "a")
  local lost, bound = 0, 0
  sim:spawn(function() client.run(a, "eth0", { onBound = function() bound = bound + 1 end, onLost = function() lost = lost + 1 end, retryAfter = 2 }) end)
  sim:run(3)
  eq(bound, 1)
  router:iface("eth0").port.down = true               -- the cable of the server is pulled
  sim:run(60)
  eq(lost, 1, "the lease expired")
  eq(a:iface("eth0").addrs, {}, "the address was taken away")
  eq(a:lookup(B.ip("8.8.8.8")), nil)
  router:iface("eth0").port.down = false
  sim:run(70)
  ok(bound >= 2, "the client got an address again")
  ok(#a:iface("eth0").addrs == 1)
end)

test("reservations, requested addresses, exhausted pools, wrong networks", function()
  local sim, seg, router, server = net({ range = { "10.2.0.100", "10.2.0.101" } })
  local a, b, c, d = newClient(sim, seg, "a"), newClient(sim, seg, "b"), newClient(sim, seg, "c"), newClient(sim, seg, "d")
  local leases = {}
  for _, h in ipairs({ a, b, c, d }) do
    sim:spawn(function() leases[h.name] = client.acquire(h, "eth0", { tries = 2 }) end)
  end
  sim:run(30)
  local got = 0
  for _, h in ipairs({ a, b, c, d }) do if leases[h.name] then got = got + 1 end end
  eq(got, 2, "only two addresses are in the pool, the other two computers get nothing")
  -- a reservation wins over the pool
  server.pools[1].reservations[B.makeMac(1, 1, 1)] = B.ip("10.2.0.50")
  local rm = { op = 1, xid = 1, chaddr = B.makeMac(1, 1, 1), broadcast = true, options = { type = W.DISCOVER } }
  eq(server:handle(rm, "eth0").yiaddr, B.ip("10.2.0.50"))
  -- a request for an address in another network is refused with a NAK
  local m = { op = 1, xid = 99, chaddr = B.makeMac(9, 9, 9), broadcast = true, options = { type = W.REQUEST, requestedIp = B.ip("192.168.1.5") } }
  local reply = server:handle(m, "eth0")
  eq(reply.options.type, W.NAK) ok(reply.options.message:find("wrong network", 1, true))
  -- another server was chosen by the client: ignored
  m.options.serverId = B.ip("10.2.0.77")
  eq(server:handle(m, "eth0"), nil)
  -- decline marks the address bad
  local dm = { op = 1, xid = 5, chaddr = B.makeMac(8, 8, 8), options = { type = W.DECLINE, requestedIp = B.ip("10.2.0.100") } }
  server:handle(dm, "eth0")
  ok(server.bad[B.ip("10.2.0.100")])
  -- inform answers with options but no lease
  local im = { op = 1, xid = 6, chaddr = B.makeMac(7, 7, 7), ciaddr = B.ip("10.2.0.200"), options = { type = W.INFORM } }
  local ir = server:handle(im, "eth0")
  eq(ir.options.type, W.ACK) eq(ir.options.leaseTime, nil) eq(ir.options.routers, { B.ip("10.2.0.1") })
end)

test("address conflicts are detected before the address is used", function()
  local sim, seg, router, server = net({ range = { "10.2.0.100", "10.2.0.100" } })
  local squatter = newClient(sim, seg, "squatter")
  squatter:setAddress("eth0", "10.2.0.100", 24)      -- somebody configured the pool address by hand
  local a = newClient(sim, seg, "a")
  local lease
  sim:spawn(function() lease = client.acquire(a, "eth0", { tries = 2 }) end)
  sim:run(40)
  eq(lease, nil, "the only address in the pool is in use, the client must not take it")
  ok(server.bad[B.ip("10.2.0.100")], "it was declined")
  eq(a:iface("eth0").addrs, {})
end)

test("the server remembers leases across a restart", function()
  local sim = Sim.new()
  local seg = sim:segment("lan")
  local router = sim:host("router", { forwarding = true })
  sim:plug(router, "eth0", seg, "10.2.0.1/24")
  local path = "/tmp/dhcp-test.leases"
  local cfg = { pools = { { name = "lan", iface = "eth0", network = "10.2.0.0/24", range = { "10.2.0.100", "10.2.0.110" }, lease = 100000 } }, leasePath = path, clock = function() return sim.now end }
  local s1 = serverMod.new(router, cfg)
  sim:spawn(function() s1:serve() end)
  local a = newClient(sim, seg, "a")
  local lease
  sim:spawn(function() lease = client.acquire(a, "eth0", {}) end)
  sim:run(3)
  ok(lease)
  s1.stop = true
  sim:run(2)
  local s2 = serverMod.new(router, cfg)
  s2:load()
  eq(#s2:active(), 1)
  eq(s2:active()[1].ip, lease.address)
  require("tsr.vfs").fs.delete(path)
end)

test("a relay agent lets clients behind a router use a DHCP server on another network", function()
  local relayMod = require("tsr.dhcp.relay")
  local sim = Sim.new()
  local clients, servers = sim:segment("clients"), sim:segment("servers")
  local router = sim:host("router", { forwarding = true })
  local dhcpHost = sim:host("dhcp")
  sim:plug(router, "eth0", clients, "10.5.0.1/24")
  sim:plug(router, "eth1", servers, "10.0.0.2/24")
  sim:plug(dhcpHost, "eth0", servers, "10.0.0.1/24")
  dhcpHost:addRoute("10.5.0.0/24", "10.0.0.2")
  local server = serverMod.new(dhcpHost, { pools = {
    { name = "far", iface = "eth0", network = "10.5.0.0/24", range = { "10.5.0.100", "10.5.0.110" }, router = "10.5.0.1", dns = { "10.0.0.1" }, lease = 600 },
  }, persist = false, clock = function() return sim.now end })
  sim:spawn(function() server:serve() end)
  local relay = relayMod.new(router, { interfaces = { "eth0" }, servers = { "10.0.0.1" } })
  local t = sim:spawn(function() relay:run() end)
  t.daemon = true
  sim:run(0.2)
  local a = newClient(sim, clients, "a")
  local lease
  sim:spawn(function() lease = client.acquire(a, "eth0", {}) end)
  sim:run(5)
  ok(lease, "the client got an address through the relay")
  ok(lease.address >= B.ip("10.5.0.100") and lease.address <= B.ip("10.5.0.110"))
  eq(lease.routers, { B.ip("10.5.0.1") })
  eq(relay.stats.requests >= 2 and relay.stats.replies >= 2, true)
  client.apply(a, "eth0", lease)
  ok(ICMP.probe(a, "10.0.0.1", { timeout = 3 }).ok, "and can reach the server network through the router")
end)
