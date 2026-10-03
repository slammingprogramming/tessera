-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Use cases: what a computer is *for*, beyond the kind of computer it is (the profile). Each use case is a bundle of packages, services, settings and
-- starting files, so that a new computer can become a home router, a managed switch, a mail server, a smart-home hub or an industrial controller in one step.
--   M.available(probe, profile)  the list for the wizard: { id, group, label, summary, blocked, recommended, reason }
--   M.plan(id, probe, opts)      what applying it would do: { packages, services, files, config, notes }   (files are produced by apply, once the packages are there)
--   M.apply(id, probe, env)      write the files that do not exist yet, set the settings, enable the services. Returns { written, kept, enabled, notes, problems }
-- Starting files never overwrite an existing file; generated secrets (Wi-Fi passphrase, routing key) are returned in `notes` once.
local M = {}

M.GROUPS = { "Computers", "Network equipment", "Services", "Devices and automation" }

---------------------------------------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------------------------------------

--- The modems of this computer: wired and wireless peripheral names.
local function nics(probe)
  local wired, wireless = {}, {}
  for _, p in ipairs(probe.peripherals or {}) do
    if p.isType and p.isType.modem and not p.remote then
      if p.wireless then wireless[#wireless + 1] = p.name else wired[#wired + 1] = p.name end
    end
  end
  table.sort(wired)
  table.sort(wireless)
  return wired, wireless
end

local function q(s) return ("%q"):format(s) end

local function random(n)
  local ok, crypto = pcall(require, "tsr.crypto")
  local bytes
  if ok and crypto.rand then bytes = crypto.rand.bytes(n) end
  if not bytes then
    math.randomseed((os.epoch and os.epoch("utc") or 0) + os.clock() * 1000)
    local t = {}
    for i = 1, n do t[i] = string.char(math.random(0, 255)) end
    bytes = table.concat(t)
  end
  return bytes
end

local ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789"
--- A readable random secret, e.g. "kx7h-m2qa-9fte".
local function secret(groups)
  local bytes = random(groups * 4)
  local out = {}
  for g = 1, groups do
    local part = {}
    for i = 1, 4 do
      local b = bytes:byte((g - 1) * 4 + i)
      part[i] = ALPHABET:sub(b % #ALPHABET + 1, b % #ALPHABET + 1)
    end
    out[g] = table.concat(part)
  end
  return table.concat(out, "-")
end

local function hostOf(opts) return (opts and opts.hostname) or "tessera" end

local NEEDS_MODEM = function(probe) if not probe.hasModem then return "needs a modem" end end

--- The network configuration file for interfaces: list of { name, modem, channel, addresses, dhcp, gateway, key }.
local function networkFile(host, forwarding, ifaces, extra)
  local lines = { "-- Network configuration (written by tsr-setup; edit freely). See: help network", "return {", "  hostname = " .. q(host) .. "," }
  if forwarding then lines[#lines + 1] = "  forwarding = true," end
  lines[#lines + 1] = "  interfaces = {"
  for _, i in ipairs(ifaces) do
    local parts = { "modem = " .. q(i.modem), "channel = " .. i.channel }
    if i.addresses then
      local a = {}
      for _, x in ipairs(i.addresses) do a[#a + 1] = q(x) end
      parts[#parts + 1] = "addresses = { " .. table.concat(a, ", ") .. " }"
    end
    if i.dhcp then parts[#parts + 1] = "dhcp = true" end
    if i.gateway then parts[#parts + 1] = "gateway = " .. q(i.gateway) end
    lines[#lines + 1] = ("    %s = { %s },"):format(i.name, table.concat(parts, ", "))
  end
  lines[#lines + 1] = "  },"
  for _, l in ipairs(extra or {}) do lines[#lines + 1] = "  " .. l end
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n") .. "\n"
end

M.networkFile = networkFile

local NETWORK = "/etc/tsr/inet/network.lua"
local DHCPD = "/etc/tsr/inet/dhcpd.lua"
local NAMED = "/etc/tsr/inet/named.lua"
local RULES = "/etc/tsr/inet/iptables.rules"
local WIFI = "/etc/tsr/inet/wifi-ap.lua"
local SWITCH = "/etc/tsr/inet/switch.lua"
local RIP = "/etc/tsr/inet/rip.lua"
local BGP = "/etc/tsr/inet/bgp.lua"

---------------------------------------------------------------------------------------------------------------------
-- The catalogue
---------------------------------------------------------------------------------------------------------------------

M.LIST = {
  -- Computers ------------------------------------------------------------------------------------------------------
  { id = "workstation", group = "Computers", label = "Client PC (workstation)",
    summary = "Everyday computer on the network: browser, mail, remote shell, files from other computers.",
    profiles = { "client", "client-lite" },
    packages = function(probe) local p = { "inet", "dhcp", "web", "ssh" } if probe.hasModem then p[#p + 1] = "mail" end return p end,
    services = { "inetd", "dhclient" },
    config = { ["net.transport"] = "ip" },
    notes = "It gets its address by DHCP. Try: ping, www, fetch, ssh. Mail: mail account set ... (see help mail).",
    needs = NEEDS_MODEM },

  { id = "server", group = "Computers", label = "Server (general purpose)",
    summary = "A computer other computers rely on: remote login, time, firewall, scheduled jobs, central logs.",
    profiles = { "server" },
    packages = { "inet", "dhcp", "svc-manager", "ssh", "ntp", "firewall", "ops", "netmon" },
    services = { "inetd", "dhclient", "sshd", "ntpd", "crond" },
    config = { ["net.transport"] = "ip" },
    notes = "Add what it should serve: tsr-setup again and pick a service role, or pkg install ...",
    needs = NEEDS_MODEM },

  -- Network equipment ----------------------------------------------------------------------------------------------
  { id = "router-home", group = "Network equipment", label = "Home router (consumer)",
    summary = "One address from the provider, a private network behind it: DHCP, DNS, NAT, a firewall, and Wi-Fi with a wireless modem.",
    profiles = { "server", "client", "client-lite" },
    packages = function(probe)
      local _, wireless = nics(probe)
      local p = { "inet", "dhcp", "inet-dns", "inet-fw" }
      if #wireless > 0 then p[#p + 1] = "wifi" end
      return p
    end,
    services = function(probe)
      local _, wireless = nics(probe)
      local s = { "inetd", "dhcpd", "named", "netfilter" }
      if #wireless > 0 then s[#s + 1] = "wifiap" end
      return s
    end,
    config = { ["net.transport"] = "ip" },
    needs = function(probe)
      local wired, wireless = nics(probe)
      if #wired + #wireless < 2 then return "needs two modems (one towards the provider, one for your own network)" end
    end,
    files = function(probe, opts, gen)
      local wired, wireless = nics(probe)
      local host = hostOf(opts)
      local all, isWired = {}, {}
      for _, n in ipairs(wired) do all[#all + 1] = n isWired[n] = true end
      for _, n in ipairs(wireless) do all[#all + 1] = n end
      local wan = all[1]
      local lanWired, lanWireless
      for i = 2, #all do
        if isWired[all[i]] then lanWired = lanWired or all[i] else lanWireless = lanWireless or all[i] end
      end
      if not lanWired and not lanWireless then return nil, "could not find a second modem for the home network" end
      -- the home network is the Wi-Fi access point (its virtual interface vlan1 carries the router address), or the wired port when there is no wireless modem
      local lanName = lanWireless and "vlan1" or "eth1"
      local ifaces = { { name = "eth0", modem = wan, channel = 7101, dhcp = true } }
      if lanWired then ifaces[2] = { name = "eth1", modem = lanWired, channel = 7102, addresses = (not lanWireless) and { "192.168.1.1/24" } or nil } end
      local files, notes = {}, {}
      files[NETWORK] = networkFile(host, true, ifaces, { 'dns = { "192.168.1.1" },' })
      files[DHCPD] = ([[
-- DHCP server for the home network
return { pools = {
  { name = "home", iface = %s, network = "192.168.1.0/24", range = { "192.168.1.100", "192.168.1.199" }, router = "192.168.1.1",
    dns = { "192.168.1.1" }, domain = "home.lan", lease = 3600 },
} }
]]):format(q(lanName))
      files[NAMED] = [[
-- Name server of the home network: asks the provider's servers (learned by DHCP) for everything it does not know.
return {
  recursion = true,
  allowRecursion = { "192.168.1.0/24" },
  forwarders = "upstream",
}
]]
      files[RULES] = ([[
# Home router firewall: nothing from outside gets in unless we asked for it; the home network may go out (NAT).
-P INPUT DROP
-P FORWARD DROP
-A INPUT -i lo -j ACCEPT
-A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
-A INPUT -i eth0 -p udp --dport 68 -j ACCEPT
-A INPUT -i %s -p udp --dport 67 -j ACCEPT
-A INPUT -i %s -p udp --dport 53 -j ACCEPT
-A INPUT -i %s -p tcp --dport 53 -j ACCEPT
-A INPUT -i %s -p icmp --icmp-type echo-request -j ACCEPT
-A INPUT -p icmp --icmp-type echo-request -m limit --limit 5/second -j ACCEPT
-A FORWARD -i %s -o eth0 -j ACCEPT
-A FORWARD -i eth0 -o %s -m state --state ESTABLISHED,RELATED -j ACCEPT
-t nat -A POSTROUTING -o eth0 -j MASQUERADE
]]):format(lanName, lanName, lanName, lanName, lanName, lanName)
      if lanWireless then
        local pass = gen.secret(3)
        files[WIFI] = ([[
-- The Wi-Fi of the home network%s.
return { modem = %s, ssid = %s, channel = 6, security = "psk", passphrase = %s,%s management = "192.168.1.1/24", maxClients = 16 }
]]):format(lanWired and ", joined to the wired port" or "", q(lanWireless), q("tessera-" .. host), q(pass), lanWired and ' bridge = { "eth1" },' or "")
        notes[#notes + 1] = ("Wi-Fi: network %q, passphrase %s"):format("tessera-" .. host, pass)
      end
      return files, notes
    end,
    notes = "WAN: first modem (asks the provider by DHCP). Home network 192.168.1.0/24 behind it. Look at: ip addr, iptables -L -n, nslookup.",
  },

  { id = "router-business", group = "Network equipment", label = "Enterprise router",
    summary = "Routes between several networks (VLANs), RIP with authentication, firewall with management only from the admin network, time, logs, ready for BGP peering.",
    profiles = { "server" },
    packages = { "inet", "dhcp", "inet-dns", "inet-fw", "inet-route", "bgp", "inet-switch", "ssh", "ntp", "netmon", "ops" },
    services = { "inetd", "dhcprelay", "netfilter", "ripd", "sshd", "ntpd", "crond" },
    config = { ["net.transport"] = "ip" },
    needs = function(probe)
      local wired, wireless = nics(probe)
      if #wired + #wireless < 2 then return "needs at least two modems (uplink and inside)" end
    end,
    files = function(probe, opts, gen)
      local wired, wireless = nics(probe)
      local all = {}
      for _, n in ipairs(wired) do all[#all + 1] = n end
      for _, n in ipairs(wireless) do all[#all + 1] = n end
      local host = hostOf(opts)
      local files, notes = {}, {}
      local ifaces = { { name = "eth0", modem = all[1], channel = 7101, addresses = { "10.255.0.2/30" }, gateway = "10.255.0.1" } }
      for i = 2, #all do
        ifaces[#ifaces + 1] = { name = "eth" .. (i - 1), modem = all[i], channel = 7101 + (i - 1), addresses = { ("10.%d.0.1/24"):format(i - 1) } }
      end
      files[NETWORK] = networkFile(host, true, ifaces, {
        "-- VLAN sub-interface example (a tagged network on the inside link):",
        '-- ["eth1.20"] = { vlan = 20, parent = "eth1", addresses = { "10.20.0.1/24" } },',
      })
      local key = gen.secret(4)
      files[RIP] = ([[
-- RIP version 2 between our routers; updates must carry the shared key (HMAC).
return { interfaces = { %s }, redistribute = { "connected" }, auth = { type = "hmac", key = %s } }
]]):format(table.concat((function() local t = {} for i = 2, #ifaces do t[#t + 1] = q(ifaces[i].name) end return t end)(), ", "), q(key))
      files[RULES] = [[
# Enterprise router: stateful forwarding, administration only from the inside network, limited ping.
-P INPUT DROP
-P FORWARD DROP
-A INPUT -i lo -j ACCEPT
-A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
-A INPUT -p udp --dport 520 -j ACCEPT
-A INPUT -p tcp --dport 179 -j ACCEPT
-A INPUT -i eth1 -p tcp --dport 22 -j ACCEPT
-A INPUT -p icmp --icmp-type echo-request -m limit --limit 5/second -j ACCEPT
-A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
-A FORWARD -i eth1 -j ACCEPT
]]
      files[BGP] = [[
-- BGP-4 peering (not started automatically: svc enable bgpd when the agreement is made). Relationship decides who gets what:
-- customer = they pay us, peer = free exchange, provider = we pay them.
return { as = 65001, routerId = "10.255.0.2", networks = { "10.1.0.0/16" }, peers = {
  -- { ip = "10.255.0.1", as = 65000, relationship = "provider", maxPrefixes = 1000 },
} }
]]
      notes[#notes + 1] = "RIP key (the other routers need the same): " .. key
      notes[#notes + 1] = "Peering: edit " .. BGP .. " and enable it with: svc enable bgpd"
      return files, notes
    end,
    notes = "Edit /etc/tsr/inet/network.lua for your addresses. Policy: iptables -L; routes: routectl; capture: tcpdump.",
  },

  { id = "switch", group = "Network equipment", label = "Managed switch",
    summary = "Joins its modems into one network: MAC learning, VLANs, Spanning Tree, port security, mirroring.",
    profiles = { "server", "node" },
    packages = { "inet", "inet-switch", "ssh" },
    services = { "inetd", "switchd", "sshd" },
    config = { ["net.transport"] = "ip" },
    needs = function(probe)
      local wired, wireless = nics(probe)
      if #wired + #wireless < 2 then return "needs at least two modems (the ports)" end
    end,
    files = function(probe, opts)
      local wired, wireless = nics(probe)
      local all = {}
      for _, n in ipairs(wired) do all[#all + 1] = n end
      for _, n in ipairs(wireless) do all[#all + 1] = n end
      local ifaces, ports = {}, {}
      for i, m in ipairs(all) do
        ifaces[#ifaces + 1] = { name = "port" .. i, modem = m, channel = 7101 }
        ports[#ports + 1] = ("    port%d = { mode = \"access\", vlan = 1 },"):format(i)
      end
      local files = {}
      files[NETWORK] = networkFile(hostOf(opts), false, ifaces, { "-- the switch's own address is on the management VLAN (see switch.lua)" })
      files[SWITCH] = ([[
-- Switch settings: ports, VLANs, Spanning Tree. Port names are the interface names of the network configuration.
return {
  name = %s,
  stp = { enabled = true, priority = 32768 },
  lldp = true,
  ports = {
%s
  },
  vlans = { [1] = "default" },
  svis = { [1] = "10.0.0.2/24" },
}
]]):format(q(hostOf(opts)), table.concat(ports, "\n"))
      return files, {}
    end,
    notes = "Every modem is a port. Change a port to a trunk or another VLAN in /etc/tsr/inet/switch.lua, then: svc restart switchd. Look: swctl show.",
  },

  { id = "access-point", group = "Network equipment", label = "Wi-Fi access point",
    summary = "Brings wireless computers onto a wired network (bridge), with a passphrase, client limits and optional VLAN.",
    profiles = { "server", "node" },
    packages = { "inet", "wifi", "ssh" },
    services = { "inetd", "wifiap", "sshd" },
    config = { ["net.transport"] = "ip" },
    needs = function(probe)
      local wired, wireless = nics(probe)
      if #wireless == 0 then return "needs a wireless modem" end
      if #wired == 0 then return "needs a wired modem for the cable side" end
    end,
    files = function(probe, opts, gen)
      local wired, wireless = nics(probe)
      local host = hostOf(opts)
      local pass = gen.secret(3)
      local files = {}
      files[NETWORK] = networkFile(host, false, { { name = "eth0", modem = wired[1], channel = 7101, dhcp = true } })
      files[WIFI] = ([[
-- Access point: the wireless network is bridged to the cable on eth0.
return { modem = %s, ssid = %s, channel = 6, security = "psk", passphrase = %s, bridge = { "eth0" }, maxClients = 24, isolate = false }
]]):format(q(wireless[1]), q("tessera-" .. host), q(pass))
      return files, { ("Wi-Fi: network %q, passphrase %s"):format("tessera-" .. host, pass) }
    end,
    notes = "Check who is connected: wifi clients. Change the settings in /etc/tsr/inet/wifi-ap.lua and: svc restart wifiap.",
  },

  { id = "firewall", group = "Network equipment", label = "Firewall appliance",
    summary = "Sits between two networks and decides what passes: stateful rules, logging, rate limits, packet capture for investigation.",
    profiles = { "server" },
    packages = { "inet", "inet-fw", "netmon", "ssh" },
    services = { "inetd", "netfilter", "sshd" },
    config = { ["net.transport"] = "ip" },
    needs = function(probe)
      local wired, wireless = nics(probe)
      if #wired + #wireless < 2 then return "needs two modems (outside and inside)" end
    end,
    files = function(probe, opts)
      local wired, wireless = nics(probe)
      local all = {}
      for _, n in ipairs(wired) do all[#all + 1] = n end
      for _, n in ipairs(wireless) do all[#all + 1] = n end
      local files = {}
      files[NETWORK] = networkFile(hostOf(opts), true, {
        { name = "eth0", modem = all[1], channel = 7101, addresses = { "10.255.0.2/30" }, gateway = "10.255.0.1" },
        { name = "eth1", modem = all[2], channel = 7102, addresses = { "10.1.0.1/24" } },
      })
      files[RULES] = [[
# Firewall appliance: inside (eth1) may go out; outside (eth0) may only answer. Management from inside only.
-P INPUT DROP
-P FORWARD DROP
-A INPUT -i lo -j ACCEPT
-A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
-A INPUT -i eth1 -p tcp --dport 22 -j ACCEPT
-A INPUT -p icmp --icmp-type echo-request -m limit --limit 5/second -j ACCEPT
-A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
-A FORWARD -i eth1 -o eth0 -j ACCEPT
-A FORWARD -i eth0 -o eth1 -p tcp --dport 80 -d 10.1.0.80 -j ACCEPT
-A FORWARD -j LOG --log-prefix "denied: "
]]
      return files, {}
    end,
    notes = "Edit the addresses in /etc/tsr/inet/network.lua. See what is blocked: iptables -L -n -v, conntrack, tcpdump.",
  },

  { id = "infrastructure", group = "Network equipment", label = "DHCP, DNS and time server",
    summary = "The basic services of a network: hands out addresses, answers names, tells everyone the time.",
    profiles = { "server" },
    packages = { "inet", "dhcp", "inet-dns", "ntp", "ssh" },
    services = { "inetd", "dhcpd", "named", "ntpd", "sshd" },
    config = { ["net.transport"] = "ip" },
    needs = NEEDS_MODEM,
    files = function(probe, opts)
      local wired, wireless = nics(probe)
      local nic = wired[1] or wireless[1]
      local files = {}
      files[NETWORK] = networkFile(hostOf(opts), false, { { name = "eth0", modem = nic, channel = 7101, addresses = { "10.0.0.2/24" }, gateway = "10.0.0.1" } }, { 'dns = { "10.0.0.2" },' })
      files[DHCPD] = [[
return { pools = {
  { name = "lan", iface = "eth0", network = "10.0.0.0/24", range = { "10.0.0.100", "10.0.0.200" }, router = "10.0.0.1", dns = { "10.0.0.2" }, domain = "lan", ntp = { "10.0.0.2" }, lease = 3600 },
} }
]]
      files[NAMED] = [[
-- Zones are made with dnsctl (dnsctl zone create lan ns1.lan 10.0.0.2). Names this server does not own are looked up from the root servers you list, or forwarded.
return { zones = {}, recursion = true, allowRecursion = { "10.0.0.0/24" }, roots = {} }
]]
      return files, {}
    end,
    notes = "Make the zone: dnsctl zone create lan ns1.lan 10.0.0.2, then dnsctl add ... Time: ntp status.",
  },

  -- Services -------------------------------------------------------------------------------------------------------
  { id = "mail-server", group = "Services", label = "Mail server",
    summary = "SMTP and POP3 for your domain with mailboxes, quotas, anti-spam, anti-virus and encrypted connections.",
    profiles = { "server" },
    packages = { "inet", "dhcp", "inet-dns", "mail", "mail-spam", "av", "tls", "ssh", "ntp" },
    services = { "inetd", "dhclient", "maild", "avd", "sshd", "ntpd" },
    config = { ["net.transport"] = "ip" },
    needs = NEEDS_MODEM,
    after = function(opts)
      local ok, mc = pcall(require, "tsr.mail.config")
      if ok then
        local host = hostOf(opts)
        local made = mc.writeTemplate(host .. ".lan", "lan")
        return made and { "wrote " .. mc.STATIC } or {}
      end
      return {}
    end,
    notes = "Next: mailctl domain add <your domain>, mailctl user add <name>, publish the records (mailctl dns), certificate: tlsctl. Then: svc start maild.",
  },

  { id = "web-server", group = "Services", label = "Web server and information pages",
    summary = "Serves pages from /srv/www to browsers in the game (HTTP, optional HTTPS).",
    profiles = { "server" },
    packages = { "inet", "dhcp", "web", "tls", "ssh" },
    services = { "inetd", "dhclient", "httpd", "sshd" },
    config = { ["net.transport"] = "ip" },
    needs = NEEDS_MODEM,
    notes = "Put pages into /srv/www. Look at it from another computer: www <this computer>. Settings: /etc/tsr/inet/httpd.lua.",
  },

  { id = "package-mirror", group = "Services", label = "Package mirror",
    summary = "Fetches packages once and serves them to computers that cannot reach the web.",
    profiles = { "server" },
    packages = { "net", "pkg-mirror", "ssh" },
    services = { "netd", "pkgmirrord" },
    needs = NEEDS_MODEM,
    notes = "Clients use it with: pkg source add lan ... (see help pkg-mirror).",
  },

  -- Devices and automation -----------------------------------------------------------------------------------------
  { id = "iot-node", group = "Devices and automation", label = "Embedded / IoT device",
    summary = "A small sensor or actuator: reads or switches redstone and machines, reports over MQTT. Minimal software.",
    profiles = { "node", "client-lite", "client" },
    packages = { "inet", "dhcp", "mqtt", "hal", "redstone" },
    services = { "inetd", "dhclient" },
    config = { ["net.transport"] = "ip" },
    needs = NEEDS_MODEM,
    notes = "Publish a reading: mqtt pub <broker> home/<room>/<device>/state <value>. Declare redstone things: hal virtual add ...",
  },

  { id = "smart-home", group = "Devices and automation", label = "Smart home hub",
    summary = "Names for lights, doors and sensors in rooms, scenes and a schedule, with an MQTT broker for panels and other computers.",
    profiles = { "server", "client", "client-lite" },
    packages = { "inet", "dhcp", "mqtt", "smarthome", "hal", "rules", "redstone" },
    services = { "inetd", "dhclient", "mqttd", "homed" },
    config = { ["net.transport"] = "ip" },
    needs = NEEDS_MODEM,
    after = function()
      local ok, d = pcall(require, "tsr.home.daemon")
      if ok then
        local vfs = require("tsr.vfs")
        if not vfs.fs.exists(d.CONFIG) then vfs.writeFile(d.CONFIG, d.TEMPLATE) return { "wrote " .. d.CONFIG } end
      end
      return {}
    end,
    notes = "Name your devices in /etc/tsr/home.lua (hal list shows what is attached), add MQTT users: mqttctl user add <name>. Use: home.",
  },

  { id = "industrial", group = "Devices and automation", label = "Industrial control (PLC / SCADA)",
    summary = "Modbus/TCP slave that exposes redstone and machines to a control room, rules for automatic control, power monitoring.",
    profiles = { "server", "node" },
    packages = { "inet", "dhcp", "modbus", "hal", "rules", "redstone", "power-monitor", "firewall", "ssh" },
    services = { "inetd", "dhclient", "rulesd", "sshd" },
    config = { ["net.transport"] = "ip" },
    needs = NEEDS_MODEM,
    after = function()
      local ok, d = pcall(require, "tsr.modbus.daemon")
      if ok then
        local vfs = require("tsr.vfs")
        if not vfs.fs.exists(d.CONFIG) then vfs.writeFile(d.CONFIG, d.TEMPLATE) return { "wrote " .. d.CONFIG } end
      end
      return {}
    end,
    notes = "Describe what the addresses mean in /etc/tsr/modbus.lua (allow list first!), then svc enable modbusd && svc start modbusd. Read it from the control room: modbus read <host> coils 0 8.",
  },

  { id = "kiosk", group = "Devices and automation", label = "Kiosk / information display",
    summary = "A screen that shows one thing for ever: a page from the in-game web, refreshed, or any program; Ctrl+T does not stop it.",
    profiles = { "tv", "client", "client-lite", "server" },
    packages = { "inet", "dhcp", "web", "tv", "display" },
    services = { "inetd", "dhclient", "kioskd" },
    config = { ["net.transport"] = "ip" },
    needs = function(probe) if (probe.counts and probe.counts.monitors or 0) == 0 and not probe.computer.advanced then return "needs a screen" end end,
    after = function(opts)
      local ok, k = pcall(require, "tsr.tv.kiosk")
      if ok then
        local vfs = require("tsr.vfs")
        if not vfs.fs.exists(k.CFG_PATH) then
          vfs.writeTable(k.CFG_PATH, { command = "www --board " .. ((opts and opts.url) or "http://info.lan/") .. " --every 30", delay = 2 })
          return { "wrote " .. k.CFG_PATH .. " (change the address: kiosk set www --board <url>)" }
        end
      end
      return {}
    end,
    notes = "Set what to show: kiosk set www --board http://<server>/ --monitor <name>. To get out: svc stop kioskd from another computer.",
  },
}

---------------------------------------------------------------------------------------------------------------------

function M.get(id)
  for _, u in ipairs(M.LIST) do if u.id == id then return u end end
end

local function resolve(v, probe)
  if type(v) == "function" then return v(probe) end
  return v
end

local function suits(u, profile)
  if not u.profiles or not profile then return true end
  for _, p in ipairs(u.profiles) do if p == profile then return true end end
  return false
end

--- Use cases for the wizard. profile: the chosen profile (use cases made for other kinds of computer are blocked with a reason).
function M.available(probe, profile)
  local out = {}
  for _, u in ipairs(M.LIST) do
    local e = { id = u.id, group = u.group, label = u.label, summary = u.summary }
    if not suits(u, profile) then e.blocked = "not for a computer set up as " .. tostring(profile) end
    if not e.blocked and u.needs then e.blocked = u.needs(probe) end
    out[#out + 1] = e
  end
  return out
end

--- What a use case would install and enable. opts: hostname.
function M.plan(id, probe, opts)
  local u = M.get(id)
  if not u then return nil, "no such use case: " .. tostring(id) end
  return {
    id = u.id, label = u.label,
    packages = resolve(u.packages, probe) or {}, services = resolve(u.services, probe) or {}, config = u.config or {}, notes = u.notes,
  }
end

--- Apply a use case after its packages are installed. env: vfs, config, svc (each optional; default the real modules), hostname, force.
--- Returns { written = {paths}, kept = {paths that existed}, enabled = {services}, notes = {text}, problems = {text} }.
function M.apply(id, probe, env)
  env = env or {}
  local u = M.get(id)
  if not u then return nil, "no such use case: " .. tostring(id) end
  local vfs = env.vfs or require("tsr.vfs")
  local result = { written = {}, kept = {}, enabled = {}, notes = {}, problems = {} }
  local gen = { secret = env.secret or secret }
  if u.files then
    local files, notes = u.files(probe, { hostname = env.hostname }, gen)
    if not files then
      result.problems[#result.problems + 1] = tostring(notes)
    else
      local paths = {}
      for p in pairs(files) do paths[#paths + 1] = p end
      table.sort(paths)
      for _, path in ipairs(paths) do
        if vfs.fs.exists(path) and not env.force then
          result.kept[#result.kept + 1] = path
        else
          vfs.mkdirp(path:match("^(.*)/[^/]*$") or "/")
          local ok, err = vfs.writeFile(path, files[path])
          if ok then result.written[#result.written + 1] = path else result.problems[#result.problems + 1] = path .. ": " .. tostring(err) end
        end
      end
      for _, n in ipairs(notes or {}) do result.notes[#result.notes + 1] = n end
    end
  end
  if u.after then
    local ok, more = pcall(u.after, { hostname = env.hostname })
    if ok then for _, line in ipairs(more or {}) do result.written[#result.written + 1] = line end
    else result.problems[#result.problems + 1] = tostring(more) end
  end
  local config = env.config or require("tsr.config")
  for k, v in pairs(u.config or {}) do config.set(k, v, "system") end
  if next(u.config or {}) then config.save("system") end
  local svcOk, svc = pcall(function() return env.svc or require("tsr.svc") end)
  for _, name in ipairs(resolve(u.services, probe) or {}) do
    if svcOk and svc and svc.enable then
      local ok, err = svc.enable(name)
      if ok then result.enabled[#result.enabled + 1] = name
      else result.problems[#result.problems + 1] = ("service %s: %s"):format(name, tostring(err)) end
    end
  end
  if u.notes then result.notes[#result.notes + 1] = u.notes end
  vfs.writeJSON("/etc/tsr/usecase.json", { id = id, label = u.label, time = os.epoch and os.epoch("utc") or 0 })
  return result
end

M.secret = secret

return M
