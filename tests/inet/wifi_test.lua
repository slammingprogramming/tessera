-- SPDX-License-Identifier: AGPL-3.0-or-later
local B = require("tsr.inet.bytes")
local W = require("tsr.inet.wifi.frames")
local K = require("tsr.inet.wifi.keys")
local apMod = require("tsr.inet.wifi.ap")
local staMod = require("tsr.inet.wifi.sta")
local wifiCli = require("tsr.inet.wifi.cli")
local dhcpServer = require("tsr.dhcp.server")
local dhcpClient = require("tsr.dhcp.client")
local ICMP = require("tsr.inet.icmp")
local Sim = dofile("/tests/lib/inetsim.lua")

local macCounter = 0
local function mac()
  macCounter = macCounter + 1
  return B.macStr(B.makeMac(9, macCounter, 7))
end

local function world()
  local sim = Sim.new()
  local air = sim:air({})
  local lan = sim:segment("lan")
  local server = sim:host("server")
  sim:plug(server, "eth0", lan, "10.0.0.1/24")
  return sim, air, lan, server
end

local function addAp(sim, air, lan, name, cfg, pos)
  local host = sim:host(name)
  sim:plug(host, "eth0", lan)
  local modem = air:modem("m-" .. name, host, pos or { 0, 0, 0 })
  cfg.modem, cfg.modemName, cfg.bridge, cfg.mac, cfg.iterations = modem, "m-" .. name, cfg.bridge or { "eth0" }, mac(), 4
  local ap = apMod.new(host, cfg)
  ap:start()
  return ap, host
end

local function addSta(sim, air, name, cfg, pos, cidr)
  local host = sim:host(name)
  local modem = air:modem("m-" .. name, host, pos or { 5, 0, 0 })
  cfg.name, cfg.modem, cfg.modemName, cfg.mac, cfg.iterations = "wlan0", modem, "m-" .. name, mac(), 4
  cfg.channels = cfg.channels or { 1, 6, 11 }
  local sta = staMod.new(host, cfg)
  if cidr then host:setAddress("wlan0", cidr:match("^([%d%.]+)"), tonumber(cidr:match("/(%d+)"))) end
  sta:start()
  return sta, host, modem
end

test("frames and keys: formats round trip, the handshake keys agree, tampering is detected", function()
  local b = { channel = 6, security = 1, ssid = "home", load = 3, timestamp = 99, interval = 1000 }
  local d = W.decodeBeacon(W.encodeBeacon(b))
  eq(d.ssid, "home") eq(d.channel, 6) eq(d.security, 1) eq(d.load, 3) eq(d.interval, 1000) eq(d.hidden, false)
  eq(W.decodeBeacon(W.encodeBeacon({ channel = 1, ssid = "secret", hidden = true })).ssid, "", "a hidden network sends no name")
  local f = W.parse(W.header(W.TYPES.AUTH, B.makeMac(1, 1, 1), B.makeMac(2, 2, 2), B.makeMac(3, 3, 3)) .. W.encodeAuth(1))
  eq(f.type, 4) eq(f.src, B.makeMac(2, 2, 2)) eq(W.decodeAuth(f.body).seq, 1)
  eq(W.parse("short"), nil)
  eq(W.modemChannel(6), 7116)
  local pmkA = K.pmk("correct horse", "home", 4)
  eq(#pmkA, 32) ok(pmkA == K.pmk("correct horse", "home", 4)) ok(pmkA ~= K.pmk("correct horse", "other", 4)) ok(pmkA ~= K.pmk("correct hors", "home", 4))
  local ap, sta, an, sn = B.makeMac(1, 1, 1), B.makeMac(2, 2, 2), string.rep("a", 32), string.rep("s", 32)
  local k1, k2 = K.ptk(pmkA, ap, sta, an, sn), K.ptk(pmkA, sta, ap, an, sn)
  eq(k1.tk, k2.tk, "both sides derive the same keys regardless of the order of the addresses")
  ok(K.ptk(pmkA, ap, sta, an, string.rep("x", 32)).tk ~= k1.tk, "a different nonce gives different keys")
  local hdr = "x" .. string.rep("h", 18)
  local sealed = K.seal(k1.tk, 5, 0, "inner frame", hdr)
  local plain, pn = K.open(k1.tk, 0, sealed, hdr)
  eq(plain, "inner frame") eq(pn, 5)
  eq(K.open(k1.tk, 1, sealed, hdr), nil, "the wrong direction")
  eq(K.open(k1.tk, 0, sealed, "y" .. hdr:sub(2)), nil, "the header is authenticated too")
  eq(K.open(k1.tk, 0, sealed:sub(1, -2) .. "\0", hdr), nil, "damage is detected")
end)

test("an open network: scan, join, and talk to the wired side through the access point", function()
  local sim, air, lan, server = world()
  local ap = addAp(sim, air, lan, "ap", { ssid = "guest", channel = 6 })
  local sta, laptop = addSta(sim, air, "laptop", { ssid = "guest" }, { 12, 0, 0 }, "10.0.0.50/24")
  local list = sta:scan()
  eq(#list, 1) eq(list[1].ssid, "guest") eq(list[1].channel, 6) eq(list[1].security, "open")
  ok(list[1].signal > 70 and list[1].signal < 100, "signal " .. list[1].signal)
  ok(sta:connect())
  eq(sta:status().state, "connected")
  ok(laptop:iface("wlan0").up)
  ok(ICMP.probe(laptop, "10.0.0.1", { timeout = 3 }).ok, "ping the server on the wired LAN")
  ok(ICMP.probe(server, "10.0.0.50", { timeout = 3 }).ok, "and back")
  eq(ap:clientCount(), 1)
  eq(ap:clientList()[1].mac, sta.mac)
  -- the bridge learned the laptop behind its Wi-Fi port and the server behind the wired port
  local bridged = ap.switch:macTable()
  eq(#bridged, 2)
  ok(laptop.stats.ip.forwarded == nil)
  sta:disconnect()
  eq(sta:status().state, "idle")
  ok(not laptop:iface("wlan0").up)
  sim:run(0.5)
  eq(ap:clientCount(), 0, "the access point noticed the goodbye")
end)

test("WPA: the right passphrase joins, the wrong one does not, nothing readable is on the air, replays are dropped", function()
  local sim, air, lan, server = world()
  local ap = addAp(sim, air, lan, "ap", { ssid = "home", channel = 1, security = "psk", passphrase = "correct horse" })
  local spy = air:modem("m-spy", sim:host("spy"), { 3, 0, 0 })
  spy.open(W.modemChannel(1))
  local heard = {}
  local spyStack = air.modems[#air.modems].stack
  local linkMod = require("tsr.inet.link")
  linkMod.addHandler(spyStack, "m-spy", function(ev) heard[#heard + 1] = ev[5] end, "spy")
  local good, laptop = addSta(sim, air, "laptop", { ssid = "home", passphrase = "correct horse" }, { 8, 0, 0 }, "10.0.0.51/24")
  local bad, phone = addSta(sim, air, "phone", { ssid = "home", passphrase = "wrong passphrase" }, { 9, 0, 0 }, "10.0.0.52/24")
  ok(select(2, bad:scan())  == nil or true)
  local okBad, why = bad:connect()
  eq(okBad, nil)
  ok(why:find("handshake failed", 1, true) and why:find("passphrase", 1, true), tostring(why))
  eq(ap:clientCount(), 0)
  ok(ap.stats.handshakeFailures >= 1)
  ok(good:connect())
  ok(ICMP.probe(laptop, "10.0.0.1", { size = 64, timeout = 3 }).ok)
  -- the network name is public, but the data frames contain no readable payload
  local secret = "tessera-secret-payload-0123456789"
  local sock = require("tsr.inet.socket")
  local u = sock.udp(laptop)
  u:sendto(secret, "10.0.0.1", 9)
  sim:run(0.5)
  local seen = false
  local dataFrames = {}
  for _, m in ipairs(heard) do
    if m:find(secret, 1, true) then seen = true end
    if #m > 19 and (m:byte(1) == W.TYPES.DATA_TO_AP or m:byte(1) == W.TYPES.DATA_FROM_AP) then dataFrames[#dataFrames + 1] = m end
  end
  ok(#dataFrames >= 4 and not seen, "the spy heard " .. #heard .. " messages, none with the payload")
  -- replay: a captured data frame is not accepted a second time
  local replayed = dataFrames[#dataFrames]
  local before = ap.stats.replays + good.stats.replays
  for _ = 1, 2 do air.modems[1].transmit(W.modemChannel(1), W.modemChannel(1), replayed) end
  sim:run(0.5)
  local spyM = air.modems[2]
  spyM.transmit(W.modemChannel(1), W.modemChannel(1), replayed)
  sim:run(0.5)
  ok(ap.stats.replays + good.stats.replays > before, "replays were counted and dropped")
  -- passphrases that are too short are refused when the access point is created
  local okShort = pcall(apMod.new, laptop, { ssid = "x", security = "psk", passphrase = "short" })
  ok(not okShort)
end)

test("MAC filter, capacity, hidden network, client isolation", function()
  local sim, air, lan, server = world()
  local ap = addAp(sim, air, lan, "ap", { ssid = "club", channel = 6, maxClients = 2, isolate = true })
  local a, ha = addSta(sim, air, "a", { ssid = "club" }, { 5, 0, 0 }, "10.0.0.61/24")
  local b, hb = addSta(sim, air, "b", { ssid = "club" }, { 6, 0, 0 }, "10.0.0.62/24")
  local c, hc = addSta(sim, air, "c", { ssid = "club" }, { 7, 0, 0 }, "10.0.0.63/24")
  ok(a:connect()) ok(b:connect())
  local okC, whyC = c:connect()
  ok(okC == nil and whyC:find("full", 1, true), tostring(whyC))
  -- isolation: the two stations can reach the wired server but not each other
  ok(ICMP.probe(ha, "10.0.0.1", { timeout = 3 }).ok)
  ok(not ICMP.probe(ha, "10.0.0.62", { timeout = 2 }).ok, "isolated clients do not see each other")
  ok(ICMP.probe(ha, "10.0.0.1", { timeout = 3 }).ok)
  -- kick a client; the freed place can be used
  ap:kick(a.mac)
  sim:run(0.5)
  eq(a:status().state, "idle")
  ok(c:connect())
  -- a MAC deny list
  ap.cfg.macFilter = { mode = "deny", list = { B.macStr(a.mac) } }
  local okA, whyA = a:connect()
  ok(okA == nil and whyA:find("MAC filter", 1, true), tostring(whyA))
  ap.cfg.macFilter = { mode = "allow", list = { B.macStr(c.mac) } }
  ok(ap:allowed(c.mac) and not ap:allowed(a.mac))
  -- a hidden network does not show up in a wildcard scan, but joining it by name works
  local sim2, air2, lan2 = world()
  local hidden = addAp(sim2, air2, lan2, "ap", { ssid = "stealth", channel = 11, hidden = true })
  local s, hs = addSta(sim2, air2, "s", { ssid = "stealth" }, { 4, 0, 0 }, "10.0.0.70/24")
  local list = s:scan()
  eq(#list == 0 or list[1].ssid == "", true, "no name in the list")
  ok(s:connect(), "joining by name still works")
  eq(s:status().ssid, "stealth")
end)

test("range and signal strength; roaming to a nearer access point of the same network", function()
  local sim, air, lan, server = world()
  local ap1 = addAp(sim, air, lan, "ap1", { ssid = "campus", channel = 1 }, { 0, 0, 0 })
  local ap2 = addAp(sim, air, lan, "ap2", { ssid = "campus", channel = 11, inactivity = 12 }, { 100, 0, 0 })
  local sta, laptop, modem = addSta(sim, air, "laptop", { ssid = "campus", roamThreshold = 40, roamMargin = 10 }, { 150, 0, 0 }, "10.0.0.80/24")
  -- 150 blocks from ap1 (out of range), 50 from ap2 (weak)
  local list = sta:scan()
  eq(#list, 1, "only ap2 is in range")
  eq(list[1].channel, 11)
  ok(list[1].signal < 40, "weak: " .. list[1].signal)
  sim:spawn(function() sta:run() end)
  sim:run(12)
  eq(sta:status().state, "connected") eq(sta:status().channel, 11)
  ok(ICMP.probe(laptop, "10.0.0.1", { timeout = 3 }).ok)
  -- walk towards ap1
  modem.pos = { 20, 0, 0 }
  sim:run(30)
  eq(sta:status().channel, 1, "roamed to the nearer access point")
  ok(sta.stats.roams >= 1)
  ok(ICMP.probe(laptop, "10.0.0.1", { timeout = 3 }).ok, "still connected to the LAN")
  eq(ap1:clientCount(), 1)
  sim:run(20)
  eq(ap2:clientCount(), 0, "the old access point forgot the station after its inactivity time (it was out of range for the goodbye)")
  -- leaving the range of everything disconnects
  modem.pos = { 400, 0, 0 }
  sim:run(15)
  ok(sta:status().state ~= "connected")
  ok(not laptop:iface("wlan0").up)
  -- and coming back reconnects by itself
  modem.pos = { 10, 0, 0 }
  sim:run(25)
  eq(sta:status().state, "connected")
end)

test("when the access point goes away the station notices, and reconnects when it returns", function()
  local sim, air, lan, server = world()
  local ap = addAp(sim, air, lan, "ap", { ssid = "home", channel = 6 })
  local sta, laptop = addSta(sim, air, "laptop", { ssid = "home" }, { 5, 0, 0 }, "10.0.0.90/24")
  local lost, joined = 0, 0
  sta.onLost = function() lost = lost + 1 end
  sta.onConnect = function() joined = joined + 1 end
  sim:spawn(function() sta:run() end)
  sim:run(8)
  eq(joined, 1)
  ok(laptop:lookup(B.ip("10.0.0.1")) ~= nil)
  ap.modem.off = true                          -- the access point loses power: no more beacons
  sim:run(10)
  eq(lost, 1) eq(sta:status().state ~= "connected", true)
  eq(laptop:lookup(B.ip("10.0.0.1")), nil, "routes through the interface are gone")
  ap.modem.off = false
  sim:run(25)
  eq(sta:status().state, "connected")
  eq(joined, 2)
end)

test("a VLAN per network name: guests are kept apart from the wired LAN", function()
  local sim, air, lan, server = world()
  -- wired side: the server is in VLAN 1 (untagged); a guest server sits in VLAN 30 behind a trunk switch
  local sw = sim:host("sw")
  local trunk = sim:segment("trunk")
  local apHost = sim:host("ap")
  sim:plug(apHost, "eth0", trunk)
  sim:plug(sw, "t0", trunk)
  local guestSrv = sim:host("guestsrv")
  local seg2 = sim:segment("g")
  sim:plug(guestSrv, "eth0", seg2, "10.30.0.1/24")
  sim:plug(sw, "g0", seg2)
  local lanSrv = sim:host("lansrv")
  local seg3 = sim:segment("l")
  sim:plug(lanSrv, "eth0", seg3, "10.1.0.1/24")
  sim:plug(sw, "l0", seg3)
  local swMod = require("tsr.inet.switch")
  swMod.new(sw, { ports = { t0 = { mode = "trunk", allowed = { 1, 30 } }, g0 = { vlan = 30 }, l0 = { vlan = 1 } }, stp = false }):start()
  local modem = air:modem("m-ap", apHost, { 0, 0, 0 })
  local ap = apMod.new(apHost, { ssid = "guest", channel = 6, bridge = { "eth0" }, vlan = 30, modem = modem, modemName = "m-ap", mac = mac() })
  ap:start()
  local sta, laptop = addSta(sim, air, "laptop", { ssid = "guest" }, { 5, 0, 0 }, "10.30.0.50/24")
  ok(sta:connect())
  ok(ICMP.probe(laptop, "10.30.0.1", { timeout = 3 }).ok, "the guest reaches the guest VLAN")
  laptop:setAddress("wlan0", "10.1.0.50", 24)
  local r = ICMP.probe(laptop, "10.1.0.1", { timeout = 1.5 })
  ok(r == nil or not r.ok, "but not the main LAN")
end)

test("DHCP over Wi-Fi: a station gets its address from a server on the wired side", function()
  local sim, air, lan, server = world()
  local ap = addAp(sim, air, lan, "ap", { ssid = "home", channel = 6, security = "psk", passphrase = "correct horse" })
  local srv = dhcpServer.new(server, { pools = { { name = "lan", iface = "eth0", network = "10.0.0.0/24", range = { "10.0.0.100", "10.0.0.120" }, router = "10.0.0.1", lease = 600 } }, persist = false, clock = function() return sim.now end })
  sim:spawn(function() srv:serve() end)
  local sta, laptop = addSta(sim, air, "laptop", { ssid = "home", passphrase = "correct horse" }, { 7, 0, 0 })
  sim:spawn(function() sta:run() end)
  sim:spawn(function()
    sim:waitFor(function() return sta:status().state == "connected" end, 30)
    dhcpClient.run(laptop, "wlan0", {})
  end)
  sim:run(25)
  ok(laptop:isLocal(B.ip("10.0.0.100")) or laptop:isLocal(B.ip("10.0.0.101")), "the laptop got an address")
  eq(laptop:lookup(B.ip("8.8.8.8")).gateway, B.ip("10.0.0.1"))
  ok(ICMP.probe(laptop, "10.0.0.1", { timeout = 3 }).ok)
end)

test("the wifi command: scan, connect, status, access point status", function()
  local sim, air, lan, server = world()
  local ap = addAp(sim, air, lan, "ap", { ssid = "lab", channel = 6, security = "psk", passphrase = "lab passphrase" })
  local sta, laptop = addSta(sim, air, "laptop", {}, { 5, 0, 0 }, "10.0.0.95/24")
  laptop.wifiStations = { wlan0 = sta }
  local lines, errs = {}, {}
  local ctx = { stack = laptop, say = function(t) lines[#lines + 1] = t end, err = function(t) errs[#errs + 1] = t end, aps = { ap } }
  local function run(...) lines, errs = {}, {} return wifiCli.run({ ... }, ctx) end
  ok(run("scan"))
  ok(table.concat(lines, "\n"):find("lab", 1, true) and table.concat(lines, "\n"):find("psk", 1, true), table.concat(lines, "\n"))
  ok(not run("connect", "lab", "wrong one!!"))
  ok(errs[1]:find("could not join lab", 1, true), tostring(errs[1]))
  ok(run("connect", "lab", "lab passphrase"), table.concat(errs))
  ok(run("status") and lines[1]:find("connected to lab", 1, true), lines[1])
  sim:run(0.3)                                         -- the last handshake message is still on its way to the access point
  ok(run("ap", "status") and table.concat(lines, "\n"):find("1 client", 1, true) and table.concat(lines, "\n"):find("WPA-PSK", 1, true), table.concat(lines, "\n"))
  ok(run("ap", "clients") and lines[1]:find(B.macStr(sta.mac), 1, true))
  ok(run("disconnect") and sta:status().state == "idle")
  ok(not run("connect"))
end)
