-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The network configuration file /etc/tsr/inet/network.lua and how it is applied to a running stack:
--
--   return {
--     hostname = "gw1",
--     forwarding = false,                         -- route packets between interfaces (a router)
--     interfaces = {
--       eth0 = { modem = "back", channel = 7101, addresses = { "10.0.0.2/24" }, gateway = "10.0.0.1", mtu = 1500 },
--       wlan0 = { modem = "top", channel = 7102, dhcp = true, key = "link passphrase" },
--       ["eth0.20"] = { vlan = 20, parent = "eth0", addresses = { "10.20.0.1/24" } },
--     },
--     routes = { { "10.9.0.0/16", "10.0.0.254", metric = 5 } },
--     hosts = { alpha = "10.0.0.7" },
--     dns = { "10.0.0.53" }, search = { "lan" },
--   }
--
-- With no file (or no `interfaces`) every modem found gets an interface and asks for an address by DHCP when the dhcp package is installed.
local B = require("tsr.inet.bytes")
local vfs = require("tsr.vfs")

local M = {}

M.PATH = "/etc/tsr/inet/network.lua"

function M.load(path)
  path = path or M.PATH
  if not vfs.fs.exists(path) then return {} end
  local text = vfs.readFile(path)
  local chunk, err = load(text or "", "=network.lua", "t", {})
  if not chunk then return nil, "network.lua: " .. tostring(err) end
  local ok, cfg = pcall(chunk)
  if not ok or type(cfg) ~= "table" then return nil, "network.lua: " .. tostring(cfg) end
  return cfg
end

local function quote(v)
  if type(v) == "string" then return ("%q"):format(v):gsub("\n", "n") end
  return tostring(v)
end

local function dump(v, indent)
  indent = indent or ""
  if type(v) ~= "table" then return quote(v) end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    if type(a) == type(b) then return a < b end
    return type(a) == "number"
  end)
  local out = {}
  local isList = #v == #keys
  for _, k in ipairs(keys) do
    local val = dump(v[k], indent .. "  ")
    if isList then out[#out + 1] = indent .. "  " .. val
    elseif type(k) == "string" and k:match("^[%a_][%w_]*$") then out[#out + 1] = indent .. "  " .. k .. " = " .. val
    else out[#out + 1] = indent .. "  [" .. quote(k) .. "] = " .. val end
  end
  return "{\n" .. table.concat(out, ",\n") .. "\n" .. indent .. "}"
end

M.dump = dump

function M.save(cfg, path)
  path = path or M.PATH
  return vfs.writeFile(path, "-- SPDX-License-Identifier: AGPL-3.0-or-later\n-- Network configuration (written by `ip save`; edit freely).\nreturn " .. dump(cfg) .. "\n")
end

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t or {}) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

--- Modems attached right now: list of { name, wireless }.
function M.detectModems()
  local out = {}
  if not peripheral then return out end
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      local m = peripheral.wrap(name)
      out[#out + 1] = { name = name, wireless = m.isWireless and m.isWireless() or false }
    end
  end
  return out
end

--- What to do when there is no configuration: one interface per modem, addresses by DHCP.
function M.automatic()
  local cfg = { interfaces = {}, auto = true }
  local eth, wlan = 0, 0
  for _, m in ipairs(M.detectModems()) do
    local name
    if m.wireless then name = "wlan" .. wlan wlan = wlan + 1 else name = "eth" .. eth eth = eth + 1 end
    cfg.interfaces[name] = { modem = m.name, dhcp = true }
  end
  return cfg
end

--- Apply a configuration to a stack. Returns a list of problems (strings); the rest is applied as far as possible.
function M.apply(stack, cfg)
  local link = require("tsr.inet.link")
  local problems = {}
  if cfg.hostname then stack.hostname = cfg.hostname end
  if cfg.forwarding ~= nil then stack.forwarding = cfg.forwarding and true or false end
  if cfg.ttl then stack.sysctl.defaultTtl = cfg.ttl end
  stack.dhcpWanted = stack.dhcpWanted or {}
  -- real interfaces first, VLAN subinterfaces after their parents
  local names = sortedKeys(cfg.interfaces)
  local vlans = {}
  for _, name in ipairs(names) do
    local spec = cfg.interfaces[name]
    if spec.vlan then vlans[#vlans + 1] = name
    elseif spec.wifi then
      local okWifi, wifi = pcall(require, "tsr.inet.wifi")
      if not okWifi then problems[#problems + 1] = name .. ": the wifi package is not installed"
      elseif not stack.ifaces[name] then
        local sta, err = wifi.attachStation(stack, name, spec)
        if not sta then problems[#problems + 1] = name .. ": " .. tostring(err) end
      end
    elseif spec.modem then
      if not stack.ifaces[name] then
        local iface, err = link.attachModem(stack, { name = name, peripheral = spec.modem, channel = spec.channel, mtu = spec.mtu, key = spec.key, mac = spec.mac and B.mac(spec.mac) })
        if not iface then problems[#problems + 1] = name .. ": " .. tostring(err) end
      end
    elseif not stack.ifaces[name] then
      problems[#problems + 1] = name .. ": no modem named"
    end
  end
  for _, name in ipairs(vlans) do
    local spec = cfg.interfaces[name]
    if stack.ifaces[spec.parent] and not stack.ifaces[name] then stack:addVlan(spec.parent, spec.vlan, name)
    elseif not stack.ifaces[spec.parent] then problems[#problems + 1] = name .. ": parent " .. tostring(spec.parent) .. " is missing" end
  end
  for _, name in ipairs(names) do
    local spec = cfg.interfaces[name]
    local iface = stack.ifaces[name]
    if iface then
      if spec.mtu then iface.mtu = spec.mtu end
      if spec.proxyArp then iface.proxyArp = true end
      if spec.up == false then stack:setUp(name, false) end
      for _, cidr in ipairs(spec.addresses or {}) do
        local addr, plen = tostring(cidr):match("^([%d%.]+)/(%d+)$")
        if addr and B.ip(addr) then stack:setAddress(name, addr, tonumber(plen))
        else problems[#problems + 1] = name .. ": bad address " .. tostring(cidr) end
      end
      if spec.gateway then
        local ok, err = stack:addRoute("default", spec.gateway, { iface = name })
        if not ok then problems[#problems + 1] = name .. ": gateway " .. tostring(spec.gateway) .. ": " .. tostring(err) end
      end
      if spec.dhcp then stack.dhcpWanted[name] = true end
    end
  end
  for _, r in ipairs(cfg.routes or {}) do
    local ok, err = stack:addRoute(r[1], r[2], { metric = r.metric, iface = r.iface })
    if not ok then problems[#problems + 1] = "route " .. tostring(r[1]) .. ": " .. tostring(err) end
  end
  for name, ip in pairs(cfg.hosts or {}) do stack:addHost(name, ip) end
  stack.dnsServers = {}
  for _, s in ipairs(cfg.dns or {}) do stack.dnsServers[#stack.dnsServers + 1] = B.ip(s) end
  stack.searchDomains = cfg.search or {}
  return problems
end

--- Describe the running stack as a configuration table (what `ip save` writes).
function M.snapshot(stack)
  local cfg = { hostname = stack.hostname, forwarding = stack.forwarding or nil, interfaces = {}, routes = {}, hosts = {} }
  for _, iface in ipairs(stack.ifaceList) do
    if iface.kind ~= "loopback" then
      local spec = {}
      if iface.driver then
        spec.modem, spec.channel = iface.driver.name, iface.driver.channel
        if iface.driver.keyText then spec.key = iface.driver.keyText end
      end
      if iface.parent then spec.vlan, spec.parent = iface.vlan, iface.parent end
      if stack.dhcpWanted and stack.dhcpWanted[iface.name] then spec.dhcp = true end
      if #iface.addrs > 0 and not spec.dhcp then
        spec.addresses = {}
        for _, a in ipairs(iface.addrs) do spec.addresses[#spec.addresses + 1] = B.ipStr(a.ip) .. "/" .. a.plen end
      end
      if iface.mtu ~= 1500 and not iface.parent then spec.mtu = iface.mtu end
      if iface.proxyArp then spec.proxyArp = true end
      if not iface.up then spec.up = false end
      cfg.interfaces[iface.name] = spec
    end
  end
  for _, r in ipairs(stack.routes) do
    if r.proto == "static" then
      cfg.routes[#cfg.routes + 1] = { B.cidrStr(r.net, r.plen), r.gateway and B.ipStr(r.gateway) or nil, iface = r.gateway == nil and r.iface or nil, metric = r.metric ~= 1 and r.metric or nil }
    end
  end
  for name, ip in pairs(stack.hosts) do cfg.hosts[name] = B.ipStr(ip) end
  if stack.dnsServers and #stack.dnsServers > 0 then
    cfg.dns = {}
    for _, s in ipairs(stack.dnsServers) do cfg.dns[#cfg.dns + 1] = B.ipStr(s) end
  end
  if stack.searchDomains and #stack.searchDomains > 0 then cfg.search = stack.searchDomains end
  return cfg
end

return M
