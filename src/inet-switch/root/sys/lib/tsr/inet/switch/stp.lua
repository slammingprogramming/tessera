-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The Spanning Tree Protocol (IEEE 802.1D): bridges elect a root, every other bridge picks the cheapest path to it (its root port), each segment
-- picks one designated bridge, and every other port is blocked, so that redundant cables never become a loop. Frames: configuration BPDUs to the
-- multicast address 01:80:C2:00:00:00. Ports pass through listening and learning before they forward, so a loop cannot form while the tree settles.
--
-- Bridge ID  = priority (2 bytes) + MAC (6 bytes), compared as a string: the lowest wins.
-- Port  ID   = priority (1 byte, 128) + port number (1 byte).
-- Priority vector of a BPDU = (root ID, cost to root, sender bridge ID, sender port ID): the smaller vector is better.
local B = require("tsr.inet.bytes")

local M = {}
local Stp = {}
Stp.__index = Stp

M.MAC = "\1\128\194\0\0\0"
M.ETH_LEN_TYPE = 38           -- 3 bytes LLC + 35 bytes BPDU: the 802.3 length field of the frame
M.TCN_LEN = 7                 -- topology change notification: LLC + protocol 0, version 0, type 0x80
M.FLAG_TC, M.FLAG_TCA = 1, 128

local function encodeBpdu(b)
  local ageUnits = math.floor(b.messageAge * 256)
  return "\66\66\3" .. "\0\0" .. "\0" .. "\0" .. string.char(b.flags or 0) .. b.rootId .. B.u32(b.cost) .. b.bridgeId .. b.portId
    .. B.u16(ageUnits) .. B.u16(b.maxAge * 256) .. B.u16(b.hello * 256) .. B.u16(b.forwardDelay * 256)
end

local function decodeBpdu(p)
  if #p < 38 or p:sub(1, 3) ~= "\66\66\3" or p:byte(7) ~= 0 then return nil end
  return { flags = p:byte(8), rootId = p:sub(9, 16), cost = B.rd32(p, 17), bridgeId = p:sub(21, 28), portId = p:sub(29, 30),
    messageAge = B.rd16(p, 31) / 256, maxAge = B.rd16(p, 33) / 256, hello = B.rd16(p, 35) / 256, forwardDelay = B.rd16(p, 37) / 256 }
end

M.encode, M.decode = encodeBpdu, decodeBpdu

--- Is vector a better (smaller) than b?
local function better(a, b)
  if a.root ~= b.root then return a.root < b.root end
  if a.cost ~= b.cost then return a.cost < b.cost end
  if a.bridge ~= b.bridge then return a.bridge < b.bridge end
  return a.port < b.port
end
M.better = better

--- sw: the switch (needs sw.stack, sw.ports (name -> port), sw.mac, sw:sendRaw(port, dst, ethType, payload), sw:topologyChange()).
--- cfg: priority (32768), hello (2), maxAge (20), forwardDelay (15), cost (19 per port).
function M.new(sw, cfg)
  cfg = cfg or {}
  local self = setmetatable({
    sw = sw, priority = cfg.priority or 32768, hello = cfg.hello or 2, maxAge = cfg.maxAge or 20, forwardDelay = cfg.forwardDelay or 15, defaultCost = cfg.cost or 19,
    enabled = true, ports = {},
  }, Stp)
  self.bridgeId = B.u16(self.priority) .. sw.mac
  self.root, self.rootCost, self.rootPort = self.bridgeId, 0, nil
  local n = 0
  local names = {}
  for name in pairs(sw.ports) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    n = n + 1
    local port = sw.ports[name]
    port.stp = { id = string.char(128, n), cost = (port.cfg and port.cfg.cost) or self.defaultCost, best = nil, role = "designated", state = "blocking" }
    self.ports[name] = port
  end
  return self
end

local function now(self) return self.sw.stack.clock() end

function Stp:setState(port, state)
  local s = port.stp
  if s.state == state then return end
  local wasForwarding = s.state == "forwarding"
  s.state = state
  s.timer = nil
  s.stateSince = now(self)
  if wasForwarding or state == "forwarding" then self.sw:topologyChange(port) end
end

--- Move a port toward forwarding: listening -> learning -> forwarding, each after forwardDelay.
function Stp:advance(port)
  local s = port.stp
  if s.state == "blocking" then
    self:setState(port, "listening")
    local token = {}
    s.timer = token
    self.sw.stack:after(self.forwardDelay, function()
      if s.timer ~= token or s.state ~= "listening" then return end
      self:setState(port, "learning")
      local token2 = {}
      s.timer = token2
      self.sw.stack:after(self.forwardDelay, function()
        if s.timer ~= token2 or s.state ~= "learning" then return end
        self:setState(port, "forwarding")
      end)
    end)
  end
end

--- Work out root, root port and the role of every port from the stored BPDUs.
function Stp:recompute()
  local own = { root = self.bridgeId, cost = 0, bridge = self.bridgeId, port = "" }
  local best, rootPort = own, nil
  local t = now(self)
  for name, port in pairs(self.ports) do
    local s = port.stp
    if s.best and t - s.best.at > self.maxAge then s.best = nil end
    if s.best and s.state ~= "disabled" and not port.errdisabled and s.best.bridge ~= self.bridgeId then
      local v = { root = s.best.root, cost = s.best.cost + s.cost, bridge = s.best.bridge, port = s.best.port }
      if better(v, best) then best, rootPort = v, port end
    end
  end
  local changed = self.root ~= best.root or self.rootPort ~= rootPort
  self.root, self.rootCost, self.rootPort = best.root, best.cost, rootPort
  for name, port in pairs(self.ports) do
    local s = port.stp
    local role
    if port.errdisabled or not port.up then role = "disabled"
    elseif port == rootPort then role = "root"
    else
      local designated = { root = self.root, cost = self.rootCost, bridge = self.bridgeId, port = s.id }
      if s.best then
        if s.best.bridge == self.bridgeId then role = "backup"
        elseif not better(designated, { root = s.best.root, cost = s.best.cost, bridge = s.best.bridge, port = s.best.port }) then role = "alternate"
        else role = "designated" end
      else
        role = "designated"
      end
    end
    s.role = role
    if role == "root" or role == "designated" then
      if s.state == "blocking" then self:advance(port) end
    else
      self:setState(port, role == "disabled" and "disabled" or "blocking")
    end
  end
  return changed
end

function Stp:isRoot() return self.root == self.bridgeId end

--- A BPDU arrived on `port`.
function Stp:receive(port, payload)
  if not self.enabled then return end
  if #payload == 7 and payload:byte(7) == 128 then
    -- a topology change notification from a bridge below us: acknowledge it and pass it on towards the root
    if port.stp.role == "designated" then
      port.stp.tca = true
      self:topologyDetected()
      self:sendOn(port)
    end
    return
  end
  local b = decodeBpdu(payload)
  if not b then return end
  local s = port.stp
  local vec = { root = b.rootId, cost = b.cost, bridge = b.bridgeId, port = b.portId }
  local cur = s.best
  local replace = false
  if not cur then replace = true
  elseif cur.bridge == b.bridgeId and cur.port == b.portId then replace = true          -- refresh from the same designated port
  elseif better(vec, { root = cur.root, cost = cur.cost, bridge = cur.bridge, port = cur.port }) then replace = true end
  if replace then
    if port == self.rootPort then
      if b.flags % 2 == 1 then self:topologyAnnounced() end
      if b.flags >= 128 then self.tcnPending = false end
    end
    s.best = { root = b.rootId, cost = b.cost, bridge = b.bridgeId, port = b.portId, at = now(self), hello = b.hello }
    -- the root dictates the timers (802.1D 8.6.2)
    if b.maxAge > 0 and b.rootId == self.root then self.maxAge, self.forwardDelay = b.maxAge, b.forwardDelay end
    self:recompute()
  elseif s.role == "designated" then
    -- an inferior BPDU on our designated port: answer at once so the neighbour learns the better information
    self:sendOn(port)
  end
end

function Stp:sendOn(port)
  local s = port.stp
  if s.state == "disabled" or port.errdisabled or not port.up then return end
  local age = 0
  if self.rootPort and self.rootPort.stp.best then age = math.min(self.maxAge - 1, (now(self) - self.rootPort.stp.best.at) + 1) end
  local flags = 0
  if self.tcActiveUntil and now(self) < self.tcActiveUntil then flags = flags + M.FLAG_TC end
  if s.tca then flags = flags + M.FLAG_TCA s.tca = nil end
  self.sw:sendRaw(port, M.MAC, M.ETH_LEN_TYPE, encodeBpdu({
    flags = flags, rootId = self.root, cost = self.rootCost, bridgeId = self.bridgeId, portId = s.id, messageAge = age, maxAge = self.maxAge, hello = self.hello, forwardDelay = self.forwardDelay,
  }))
  s.sent = (s.sent or 0) + 1
end

--- Called every hello interval and whenever the topology may have changed.
--- This bridge saw a port enter or leave forwarding: tell the root (TCN) or, as the root, announce it to everybody (TC flag in the BPDUs).
function Stp:topologyDetected()
  if not self.enabled then return end
  self.sw:flushPort(nil)
  if self:isRoot() then
    self.tcActiveUntil = now(self) + self.maxAge + self.forwardDelay
  else
    self.tcnPending = true
    self:sendTcn()
  end
end

--- The root announced a topology change (TC flag): forget learned addresses and shorten aging for a while.
function Stp:topologyAnnounced()
  local t = now(self)
  if not self.tcActiveUntil or t >= self.tcActiveUntil then self.sw:flushPort(nil) end
  self.tcActiveUntil = math.max(self.tcActiveUntil or 0, t + self.maxAge + self.forwardDelay)
end

function Stp:sendTcn()
  local port = self.rootPort
  if port and port.up and not port.errdisabled then
    self.sw:sendRaw(port, M.MAC, M.TCN_LEN, "\66\66\3\0\0\0\128")
  end
end

function Stp:periodic()
  if not self.enabled then return end
  if self.tcnPending then self:sendTcn() end
  self:recompute()
  for _, port in pairs(self.ports) do
    if port.stp.role == "designated" then self:sendOn(port) end
  end
end

--- Start the periodic hello (and aging) timer.
function Stp:start()
  self.running = true
  for _, port in pairs(self.ports) do port.stp.state = "blocking" end
  self:recompute()
  local function loop()
    if not self.running then return end
    self:periodic()
    self.sw.stack:after(self.hello, loop)
  end
  loop()
end

function Stp:stop()
  self.running = false
  for _, port in pairs(self.ports) do port.stp.state = "forwarding" port.stp.role = "designated" end
end

--- Text for `swctl show stp`.
function Stp:describe()
  local lines = {}
  local function id(x) return ("%d/%s"):format(B.rd16(x, 1), B.macStr(x:sub(3))) end
  lines[#lines + 1] = ("bridge %s, root %s%s, root cost %d"):format(id(self.bridgeId), id(self.root), self:isRoot() and " (this bridge)" or "", self.rootCost)
  local names = {}
  for name in pairs(self.ports) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local s = self.ports[name].stp
    lines[#lines + 1] = ("  %-8s %-10s %-11s cost %d"):format(name, s.role, s.state, s.cost)
  end
  return lines
end

return M
