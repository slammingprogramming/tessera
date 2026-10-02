-- SPDX-License-Identifier: AGPL-3.0-or-later
-- RIP version 2 (RFC 2453): routers tell their neighbours which networks they can reach and at what cost (hops, 1..15; 16 = unreachable), and
-- everybody builds a routing table from what they hear. Updates every 30 s (or at once when something changes), routes that are not refreshed
-- time out after 180 s, split horizon with poison reverse stops two routers counting to infinity. Messages go to the multicast group 224.0.0.9, UDP 520.
--
-- Added for safety (RIP has no protection of its own): `auth = { type = "password", key = "..." }` (RFC 2453 section 5.2) or `type = "hmac"`
-- (HMAC-SHA256 with a sequence number against replays; this one is Tessera's own, not part of the RFC), and `neighbors = { "10.0.0.2" }` to
-- accept updates only from listed routers.
local B = require("tsr.inet.bytes")
local socket = require("tsr.inet.socket")

local M = {}
local Rip = {}
Rip.__index = Rip

M.PORT = 520
M.GROUP = "224.0.0.9"
M.INFINITY = 16
M.DISTANCE = 120               -- stack metric of a RIP route = DISTANCE + hop count (static routes win over it)

local function key(net, plen) return net .. "/" .. plen end

--- cfg: interfaces (names; default every interface with an address), redistribute = { "connected", "static" }, defaultRoute (advertise 0.0.0.0/0),
--- passive = { names that listen but do not send }, auth, neighbors, update (30), timeout (180), gc (120).
function M.new(stack, cfg)
  cfg = cfg or {}
  local self = setmetatable({
    stack = stack, cfg = cfg, routes = {}, update = cfg.update or 30, timeout = cfg.timeout or 180, gc = cfg.gc or 120, seq = 0, peerSeq = {},
    stats = { sent = 0, received = 0, rejected = 0, triggered = 0 }, redistribute = {}, passive = {}, neighbours = {},
  }, Rip)
  for _, r in ipairs(cfg.redistribute or { "connected" }) do self.redistribute[r] = true end
  for _, n in ipairs(cfg.passive or {}) do self.passive[n] = true end
  if cfg.neighbors then
    self.allowed = {}
    for _, n in ipairs(cfg.neighbors) do self.allowed[B.ip(n)] = true end
  end
  return self
end

function Rip:ifaces()
  local out = {}
  if self.cfg.interfaces then
    for _, n in ipairs(self.cfg.interfaces) do if self.stack.ifaces[n] then out[#out + 1] = self.stack.ifaces[n] end end
  else
    for _, i in ipairs(self.stack.ifaceList) do if i.kind ~= "loopback" and #i.addrs > 0 then out[#out + 1] = i end end
  end
  return out
end

---------------------------------------------------------------------------------------------------------------------
-- Messages
---------------------------------------------------------------------------------------------------------------------

local function encodeEntry(net, plen, nexthop, metric, tag)
  return B.u16(2) .. B.u16(tag or 0) .. B.u32(net) .. B.u32(B.mask(plen)) .. B.u32(nexthop or 0) .. B.u32(metric)
end

function M.encode(command, entries, auth, seq)
  local body = {}
  if auth then
    if auth.type == "password" then
      body[#body + 1] = B.u16(0xFFFF) .. B.u16(2) .. (auth.key .. string.rep("\0", 16)):sub(1, 16)
    elseif auth.type == "hmac" then
      body[#body + 1] = B.u16(0xFFFF) .. B.u16(0x5453) .. B.u32(seq or 0) .. string.rep("\0", 12)
    end
  end
  for _, e in ipairs(entries) do
    if e.whole then body[#body + 1] = B.u16(0) .. B.u16(0) .. string.rep("\0", 12) .. B.u32(16)         -- "send me everything" (RFC 2453 3.9.1)
    else body[#body + 1] = encodeEntry(e.net, e.plen, e.nexthop, e.metric, e.tag) end
  end
  local msg = string.char(command, 2) .. "\0\0" .. table.concat(body)
  if auth and auth.type == "hmac" then
    local mac = require("tsr.crypto").kdf.hmac(auth.key, msg):sub(1, 16)
    msg = msg .. B.u16(0xFFFF) .. B.u16(1) .. mac
  end
  return msg
end

--- Returns { command, entries = { {net, plen, nexthop, metric, tag} }, auth = { type = "password"|"hmac"|nil, key / seq / mac }, wholeTable }.
function M.decode(data)
  if #data < 4 or data:byte(2) ~= 2 then return nil, "not RIPv2" end
  local m = { command = data:byte(1), entries = {} }
  local pos = 5
  local macTrailer
  while pos + 19 <= #data do
    local afi = B.rd16(data, pos)
    if afi == 0xFFFF then
      local t = B.rd16(data, pos + 2)
      if t == 2 then m.auth = { type = "password", key = (data:sub(pos + 4, pos + 19):gsub("%z+$", "")) }
      elseif t == 0x5453 then m.auth = { type = "hmac", seq = B.rd32(data, pos + 4), covered = data:sub(1, #data) }
      elseif t == 1 then macTrailer = { mac = data:sub(pos + 4, pos + 19), at = pos } end
    elseif afi == 2 then
      local mask = B.rd32(data, pos + 8)
      local plen = B.maskToPrefix(B.ipStr(mask))
      if plen then m.entries[#m.entries + 1] = { net = B.band(B.rd32(data, pos + 4), mask), plen = plen, nexthop = B.rd32(data, pos + 12), metric = B.rd32(data, pos + 16), tag = B.rd16(data, pos + 2) } end
    elseif afi == 0 and m.command == 1 then m.wholeTable = true m.entries[#m.entries + 1] = { net = 0, plen = 0, metric = 16, whole = true }
    end
    pos = pos + 20
  end
  if m.auth and m.auth.type == "hmac" and macTrailer then
    m.auth.mac = macTrailer.mac
    m.auth.covered = data:sub(1, macTrailer.at - 1)
  end
  return m
end

---------------------------------------------------------------------------------------------------------------------
-- The table
---------------------------------------------------------------------------------------------------------------------

--- Everything we know and would advertise right now: { net, plen, metric, via (interface name it was learned on), nexthop }.
function Rip:advertised()
  local out = {}
  for _, r in pairs(self.routes) do out[#out + 1] = { net = r.net, plen = r.plen, metric = r.metric, via = r.iface, nexthop = r.nexthop, learned = true } end
  local stack = self.stack
  for _, r in ipairs(stack.routes) do
    if r.proto == "connected" and self.redistribute.connected and r.iface ~= "lo" then
      out[#out + 1] = { net = r.net, plen = r.plen, metric = 1, via = r.iface }
    elseif r.proto == "static" and self.redistribute.static and r.plen > 0 then
      out[#out + 1] = { net = r.net, plen = r.plen, metric = 1, via = nil }
    end
  end
  if self.cfg.defaultRoute then out[#out + 1] = { net = 0, plen = 0, metric = 1 } end
  return out
end

function Rip:install(r)
  self.stack:addRoute(B.cidrStr(r.net, r.plen), r.nexthop, { iface = r.iface, proto = "rip", metric = M.DISTANCE + r.metric })
end

function Rip:uninstall(r)
  self.stack:removeRoutes(function(x) return x.proto == "rip" and x.net == r.net and x.plen == r.plen end)
end

local function now(self) return self.stack.clock() end

--- Process one received response message from `src` on interface `iface`.
function Rip:process(msg, src, iface)
  local t = now(self)
  local changed = false
  for _, e in ipairs(msg.entries) do
    if e.metric >= 1 and e.metric <= M.INFINITY and not e.whole and e.plen <= 32 and not B.isLoopback(e.net) and not B.isMulticast(e.net) then
      local metric = math.min(M.INFINITY, e.metric + 1)
      local nexthop = e.nexthop ~= 0 and e.nexthop or src
      -- a next hop that is not on the segment is replaced by the sender
      local onLink = false
      for _, a in ipairs(iface.addrs) do if B.inNet(nexthop, B.band(a.ip, B.mask(a.plen)), a.plen) then onLink = true end end
      if not onLink then nexthop = src end
      local k = key(e.net, e.plen)
      local cur = self.routes[k]
      -- routes we know better (connected or static) are never replaced
      local own = false
      for _, r in ipairs(self.stack.routes) do
        if r.net == e.net and r.plen == e.plen and (r.proto == "connected" or r.proto == "static") then own = true break end
      end
      if not own then
        if not cur then
          if metric < M.INFINITY then
            local r = { net = e.net, plen = e.plen, metric = metric, nexthop = nexthop, iface = iface.name, from = src, expires = t + self.timeout }
            self.routes[k] = r
            self:install(r)
            changed = true
          end
        elseif cur.from == src and cur.iface == iface.name then
          if metric ~= cur.metric then
            changed = true
            if metric >= M.INFINITY then
              cur.metric, cur.gcAt = M.INFINITY, t + self.gc
              self:uninstall(cur)
            else
              if cur.metric >= M.INFINITY then cur.gcAt = nil end
              cur.metric = metric
              cur.nexthop = nexthop
              self:uninstall(cur) self:install(cur)
            end
          end
          if metric < M.INFINITY then cur.expires = t + self.timeout end
        elseif metric < cur.metric then
          self:uninstall(cur)
          cur.metric, cur.nexthop, cur.iface, cur.from, cur.expires, cur.gcAt = metric, nexthop, iface.name, src, t + self.timeout, nil
          self:install(cur)
          changed = true
        end
      end
    end
  end
  if changed then self:triggerUpdate() end
  return changed
end

--- Routes whose neighbour went silent become unreachable (and are announced as such), then are forgotten.
function Rip:expire()
  local t = now(self)
  local changed = false
  for k, r in pairs(self.routes) do
    if r.metric < M.INFINITY and t >= r.expires then
      r.metric, r.gcAt = M.INFINITY, t + self.gc
      self:uninstall(r)
      changed = true
    elseif r.metric >= M.INFINITY and r.gcAt and t >= r.gcAt then
      self.routes[k] = nil
    end
  end
  if changed then self:triggerUpdate() end
end

---------------------------------------------------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------------------------------------------------

function Rip:send(u, iface, msgEntries, dst)
  local auth = self.cfg.auth
  local i = 1
  repeat
    local chunk = {}
    for k = i, math.min(i + 24, #msgEntries) do chunk[#chunk + 1] = msgEntries[k] end
    self.seq = self.seq + 1
    local data = M.encode(2, chunk, auth, self.seq)
    local src = iface.addrs[1] and iface.addrs[1].ip
    u:sendto(data, dst or M.GROUP, M.PORT, { iface = iface.name, src = src, ttl = 1 })
    self.stats.sent = self.stats.sent + 1
    i = i + 25
  until i > #msgEntries
end

--- Send our table out of every interface (split horizon with poison reverse), or to one neighbour.
function Rip:sendUpdate(u, onlyIface, dst)
  for _, iface in ipairs(self:ifaces()) do
    if (not onlyIface or onlyIface == iface) and not self.passive[iface.name] then
      local entries = {}
      local seen = {}
      for _, a in ipairs(self:advertised()) do
        local k = key(a.net, a.plen)
        if not seen[k] then
          seen[k] = true
          local metric = a.metric
          if a.via == iface.name then
            if a.learned then metric = M.INFINITY else metric = nil end        -- connected to this very interface: the neighbour knows it
          end
          if metric then entries[#entries + 1] = { net = a.net, plen = a.plen, metric = metric, nexthop = 0 } end
        end
      end
      if #entries > 0 then self:send(u, iface, entries, dst) end
    end
  end
end

function Rip:triggerUpdate()
  if self.triggerPending or not self.socket then return end
  self.triggerPending = true
  self.stats.triggered = self.stats.triggered + 1
  self.stack:after(1 + (self.stack.random(2) - 1) * 0.5, function()
    self.triggerPending = false
    if self.running then self:sendUpdate(self.socket) end
  end)
end

---------------------------------------------------------------------------------------------------------------------
-- Running
---------------------------------------------------------------------------------------------------------------------

function Rip:handleDatagram(data, srcIp, d)
  local iface = self.stack.ifaces[d.iface]
  if not iface then return end
  local msg = M.decode(data)
  if not msg then self.stats.rejected = self.stats.rejected + 1 return end
  -- ignore ourselves and anything from beyond the segment
  if self.stack:isLocal(srcIp) then return end
  local direct = false
  for _, a in ipairs(iface.addrs) do if B.inNet(srcIp, B.band(a.ip, B.mask(a.plen)), a.plen) then direct = true end end
  if not direct then self.stats.rejected = self.stats.rejected + 1 return end
  if self.allowed and not self.allowed[srcIp] then self.stats.rejected = self.stats.rejected + 1 return end
  local auth = self.cfg.auth
  if auth then
    if not msg.auth or msg.auth.type ~= auth.type then self.stats.rejected = self.stats.rejected + 1 return end
    if auth.type == "password" and msg.auth.key ~= auth.key:sub(1, 16) then self.stats.rejected = self.stats.rejected + 1 return end
    if auth.type == "hmac" then
      local expect = require("tsr.crypto").kdf.hmac(auth.key, msg.auth.covered):sub(1, 16)
      if not msg.auth.mac or msg.auth.mac ~= expect then self.stats.rejected = self.stats.rejected + 1 return end
      if msg.auth.seq <= (self.peerSeq[srcIp] or 0) and msg.auth.seq > (self.peerSeq[srcIp] or 0) - 1000000 then self.stats.rejected = self.stats.rejected + 1 return end
      self.peerSeq[srcIp] = msg.auth.seq
    end
  elseif msg.auth then
    -- an authenticated neighbour on an unauthenticated router: accept (RFC 2453 allows it) only when no auth is configured at all
  end
  self.stats.received = self.stats.received + 1
  self.neighbours[srcIp] = { iface = iface.name, last = now(self) }
  if msg.command == 2 then
    self:process(msg, srcIp, iface)
  elseif msg.command == 1 then
    -- a request: for the whole table answer with our table, otherwise the entries asked for
    if msg.wholeTable then self:sendUpdate(self.socket, iface, B.ipStr(srcIp)) end
  end
end

--- Worker functions (parallel.waitForAny / sim:spawn each).
function Rip:workers()
  local stack = self.stack
  local u = socket.udp(stack)
  u:setoption("reuse", true)
  local ok, err = u:bind(nil, M.PORT)
  if not ok then return nil, err end
  stack:joinGroup(M.GROUP)
  self.socket = u
  self.running = true
  local rip = self
  local jobs = {}
  jobs[#jobs + 1] = function()
    -- ask the neighbours for their tables right away
    for _, iface in ipairs(rip:ifaces()) do
      if not rip.passive[iface.name] then
        rip.seq = rip.seq + 1
        u:sendto(M.encode(1, { { whole = true } }, rip.cfg.auth, rip.seq), M.GROUP, M.PORT, { iface = iface.name, src = iface.addrs[1].ip, ttl = 1 })
      end
    end
    while rip.running do
      local data, ip, port, info = u:receivefrom(1)
      if data and port == M.PORT then rip:handleDatagram(data, B.ip(ip), info) end
    end
  end
  jobs[#jobs + 1] = function()
    while rip.running do
      rip:sendUpdate(u)
      local jitter = (stack.random(100) - 50) / 100 * (rip.update / 6)
      stack.wait(function() return not rip.running end, rip.update + jitter)
    end
  end
  jobs[#jobs + 1] = function()
    while rip.running do
      rip:expire()
      stack.wait(function() return not rip.running end, 5)
    end
  end
  return jobs
end

function Rip:stop()
  self.running = false
  for _, r in pairs(self.routes) do self:uninstall(r) end
  self.routes = {}
  self.stack:leaveGroup(M.GROUP)
  if self.socket then self.socket:close() end
end

--- Text lines for the routectl command.
function Rip:describe()
  local lines = {}
  local list = {}
  for _, r in pairs(self.routes) do list[#list + 1] = r end
  table.sort(list, function(a, b) if a.net ~= b.net then return a.net < b.net end return a.plen < b.plen end)
  for _, r in ipairs(list) do
    lines[#lines + 1] = ("%-18s via %-15s dev %-6s metric %2d  %s"):format(B.cidrStr(r.net, r.plen), B.ipStr(r.nexthop), r.iface, r.metric,
      r.metric >= M.INFINITY and "(unreachable, garbage collecting)" or ("expires in " .. math.max(0, math.floor(r.expires - now(self))) .. "s"))
  end
  return lines
end

return M
