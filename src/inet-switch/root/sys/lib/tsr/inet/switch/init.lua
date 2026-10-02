-- SPDX-License-Identifier: AGPL-3.0-or-later
-- A managed Ethernet switch: it joins the interfaces of this computer (each connected to its own cable or radio channel) into one network.
--   * learns which MAC address lives behind which port and forwards frames only there (floods what it does not know);
--   * VLANs (IEEE 802.1Q): access ports belong to one VLAN, trunk ports carry tagged frames for several;
--   * Spanning Tree (IEEE 802.1D) blocks redundant links so cables can form loops safely (see stp.lua);
--   * port security (limit or fix the MAC addresses on a port), broadcast storm control, port mirroring, LLDP neighbour discovery;
--   * switch virtual interfaces (SVI): an IP interface of the switch inside a VLAN, for management and routing between VLANs.
-- It plugs into the IP stack through the interfaces' rxhook, so the same computer can also run routing, DHCP and so on.
local B = require("tsr.inet.bytes")
local W = require("tsr.inet.wire")
local Stp = require("tsr.inet.switch.stp")

local M = {}
local Switch = {}
Switch.__index = Switch
M.Switch = Switch

M.LLDP_MAC = "\1\128\194\0\0\14"
M.ETH_LLDP = 0x88CC

local function now(self) return self.stack.clock() end

local function isMulticastMac(mac) return mac:byte(1) % 2 == 1 end

--- cfg: name, aging (300 s), maxMacs (2048), ports = { name = { mode = "access"|"trunk", vlan, native, allowed = {..}, cost, secure = {...}, storm = pps } },
--- vlans = { [id] = name }, stp = { enabled, priority, ... }, svis = { [vlan] = "10.0.0.1/24" }, mirror = { dest, sources = {..} }, lldp = true.
function M.new(stack, cfg)
  cfg = cfg or {}
  local self = setmetatable({
    stack = stack, name = cfg.name or stack.hostname, aging = cfg.aging or 300, maxMacs = cfg.maxMacs or 2048, ports = {}, portList = {}, fdb = {}, vlans = { [1] = "default" },
    svis = {}, neighbours = {}, stats = { flooded = 0, forwarded = 0, filtered = 0, dropped = 0, learned = 0, moves = 0 }, lldp = cfg.lldp ~= false,
  }, Switch)
  for id, name in pairs(cfg.vlans or {}) do self.vlans[id] = name end
  local names = {}
  for name in pairs(cfg.ports or {}) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do self:addPort(name, cfg.ports[name]) end
  -- the bridge address is the lowest port address, like real switches
  local lowest
  for _, p in ipairs(self.portList) do if not lowest or p.iface.mac < lowest then lowest = p.iface.mac end end
  self.mac = cfg.mac and B.mac(cfg.mac) or lowest or B.makeMac(os.getComputerID and os.getComputerID() or 1, 250, 0)
  if cfg.stp ~= false and #self.portList > 1 then
    self.stp = Stp.new(self, cfg.stp or {})
    self.stp.enabled = not (cfg.stp and cfg.stp.enabled == false)
  end
  for vlan, cidr in pairs(cfg.svis or {}) do self:addSvi(vlan, cidr) end
  if cfg.mirror then self:setMirror(cfg.mirror.dest, cfg.mirror.sources, cfg.mirror.direction) end
  return self
end

---------------------------------------------------------------------------------------------------------------------
-- Ports
---------------------------------------------------------------------------------------------------------------------

--- A port that is not a stack interface (a Wi-Fi client, a tunnel): spec.send(frame) puts a frame on it; feed frames from it with switch:ingress(port, frame).
function Switch:addVirtualPort(name, spec)
  spec = spec or {}
  local port = {
    name = name, iface = { name = name, up = true, mac = spec.mac or string.rep("\0", 6), stats = {} }, virtual = true, send = spec.send, mode = spec.mode or "access",
    vlan = spec.vlan or 1, native = spec.native or 1, cfg = spec, counters = { rx = 0, tx = 0, dropped = 0, flooded = 0, violations = 0 }, isolated = spec.isolated, up = true,
  }
  self.ports[name] = port
  self.portList[#self.portList + 1] = port
  table.sort(self.portList, function(a, b) return a.name < b.name end)
  return port
end

function Switch:removePort(name)
  local port = self.ports[name]
  if not port then return false end
  self:flushPort(name)
  self.ports[name] = nil
  for i, p in ipairs(self.portList) do if p == port then table.remove(self.portList, i) break end end
  return true
end

local function sendOnPort(self, port, frame)
  if port.virtual then
    if port.send then port.send(frame) end
    return true
  end
  return self.stack:txRaw(port.iface, frame)
end

function Switch:addPort(name, pcfg)
  pcfg = pcfg or {}
  local iface = self.stack.ifaces[name]
  assert(iface, "no interface " .. name)
  local port = {
    name = name, iface = iface, mode = pcfg.mode or "access", vlan = pcfg.vlan or 1, native = pcfg.native or 1, allowed = nil, cfg = pcfg,
    counters = { rx = 0, tx = 0, dropped = 0, flooded = 0, violations = 0 }, secure = pcfg.secure, storm = pcfg.storm,
  }
  if pcfg.allowed then
    port.allowed = {}
    for _, v in ipairs(pcfg.allowed) do port.allowed[v] = true end
  end
  port.up = iface.up
  iface.switchPort = port
  iface.rxhook = function(frame) self:ingress(port, frame) return true end
  self.ports[name] = port
  self.portList[#self.portList + 1] = port
  table.sort(self.portList, function(a, b) return a.name < b.name end)
  return port
end

local function allowedOn(port, vlan)
  if port.mode == "access" then return port.vlan == vlan end
  return port.allowed == nil or port.allowed[vlan] == true or vlan == port.native
end
M.allowedOn = allowedOn

--- Reconfigure a port at run time: mode, vlan, native, allowed (list or nil), cost, secure, storm.
function Switch:configurePort(name, changes)
  local port = self.ports[name]
  if not port then return nil, "no such port " .. tostring(name) end
  if changes.mode then
    if changes.mode ~= "access" and changes.mode ~= "trunk" then return nil, "mode is access or trunk" end
    port.mode = changes.mode
  end
  if changes.vlan then port.vlan = changes.vlan end
  if changes.native then port.native = changes.native end
  if changes.allowed ~= nil then
    if changes.allowed == false then port.allowed = nil else
      port.allowed = {}
      for _, v in ipairs(changes.allowed) do port.allowed[v] = true end
    end
  end
  if changes.secure ~= nil then port.secure = changes.secure or nil end
  if changes.storm ~= nil then port.storm = changes.storm or nil end
  if changes.cost and port.stp then port.stp.cost = changes.cost end
  if changes.vlan or changes.mode or changes.native then self:flushPort(name) end
  return port
end

function Switch:setPortEnabled(name, on)
  local port = self.ports[name]
  if not port then return false end
  port.errdisabled = not on
  if on then port.violationCount = 0 end
  if self.stp then self.stp:recompute() end
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- Address table
---------------------------------------------------------------------------------------------------------------------

function Switch:fdbFor(vlan)
  local t = self.fdb[vlan]
  if not t then t = {} self.fdb[vlan] = t end
  return t
end

local function fresh(self, e)
  if e.static or e.cpu then return true end
  local aging = self.aging
  if self.stp and self.stp.tcActiveUntil and now(self) < self.stp.tcActiveUntil then aging = math.min(aging, self.stp.forwardDelay) end
  return now(self) - e.at <= aging
end

function Switch:lookup(vlan, mac)
  local e = self.fdb[vlan] and self.fdb[vlan][mac]
  if e and fresh(self, e) then return e end
  if e then self.fdb[vlan][mac] = nil end
  return nil
end

function Switch:countOnPort(name)
  local n = 0
  for _, t in pairs(self.fdb) do for _, e in pairs(t) do if e.port == name and not e.static then n = n + 1 end end end
  return n
end

function Switch:size()
  local n = 0
  for _, t in pairs(self.fdb) do for _ in pairs(t) do n = n + 1 end end
  return n
end

--- Remove learned addresses (all, or those of one port).
function Switch:flushPort(name)
  for _, t in pairs(self.fdb) do
    for mac, e in pairs(t) do if not e.static and not e.cpu and (name == nil or e.port == name) then t[mac] = nil end end
  end
end

function Switch:addStatic(vlan, mac, portName)
  self:fdbFor(vlan)[mac] = { port = portName, static = true, at = now(self) }
end

--- Port security check; returns true when the frame may pass.
local function secureCheck(self, port, vlan, src)
  local sec = port.secure
  if not sec then return true end
  local known = self:fdb_known(port, vlan, src)
  if known then return true end
  local allowedMac = false
  if sec.static and #sec.static > 0 then
    for _, m in ipairs(sec.static) do if B.mac(m) == src then allowedMac = true end end
    if not allowedMac then
      return false
    end
    return true
  end
  if self:countOnPort(port.name) < (sec.max or 1) then return true end
  return false
end

function Switch:fdb_known(port, vlan, src)
  local e = self.fdb[vlan] and self.fdb[vlan][src]
  return e and e.port == port.name and fresh(self, e)
end

local function violation(self, port, src)
  port.counters.violations = port.counters.violations + 1
  local mode = port.secure and port.secure.violation or "restrict"
  if mode == "shutdown" then
    port.errdisabled = true
    if self.stack.logger then self.stack.logger(("port %s shut down: unexpected address %s"):format(port.name, B.macStr(src))) end
    if self.stp then self.stp:recompute() end
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Forwarding
---------------------------------------------------------------------------------------------------------------------

local function stpState(self, port)
  if self.stp and self.stp.enabled and port.stp then return port.stp.state end
  return "forwarding"
end

--- Send the frame on `port` in the right form for its mode. `f` is the decoded frame (vlan field = the frame's own tag, if any).
function Switch:egress(port, f, vlan, original, taggedOriginal, from)
  if port.errdisabled or not port.up or not port.iface.up then return false end
  if from and from.isolated and port.isolated then return false end
  if stpState(self, port) ~= "forwarding" then return false end
  if not allowedOn(port, vlan) then return false end
  if self.mirror and self.mirror.dest == port.name then return false end
  local tagged = port.mode == "trunk" and vlan ~= port.native
  local out
  if tagged == taggedOriginal then out = original
  else out = W.ethEncode({ dst = f.dst, src = f.src, type = f.type, payload = f.payload, vlan = tagged and vlan or nil, pcp = f.pcp }) end
  port.counters.tx = port.counters.tx + 1
  if self.mirror and self.mirror.sources[port.name] and self.mirror.direction ~= "rx" then sendOnPort(self, self.ports[self.mirror.dest], out) end
  sendOnPort(self, port, out)
  return true
end

local function deliverToSvi(self, vlan, f)
  local svi = self.svis[vlan]
  if not svi or not svi.up then return end
  local frame = W.ethEncode({ dst = f.dst, src = f.src, type = f.type, payload = f.payload })
  self.stack:input(svi, frame)
end

function Switch:flood(vlan, f, original, taggedOriginal, from)
  self.stats.flooded = self.stats.flooded + 1
  for _, p in ipairs(self.portList) do
    if p ~= from then
      if self:egress(p, f, vlan, original, taggedOriginal, from) then p.counters.flooded = p.counters.flooded + 1 end
    end
  end
end

local function stormOk(self, port)
  local s = port.storm
  if not s then return true end
  local t = now(self)
  port.stormTokens = math.min(s, (port.stormTokens or s) + (t - (port.stormAt or t)) * s)
  port.stormAt = t
  if port.stormTokens < 1 then return false end
  port.stormTokens = port.stormTokens - 1
  return true
end

--- A frame arrived on a port.
function Switch:ingress(port, frame)
  if port.errdisabled or not port.up or not port.iface.up then return end
  port.counters.rx = port.counters.rx + 1
  local f = W.ethDecode(frame)
  if not f then return end
  -- control frames that a bridge consumes and never forwards
  if f.dst == Stp.MAC then
    if self.stp and self.stp.enabled and (f.type == Stp.ETH_LEN_TYPE or f.type == Stp.TCN_LEN) then self.stp:receive(port, f.payload) end
    return
  end
  if f.dst == M.LLDP_MAC then return self:lldpReceive(port, f) end
  if f.dst:sub(1, 5) == "\1\128\194\0\0" then return end
  local st = stpState(self, port)
  if st == "blocking" or st == "listening" or st == "disabled" then self.stats.dropped = self.stats.dropped + 1 return end
  -- classify
  local vlan
  local taggedOriginal = f.vlan ~= nil
  if port.mode == "access" then
    if f.vlan and f.vlan ~= 0 then self.stats.dropped = self.stats.dropped + 1 return end
    vlan = port.vlan
    taggedOriginal = false
  else
    if f.vlan and f.vlan ~= 0 then
      if not allowedOn(port, f.vlan) then self.stats.dropped = self.stats.dropped + 1 return end
      vlan = f.vlan
    else
      vlan = port.native
    end
  end
  -- security and learning
  local src = f.src
  if not isMulticastMac(src) then
    if not secureCheck(self, port, vlan, src) then
      violation(self, port, src)
      return
    end
    local table_ = self:fdbFor(vlan)
    local e = table_[src]
    if e and e.static then
      if e.port ~= port.name then self.stats.dropped = self.stats.dropped + 1 return end
    elseif e and e.cpu then
      return                                                   -- somebody else claims our own address
    else
      if not e then
        if self:size() < self.maxMacs then
          table_[src] = { port = port.name, at = now(self) }
          self.stats.learned = self.stats.learned + 1
        end
      else
        if e.port ~= port.name then self.stats.moves = self.stats.moves + 1 end
        e.port, e.at = port.name, now(self)
      end
    end
  end
  if st == "learning" then return end
  if self.mirror and self.mirror.sources[port.name] and self.mirror.direction ~= "tx" and self.mirror.dest ~= port.name then
    sendOnPort(self, self.ports[self.mirror.dest], frame)
  end
  -- forward
  local dst = f.dst
  local broadcastLike = isMulticastMac(dst)
  if broadcastLike then
    if not stormOk(self, port) then self.stats.dropped = self.stats.dropped + 1 return end
    deliverToSvi(self, vlan, f)
    return self:flood(vlan, f, frame, taggedOriginal, port)
  end
  local e = self:lookup(vlan, dst)
  if not e then
    if not stormOk(self, port) then self.stats.dropped = self.stats.dropped + 1 return end
    return self:flood(vlan, f, frame, taggedOriginal, port)
  end
  if e.cpu then return deliverToSvi(self, vlan, f) end
  if e.port == port.name then self.stats.filtered = self.stats.filtered + 1 return end
  local out = self.ports[e.port]
  if out then
    self.stats.forwarded = self.stats.forwarded + 1
    self:egress(out, f, vlan, frame, taggedOriginal, port)
  end
end

--- A frame the switch itself sends into VLAN `vlan` (from an SVI).
function Switch:cpuEgress(vlan, frame)
  local f = W.ethDecode(frame)
  if not f then return end
  if isMulticastMac(f.dst) then return self:flood(vlan, f, frame, false, nil) end
  local e = self:lookup(vlan, f.dst)
  if e and e.port and self.ports[e.port] then return self:egress(self.ports[e.port], f, vlan, frame, false) end
  if e and e.cpu then return deliverToSvi(self, vlan, f) end
  self:flood(vlan, f, frame, false, nil)
end

--- Raw frame from this switch on one port (BPDU, LLDP).
function Switch:sendRaw(port, dst, ethType, payload)
  sendOnPort(self, port, W.ethEncode({ dst = dst, src = port.iface.mac, type = ethType, payload = payload }))
end

function Switch:topologyChange(port)
  if self.stp then self.stp:topologyDetected() else self:flushPort(nil) end
end

---------------------------------------------------------------------------------------------------------------------
-- SVIs (IP interfaces of the switch)
---------------------------------------------------------------------------------------------------------------------

function Switch:addSvi(vlan, cidr)
  local name = "vlan" .. vlan
  local iface = self.stack.ifaces[name]
  if not iface then
    iface = self.stack:addInterface({ name = name, kind = "virtual", mac = self.mac, send = function(frame) self:cpuEgress(vlan, frame) end })
  end
  self.svis[vlan] = iface
  self.vlans[vlan] = self.vlans[vlan] or ("vlan" .. vlan)
  self:fdbFor(vlan)[iface.mac] = { cpu = true, at = now(self) }
  if cidr then
    local addr, plen = tostring(cidr):match("^([%d%.]+)/(%d+)$")
    if addr then self.stack:setAddress(name, addr, tonumber(plen)) end
  end
  return iface
end

---------------------------------------------------------------------------------------------------------------------
-- Mirroring
---------------------------------------------------------------------------------------------------------------------

function Switch:setMirror(dest, sources, direction)
  if not dest then self.mirror = nil return true end
  if not self.ports[dest] then return nil, "no such port " .. tostring(dest) end
  local set = {}
  for _, s in ipairs(sources or {}) do set[s] = true end
  self.mirror = { dest = dest, sources = set, direction = direction or "both" }
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- LLDP (neighbour discovery, IEEE 802.1AB: chassis, port, time to live, system name)
---------------------------------------------------------------------------------------------------------------------

local function tlv(t, value) return B.u16(t * 512 + #value) .. value end

function Switch:lldpPayload(port)
  return tlv(1, "\4" .. self.mac) .. tlv(2, "\5" .. port.name) .. tlv(3, B.u16(120)) .. tlv(5, self.name) .. "\0\0"
end

function Switch:lldpReceive(port, f)
  local p, pos = f.payload, 1
  local info = { expires = now(self) + 120 }
  while pos + 1 <= #p do
    local head = B.rd16(p, pos)
    local t, len = math.floor(head / 512), head % 512
    local v = p:sub(pos + 2, pos + 1 + len)
    if t == 0 then break
    elseif t == 1 then info.chassis = v:sub(2)
    elseif t == 2 then info.port = v:sub(2)
    elseif t == 3 then info.expires = now(self) + B.rd16(v, 1)
    elseif t == 5 then info.name = v end
    pos = pos + 2 + len
  end
  self.neighbours[port.name] = info
end

function Switch:neighbourList()
  local out = {}
  for portName, n in pairs(self.neighbours) do
    if n.expires > now(self) then out[#out + 1] = { port = portName, name = n.name, remotePort = n.port, chassis = n.chassis } end
  end
  table.sort(out, function(a, b) return a.port < b.port end)
  return out
end

---------------------------------------------------------------------------------------------------------------------
-- Running
---------------------------------------------------------------------------------------------------------------------

function Switch:start()
  if self.started then return end
  self.started = true
  if self.stp and self.stp.enabled then self.stp:start() end
  local function maintenance()
    if not self.started then return end
    -- keep port state in step with the interfaces (cables pulled, modems gone)
    local changed = false
    for _, p in ipairs(self.portList) do
      local up = p.iface.up
      if p.up ~= up then p.up = up changed = true if not up then self:flushPort(p.name) end end
    end
    if changed and self.stp then self.stp:recompute() end
    -- age out
    local t = now(self)
    for _, tbl in pairs(self.fdb) do
      for mac, e in pairs(tbl) do if not e.static and not e.cpu and t - e.at > self.aging then tbl[mac] = nil end end
    end
    if self.lldp and t - (self.lastLldp or -999) >= 30 then
      self.lastLldp = t
      for _, p in ipairs(self.portList) do if p.up and not p.errdisabled then self:sendRaw(p, M.LLDP_MAC, M.ETH_LLDP, self:lldpPayload(p)) end end
    end
    self.stack:after(1, maintenance)
  end
  maintenance()
end

function Switch:stop()
  self.started = false
  if self.stp then self.stp:stop() end
  for _, p in ipairs(self.portList) do p.iface.rxhook = nil p.iface.switchPort = nil end
end

--- Lines of the MAC address table.
function Switch:macTable()
  local rows = {}
  for vlan, t in pairs(self.fdb) do
    for mac, e in pairs(t) do
      if fresh(self, e) then rows[#rows + 1] = { vlan = vlan, mac = mac, port = e.cpu and "CPU" or e.port, static = e.static, age = math.floor(now(self) - e.at) } end
    end
  end
  table.sort(rows, function(a, b) if a.vlan ~= b.vlan then return a.vlan < b.vlan end return a.mac < b.mac end)
  return rows
end

return M
