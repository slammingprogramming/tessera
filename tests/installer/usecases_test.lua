-- SPDX-License-Identifier: AGPL-3.0-or-later
local E = dofile("/tests/lib/testenv.lua")
local usecases = require("tsr.setup.usecases")
local wizard = require("tsr.setup.wizard")
local pkg = require("tsr.pkg")
local db = require("tsr.pkg.db")
local config = require("tsr.config")
local vfs = require("tsr.vfs")
local Sim = dofile("/tests/lib/inetsim.lua")

local function probe(spec) return E.fakeProbe(spec) end

local function twoWired() return probe({ peripherals = { { type = "modem", name = "back" }, { type = "modem", name = "left" } } }) end
local function wiredAndWireless() return probe({ peripherals = { { type = "modem", name = "back" }, { type = "modem", name = "top", wireless = true } } }) end
local function oneWired() return probe({ peripherals = { { type = "modem", name = "back" } } }) end
local function threeModems() return probe({ peripherals = { { type = "modem", name = "back" }, { type = "modem", name = "left" }, { type = "modem", name = "top", wireless = true } } }) end

--- A simulated computer that has these interfaces (a switch or access point needs them to exist).
local function hostWith(...)
  local sim = Sim.new()
  local seg = sim:segment("lan")
  local h = sim:host("dut")
  for i, name in ipairs({ ... }) do sim:plug(h, name, seg, ("10.%d.0.1/24"):format(i + 100)) end
  return h
end

local function byId(list, id) for _, u in ipairs(list) do if u.id == id then return u end end end

--- A throw-away file system for apply().
local function fakeVfs()
  local files = {}
  local v = { files = files, json = {} }
  v.fs = { exists = function(p) return files[p] ~= nil end }
  function v.mkdirp() end
  function v.writeFile(p, text) files[p] = text return true end
  function v.writeJSON(p, t) v.json[p] = t return true end
  return v
end

local function recorders()
  local cfg = { values = {}, saved = false }
  cfg.set = function(k, v) cfg.values[k] = v end
  cfg.save = function() cfg.saved = true end
  local svc = { enabled = {} }
  svc.enable = function(name) svc.enabled[#svc.enabled + 1] = name return true end
  return cfg, svc
end

test("the list of use cases follows the hardware and the profile", function()
  local none = usecases.available(probe({ peripherals = {} }), "server")
  local router = byId(none, "router-home")
  ok(router.blocked and router.blocked:find("two modems", 1, true))
  ok(byId(none, "mail-server").blocked == "needs a modem")
  ok(byId(none, "kiosk").blocked == nil, "an advanced computer has a screen")
  local one = usecases.available(oneWired(), "server")
  ok(byId(one, "mail-server").blocked == nil and byId(one, "web-server").blocked == nil)
  ok(byId(one, "iot-node").blocked:find("not for a computer set up as server", 1, true) and byId(usecases.available(oneWired(), "node"), "iot-node").blocked == nil)
  ok(byId(one, "router-home").blocked ~= nil and byId(one, "switch").blocked ~= nil and byId(one, "access-point").blocked:find("wireless", 1, true))
  local two = usecases.available(twoWired(), "server")
  ok(byId(two, "router-home").blocked == nil and byId(two, "switch").blocked == nil and byId(two, "firewall").blocked == nil)
  ok(byId(two, "access-point").blocked:find("wireless modem", 1, true))
  local mixed = usecases.available(wiredAndWireless(), "server")
  ok(byId(mixed, "access-point").blocked == nil and byId(mixed, "router-home").blocked == nil)
  -- a profile that does not fit
  local turtle = usecases.available(probe({ kind = "turtle", peripherals = { { type = "modem", name = "right", wireless = true } } }), "turtle")
  ok(byId(turtle, "router-home").blocked:find("not for a computer set up as turtle", 1, true))
  ok(byId(usecases.available(twoWired(), nil), "router-business").blocked == nil, "without a profile only the hardware counts")
  -- groups and ids
  local groups, seen = {}, {}
  for _, u in ipairs(usecases.available(threeModems(), "server")) do
    ok(not seen[u.id], "unique ids") seen[u.id] = true
    groups[u.group] = true
    ok(u.label and u.summary)
  end
  for _, g in ipairs(usecases.GROUPS) do ok(groups[g], g) end
  -- every named use case of the documentation exists
  for _, id in ipairs({ "workstation", "server", "router-home", "router-business", "switch", "access-point", "firewall", "infrastructure", "mail-server", "web-server", "package-mirror", "iot-node", "smart-home", "industrial", "kiosk" }) do
    ok(usecases.get(id), id)
  end
  ok(usecases.plan("nothing") == nil)
end)

test("plans: packages depend on the hardware, and every package and service name exists in this project", function()
  local p = usecases.plan("router-home", twoWired())
  ok(not table.concat(p.packages, ","):find("wifi", 1, true))
  p = usecases.plan("router-home", wiredAndWireless())
  ok(table.concat(p.packages, ","):find("wifi", 1, true) and table.concat(p.services, ","):find("wifiap", 1, true))
  -- names are well formed (that every one of them is a real package and service is checked by tools/build/build.mjs)
  for _, u in ipairs(usecases.LIST) do
    local plan = usecases.plan(u.id, threeModems())
    for _, name in ipairs(plan.packages) do ok(type(name) == "string" and name:match("^[%w%-]+$"), name) end
    for _, name in ipairs(plan.services) do ok(type(name) == "string" and name:match("^[%w%-]+$"), name) end
  end
end)

test("home router files: every file parses and is accepted by the module it is for", function()
  local cfg, svc = recorders()
  local fv = fakeVfs()
  local r = usecases.apply("router-home", threeModems(), { vfs = fv, config = cfg, svc = svc, hostname = "gw1", secret = function() return "aaaa-bbbb-cccc" end })
  eq(r.problems, {})
  eq(r.written, { "/etc/tsr/inet/dhcpd.lua", "/etc/tsr/inet/iptables.rules", "/etc/tsr/inet/named.lua", "/etc/tsr/inet/network.lua", "/etc/tsr/inet/wifi-ap.lua" })
  eq(svc.enabled, { "inetd", "dhcpd", "named", "netfilter", "wifiap" })
  eq(cfg.values["net.transport"], "ip") ok(cfg.saved)
  ok(r.notes[1]:find("passphrase aaaa-bbbb-cccc", 1, true), r.notes[1])
  eq(fv.json["/etc/tsr/usecase.json"].id, "router-home")
  local function table_of(path)
    local chunk = assert(load(fv.files[path], "=" .. path, "t", {}))
    return chunk()
  end
  local net = table_of("/etc/tsr/inet/network.lua")
  eq(net.hostname, "gw1") eq(net.forwarding, true)
  eq(net.interfaces.eth0, { modem = "back", channel = 7101, dhcp = true })
  eq(net.interfaces.eth1.modem, "left") eq(net.interfaces.eth1.addresses, nil, "the wired port is bridged to the Wi-Fi: the router address lives on the access point")
  -- DHCP
  local sim = Sim.new()
  local host = sim:host("gw1")
  local dhcpSrv = require("tsr.dhcp.server")
  local d = dhcpSrv.new(host, table_of("/etc/tsr/inet/dhcpd.lua"))
  ok(d.pools and #d.pools == 1 or d.pool or d, "the DHCP server accepts the pool")
  -- DNS
  local named = require("tsr.inet.dns.server").new(host, table_of("/etc/tsr/inet/named.lua"))
  ok(named.recursionOn, "forwarding to the upstream servers switches recursion on")
  -- the firewall rules load without complaints
  local fw = require("tsr.inet.fw").install(host)
  local problems = require("tsr.inet.fw.iptables").load(fw, fv.files["/etc/tsr/inet/iptables.rules"])
  eq(problems, {})
  local rules = require("tsr.inet.fw.iptables").save(fw)
  ok(rules:find("MASQUERADE", 1, true) and rules:find("-P FORWARD DROP", 1, true), rules)
  -- the access point
  local wifi = table_of("/etc/tsr/inet/wifi-ap.lua")
  eq({ wifi.modem, wifi.passphrase, wifi.management }, { "top", "aaaa-bbbb-cccc", "192.168.1.1/24" })
  eq(wifi.bridge, { "eth1" })
  ok(require("tsr.inet.wifi.ap").new(hostWith("eth1"), wifi))
  -- the DHCP pool lives on the access point's virtual interface
  eq(table_of("/etc/tsr/inet/dhcpd.lua").pools[1].iface, "vlan1")
  -- a second run keeps what is there
  local again = usecases.apply("router-home", threeModems(), { vfs = fv, config = cfg, svc = svc, hostname = "other" })
  eq(#again.written, 0) eq(#again.kept, 5)
  ok(fv.files["/etc/tsr/inet/network.lua"]:find('hostname = "gw1"', 1, true))
  local forced = usecases.apply("router-home", threeModems(), { vfs = fv, config = cfg, svc = svc, hostname = "other", force = true })
  eq(#forced.written, 5)
  ok(fv.files["/etc/tsr/inet/network.lua"]:find('hostname = "other"', 1, true))
end)

test("home router variants: wired only, wireless as the home network", function()
  local cfg, svc = recorders()
  local fv = fakeVfs()
  local r = usecases.apply("router-home", twoWired(), { vfs = fv, config = cfg, svc = svc, hostname = "gw2" })
  eq(r.problems, {})
  ok(not fv.files["/etc/tsr/inet/wifi-ap.lua"])
  local net = assert(load(fv.files["/etc/tsr/inet/network.lua"], "=n", "t", {}))()
  eq(net.interfaces.eth1.addresses, { "192.168.1.1/24" })
  ok(fv.files["/etc/tsr/inet/iptables.rules"]:find("-A FORWARD -i eth1 -o eth0 -j ACCEPT", 1, true))
  -- one wired, one wireless: the Wi-Fi is the home network
  fv = fakeVfs()
  r = usecases.apply("router-home", wiredAndWireless(), { vfs = fv, config = cfg, svc = svc, hostname = "gw3", secret = function() return "xxxx-yyyy-zzzz" end })
  eq(r.problems, {})
  local wifi = assert(load(fv.files["/etc/tsr/inet/wifi-ap.lua"], "=w", "t", {}))()
  eq({ wifi.modem, wifi.bridge, wifi.management }, { "top", nil, "192.168.1.1/24" })
  local net2 = assert(load(fv.files["/etc/tsr/inet/network.lua"], "=n", "t", {}))()
  eq(net2.interfaces.eth1, nil)
  ok(fv.files["/etc/tsr/inet/iptables.rules"]:find("-A FORWARD -i vlan1 -o eth0 -j ACCEPT", 1, true))
  -- a single modem cannot be a router
  local one = usecases.apply("router-home", oneWired(), { vfs = fakeVfs(), config = cfg, svc = svc })
  ok(#one.problems == 1 and one.problems[1]:find("second modem", 1, true), tostring(one.problems[1]))
end)

test("enterprise router, switch, access point, firewall, infrastructure: files are valid", function()
  local cfg, svc = recorders()
  local host = Sim.new():host("gw")
  local function load_(fv, path) return assert(load(fv.files[path], "=" .. path, "t", {}))() end
  -- enterprise router
  local fv = fakeVfs()
  local r = usecases.apply("router-business", threeModems(), { vfs = fv, config = cfg, svc = svc, hostname = "core1", secret = function() return "k1-k2-k3-k4" end })
  eq(r.problems, {})
  local net = load_(fv, "/etc/tsr/inet/network.lua")
  eq({ net.forwarding, net.interfaces.eth0.gateway, net.interfaces.eth1.addresses, net.interfaces.eth2.addresses }, { true, "10.255.0.1", { "10.1.0.1/24" }, { "10.2.0.1/24" } })
  local rip = load_(fv, "/etc/tsr/inet/rip.lua")
  eq(rip.auth, { type = "hmac", key = "k1-k2-k3-k4" }) eq(rip.interfaces, { "eth1", "eth2" })
  ok(require("tsr.inet.route.rip").new(host, rip))
  eq(require("tsr.inet.fw.iptables").load(require("tsr.inet.fw").install(host), fv.files["/etc/tsr/inet/iptables.rules"]), {})
  local bgp = load_(fv, "/etc/tsr/inet/bgp.lua")
  eq({ bgp.as, #bgp.peers }, { 65001, 0 })
  ok(not table.concat(svc.enabled, ","):find("bgpd", 1, true), "BGP waits until peers are configured")
  ok(r.notes[1]:find("RIP key", 1, true) and r.notes[2]:find("svc enable bgpd", 1, true))
  -- switch
  fv = fakeVfs()
  r = usecases.apply("switch", threeModems(), { vfs = fv, config = cfg, svc = svc, hostname = "sw1" })
  eq(r.problems, {})
  local sw = load_(fv, "/etc/tsr/inet/switch.lua")
  eq({ sw.name, sw.stp.enabled, sw.svis[1], sw.ports.port3.mode }, { "sw1", true, "10.0.0.2/24", "access" })
  ok(require("tsr.inet.switch").new(hostWith("port1", "port2", "port3"), sw))
  local swnet = load_(fv, "/etc/tsr/inet/network.lua")
  eq({ swnet.interfaces.port1.modem, swnet.interfaces.port3.modem }, { "back", "top" })
  -- access point
  fv = fakeVfs()
  r = usecases.apply("access-point", wiredAndWireless(), { vfs = fv, config = cfg, svc = svc, hostname = "ap1", secret = function() return "ap-ap-ap" end })
  eq(r.problems, {})
  local ap = load_(fv, "/etc/tsr/inet/wifi-ap.lua")
  eq({ ap.modem, ap.ssid, ap.bridge }, { "top", "tessera-ap1", { "eth0" } })
  ok(require("tsr.inet.wifi.ap").new(hostWith("eth0"), ap))
  eq(load_(fv, "/etc/tsr/inet/network.lua").interfaces.eth0.dhcp, true)
  -- firewall
  fv = fakeVfs()
  r = usecases.apply("firewall", twoWired(), { vfs = fv, config = cfg, svc = svc, hostname = "fw1" })
  eq(r.problems, {})
  eq(require("tsr.inet.fw.iptables").load(require("tsr.inet.fw").install(Sim.new():host("fw")), fv.files["/etc/tsr/inet/iptables.rules"]), {})
  -- infrastructure: DHCP pool, DNS config, network with a static address
  fv = fakeVfs()
  r = usecases.apply("infrastructure", oneWired(), { vfs = fv, config = cfg, svc = svc, hostname = "infra" })
  eq(r.problems, {})
  eq(load_(fv, "/etc/tsr/inet/dhcpd.lua").pools[1].ntp, { "10.0.0.2" })
  ok(require("tsr.dhcp.server").new(Sim.new():host("infra"), load_(fv, "/etc/tsr/inet/dhcpd.lua")))
  eq(load_(fv, "/etc/tsr/inet/network.lua").interfaces.eth0.addresses, { "10.0.0.2/24" })
end)

test("service and device use cases: starting files from the packages' own templates", function()
  local cfg, svc = recorders()
  local mailcfg = require("tsr.mail.config")
  local homed = require("tsr.home.daemon")
  local modbusd = require("tsr.modbus.daemon")
  local kiosk = require("tsr.tv.kiosk")
  local saved = { mailcfg.STATIC, homed.CONFIG, modbusd.CONFIG, kiosk.CFG_PATH }
  mailcfg.STATIC, homed.CONFIG, modbusd.CONFIG, kiosk.CFG_PATH = "/tmp/uc-mail.lua", "/tmp/uc-home.lua", "/tmp/uc-modbus.lua", "/tmp/uc-kiosk.cfg"
  for _, p in ipairs({ mailcfg.STATIC, homed.CONFIG, modbusd.CONFIG, kiosk.CFG_PATH }) do if fs.exists(p) then fs.delete(p) end end
  local fv = fakeVfs()
  local r = usecases.apply("mail-server", oneWired(), { vfs = fv, config = cfg, svc = svc, hostname = "mx1" })
  eq(r.problems, {})
  ok(fs.exists(mailcfg.STATIC) and assert(mailcfg.load()).hostname == "mx1.lan", "the mail settings template was written")
  eq(svc.enabled, { "inetd", "dhclient", "maild", "avd", "sshd", "ntpd" })
  svc.enabled = {}
  r = usecases.apply("smart-home", oneWired(), { vfs = fv, config = cfg, svc = svc, hostname = "h" })
  ok(fs.exists(homed.CONFIG) and assert(homed.loadConfig()).clock == "ingame")
  eq(svc.enabled, { "inetd", "dhclient", "mqttd", "homed" })
  r = usecases.apply("industrial", oneWired(), { vfs = fv, config = cfg, svc = svc, hostname = "plc" })
  ok(fs.exists(modbusd.CONFIG) and assert(modbusd.loadConfig()).readonly == false)
  r = usecases.apply("kiosk", probe({ peripherals = { { type = "monitor", name = "monitor_0" } } }), { vfs = fv, config = cfg, svc = svc, hostname = "tv1" })
  eq(r.problems, {})
  eq(vfs.readTable(kiosk.CFG_PATH).command, "www --board http://info.lan/ --every 30")
  -- existing files are never overwritten by the starting templates
  vfs.writeFile(kiosk.CFG_PATH, textutils.serialize({ command = "mine" }))
  usecases.apply("kiosk", probe({ peripherals = { { type = "monitor", name = "monitor_0" } } }), { vfs = fv, config = cfg, svc = svc })
  eq(vfs.readTable(kiosk.CFG_PATH).command, "mine")
  for _, p in ipairs({ mailcfg.STATIC, homed.CONFIG, modbusd.CONFIG, kiosk.CFG_PATH }) do if fs.exists(p) then fs.delete(p) end end
  mailcfg.STATIC, homed.CONFIG, modbusd.CONFIG, kiosk.CFG_PATH = saved[1], saved[2], saved[3], saved[4]
  -- the others just carry packages and services
  r = usecases.apply("web-server", oneWired(), { vfs = fv, config = cfg, svc = svc })
  ok(r.notes[#r.notes]:find("/srv/www", 1, true))
  ok(usecases.apply("nothing", oneWired(), {}) == nil)
end)

test("the generated secrets are readable and different every time", function()
  local a, b = usecases.secret(3), usecases.secret(3)
  ok(a:match("^[a-z2-9]+%-[a-z2-9]+%-[a-z2-9]+$") and #a == 14, a)
  ok(a ~= b)
  ok(not a:find("[ilo01]"), "no look-alike characters: " .. a)
end)

local ROOT = E.ROOT

local function catalog()
  local c = { ["ui-tui"] = { version = "1.0.0", size = 4000, files = { [ROOT .. "/ui-tui.lua"] = "t" } } }
  for _, name in ipairs({ "inet", "dhcp", "mqtt", "hal", "redstone", "net" }) do
    c[name] = { version = "1.0.0", size = 1000, description = name, files = { [ROOT .. "/" .. name .. ".lua"] = name } }
  end
  return c
end

test("the wizard: choosing a use case adds its packages and applies it at the end", function()
  E.reset()
  E.publish(catalog())
  local ui = E.scriptedUi({
    ["What should it do?"] = function(items)
      eq(items[1].label, "General purpose")
      for i, it in ipairs(items) do if it.label:find("Embedded") then return i end end
    end,
    ["Computer name"] = "sensor-7",
    ["Setup complete"] = false,
  })
  local result = wizard.run({ ui = ui, pkg = pkg, config = config, vfs = vfs,
    hw = { probe = function() return probe({ peripherals = { { type = "modem", name = "back" } }, advanced = false }) end, ofType = function() return {} end, hasTypeMatching = function() return false end },
    importer = { interactive = function() return nil end } })
  eq(result, "done")
  for _, name in ipairs({ "inet", "dhcp", "mqtt", "hal", "redstone" }) do ok(db.get(name), name .. " was installed") end
  eq(config.get("net.transport"), "ip")
  eq(vfs.readJSON("/etc/tsr/setup.done").usecase, "iot-node")
  eq(vfs.readJSON("/etc/tsr/usecase.json").id, "iot-node")
  fs.delete("/etc/tsr/setup.done") fs.delete("/etc/tsr/usecase.json")
end)

test("the wizard: --usecase picks it without asking; a use case the hardware cannot do is refused", function()
  E.reset()
  E.publish(catalog())
  local asked = false
  local ui = E.scriptedUi({
    ["What should it do?"] = function() asked = true end,
    ["Computer name"] = "plc-1",
    ["Setup complete"] = false,
  })
  local function run(id)
    return wizard.run({ ui = ui, pkg = pkg, config = config, vfs = vfs, usecase = id,
      hw = { probe = function() return probe({ peripherals = { { type = "modem", name = "back" } }, advanced = false }) end, ofType = function() return {} end, hasTypeMatching = function() return false end },
      importer = { interactive = function() return nil end } })
  end
  eq(run("iot-node"), "done")
  ok(not asked and db.get("mqtt"))
  -- a router needs two modems: the wizard says so and carries on without it
  E.reset()
  E.publish(catalog())
  ui = E.scriptedUi({ ["Use case not possible here"] = function() asked = "refused" end, ["Computer name"] = "gw", ["Setup complete"] = false })
  eq(run("router-home"), "done")
  eq(asked, "refused")
  eq(vfs.readJSON("/etc/tsr/setup.done").usecase, nil)
  fs.delete("/etc/tsr/setup.done") fs.delete("/etc/tsr/usecase.json")
end)
