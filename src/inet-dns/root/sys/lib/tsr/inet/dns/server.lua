-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The name server: authoritative for the zones it is given (primary from files, secondary by zone transfer), recursive for the networks you allow
-- (iterating from the root hints you configure, or forwarding), with a cache. UDP and TCP on port 53; answers longer than 512 bytes are truncated
-- on UDP so clients retry over TCP; zone transfers (AXFR) go to the servers you list.
--
-- Configuration /etc/tsr/inet/named.lua:
--   return {
--     zones = {
--       { origin = "example.lan", file = "/etc/tsr/inet/zones/example.lan.zone", allowTransfer = { "10.0.0.3" }, notify = { "10.0.0.3" } },
--       { origin = "other.lan", type = "secondary", masters = { "10.0.0.9" } },
--     },
--     recursion = true,                       -- answer recursive queries (for the networks below)
--     allowRecursion = { "10.0.0.0/8" },      -- default: the networks this server is connected to
--     roots = { "10.0.0.1" },                 -- root hints: where to start iterating
--     forwarders = {},                        -- or: ask these resolvers instead of iterating ("upstream" = the DNS servers learned by DHCP)
--   }
local B = require("tsr.inet.bytes")
local socket = require("tsr.inet.socket")
local W = require("tsr.inet.dns.wire")
local zoneMod = require("tsr.inet.dns.zone")
local recursorMod = require("tsr.inet.dns.recursor")
local client = require("tsr.inet.dns.client")
local vfs = require("tsr.vfs")

local M = {}
local Server = {}
Server.__index = Server

M.CONFIG = "/etc/tsr/inet/named.lua"
M.ZONE_DIR = "/etc/tsr/inet/zones"
M.UDP_LIMIT = 512

function M.new(stack, cfg)
  local self = setmetatable({
    stack = stack, zones = {}, cfg = cfg or {}, stats = { queries = 0, answers = 0, nxdomain = 0, refused = 0, recursive = 0, transfers = 0, truncated = 0 },
    allowRecursion = {},
  }, Server)
  self.recursionOn = cfg.recursion ~= false and ((cfg.roots and #cfg.roots > 0) or (cfg.forwarders and #cfg.forwarders > 0)) or false
  if self.recursionOn then self.recursor = recursorMod.new(stack, { roots = cfg.roots, forwarders = cfg.forwarders, timeout = cfg.timeout }) end
  for _, n in ipairs(cfg.allowRecursion or {}) do
    local net, plen = B.cidr(n)
    if net then self.allowRecursion[#self.allowRecursion + 1] = { net, plen } end
  end
  return self
end

--- Load the zones of the configuration. Returns problems (strings).
function Server:loadZones()
  local problems = {}
  for _, z in ipairs(self.cfg.zones or {}) do
    local origin = W.normalize(z.origin or "")
    if z.type == "secondary" then
      self.zones[origin] = { zone = zoneMod.new(origin), spec = z, secondary = true, loaded = false }
    else
      local text = z.text or (z.file and vfs.readFile(z.file))
      if not text then problems[#problems + 1] = "zone " .. origin .. ": cannot read " .. tostring(z.file)
      else
        local zone, probs = zoneMod.parse(text, origin)
        if zone.origin == "" then zone.origin = origin end
        for _, p in ipairs(probs) do problems[#problems + 1] = "zone " .. origin .. ": " .. p end
        if not zone.soa then problems[#problems + 1] = "zone " .. origin .. ": no SOA record" end
        self.zones[zone.origin] = { zone = zone, spec = z, file = z.file }
      end
    end
  end
  return problems
end

function Server:addZone(zone, spec)
  self.zones[zone.origin] = { zone = zone, spec = spec or {} }
end

--- The zone that is authoritative for `name`: the one with the longest matching origin.
function Server:zoneFor(name)
  local best, bestLen
  for origin, z in pairs(self.zones) do
    if (z.zone.soa or z.loaded) and W.isSubdomain(name, origin) and (not bestLen or #origin > bestLen) then best, bestLen = z, #origin end
  end
  return best
end

function Server:mayRecurse(src)
  if not self.recursionOn then return false end
  if #self.allowRecursion > 0 then
    for _, n in ipairs(self.allowRecursion) do if B.inNet(src, n[1], n[2]) then return true end end
    return false
  end
  -- default: clients on a network this computer is directly connected to
  for _, iface in ipairs(self.stack.ifaceList) do
    for _, a in ipairs(iface.addrs) do if B.inNet(src, B.band(a.ip, B.mask(a.plen)), a.plen) then return true end end
  end
  return false
end

local function reply(q, fields)
  local r = { id = q.id, qr = true, opcode = 0, rd = q.rd, questions = q.questions, answers = {}, authority = {}, additional = {} }
  for k, v in pairs(fields or {}) do r[k] = v end
  return r
end

--- Answer a decoded query from `src`. Returns a reply table (to be encoded) or nil to stay silent.
function Server:answer(q, src, tcp)
  self.stats.queries = self.stats.queries + 1
  if q.qr then return nil end
  if q.opcode ~= 0 then return reply(q, { rcode = W.RCODE.NOTIMP }) end
  if #q.questions ~= 1 then return reply(q, { rcode = W.RCODE.FORMERR }) end
  local question = q.questions[1]
  if question.class ~= W.CLASS_IN and question.class ~= 255 then return reply(q, { rcode = W.RCODE.REFUSED }) end
  local name = question.name
  if question.type == W.TYPES.AXFR then
    return reply(q, { rcode = W.RCODE.REFUSED })                            -- transfers are handled by the TCP path (see transfer)
  end
  local z = self:zoneFor(name)
  if z then
    local res = z.zone:lookup(name, question.type)
    if res.rcode == W.RCODE.NXDOMAIN then self.stats.nxdomain = self.stats.nxdomain + 1 end
    self.stats.answers = self.stats.answers + 1
    return reply(q, { aa = res.aa, rcode = res.rcode, answers = res.answers, authority = res.authority, additional = res.additional, ra = self.recursionOn and self:mayRecurse(src) or false })
  end
  if q.rd and self:mayRecurse(src) then
    self.stats.recursive = self.stats.recursive + 1
    local result = self.recursor:resolve(name, question.type)
    if not result then return reply(q, { rcode = W.RCODE.SERVFAIL, ra = true }) end
    return reply(q, { rcode = result.rcode, answers = result.answers, authority = result.authority or {}, ra = true })
  end
  self.stats.refused = self.stats.refused + 1
  return reply(q, { rcode = W.RCODE.REFUSED, ra = self.recursionOn and self:mayRecurse(src) or false })
end

--- Raw message in, raw message out (nil = no answer). maxSize cuts UDP answers.
function Server:handle(data, src, tcp)
  local q = W.decode(data)
  if not q then
    if #data >= 2 then return W.encode({ id = B.rd16(data, 1), qr = true, rcode = W.RCODE.FORMERR }) end
    return nil
  end
  local r = self:answer(q, src, tcp)
  if not r then return nil end
  local out = W.encode(r, (not tcp) and M.UDP_LIMIT or nil)
  if (not tcp) and B.rd16(out, 3) >= 0x8000 and math.floor(B.rd16(out, 3) / 512) % 2 == 1 then self.stats.truncated = self.stats.truncated + 1 end
  return out
end

---------------------------------------------------------------------------------------------------------------------
-- Zone transfer (RFC 5936, simplified: one message per record batch over TCP)
---------------------------------------------------------------------------------------------------------------------

function Server:mayTransfer(src, z)
  for _, a in ipairs((z.spec and z.spec.allowTransfer) or {}) do
    if B.ip(a) == src then return true end
  end
  return false
end

function Server:transfer(q, src, c)
  local question = q.questions[1]
  local z = self.zones[question.name]
  if not z or not z.zone.soa then c:send(self:frame(W.encode(reply(q, { rcode = W.RCODE.REFUSED })))) return end
  if not self:mayTransfer(src, z) then
    self.stats.refused = self.stats.refused + 1
    c:send(self:frame(W.encode(reply(q, { rcode = W.RCODE.REFUSED }))))
    return
  end
  self.stats.transfers = self.stats.transfers + 1
  local records = z.zone:all()
  local batch = {}
  local function flush(first)
    local msg = reply(q, { aa = true, answers = batch })
    if not first then msg.questions = {} end
    c:send(self:frame(W.encode(msg)))
    batch = {}
  end
  local first = true
  local size = 0
  for _, rr in ipairs(records) do
    batch[#batch + 1] = rr
    size = size + 40
    if size > 8000 then flush(first) first = false size = 0 end
  end
  batch[#batch + 1] = z.zone.soa                        -- the transfer ends with the SOA again
  flush(first)
end

function Server:frame(msg) return B.u16(#msg) .. msg end

--- Fetch a zone from a master (AXFR) into a secondary zone object. Returns true or nil + reason.
function Server:pullZone(origin)
  local z = self.zones[origin]
  if not z or not z.secondary then return nil, "not a secondary zone" end
  for _, master in ipairs(z.spec.masters or {}) do
    local zone, err = M.axfr(self.stack, master, origin)
    if zone then
      z.zone = zone
      z.loaded = true
      z.lastPull = self.stack.clock()
      return true
    end
    z.lastError = err
  end
  return nil, z.lastError or "no master answered"
end

--- AXFR client: returns a Zone or nil + reason.
function M.axfr(stack, master, origin)
  local c = socket.tcp(stack)
  local ok, err = c:connect(master, 53, 3)
  if not ok then return nil, err end
  local msg = W.encode({ id = stack.random(65535), questions = { { name = origin, type = W.TYPES.AXFR, class = 1 } } })
  c:send(B.u16(#msg) .. msg)
  local zone = zoneMod.new(origin)
  local soaCount = 0
  while soaCount < 2 do
    local len = c:receive(2, 5)
    if not len then c:close() return nil, "transfer interrupted" end
    local data = c:receive(B.rd16(len, 1), 5)
    local m = data and W.decode(data)
    if not m then c:close() return nil, "bad transfer data" end
    if m.rcode ~= W.RCODE.OK then c:close() return nil, "refused" end
    for _, rr in ipairs(m.answers) do
      if rr.type == W.TYPES.SOA then
        soaCount = soaCount + 1
        if soaCount == 1 then zone:add(rr) end
      else
        zone:add(rr)
      end
    end
  end
  c:close()
  return zone
end

---------------------------------------------------------------------------------------------------------------------
-- Serving
---------------------------------------------------------------------------------------------------------------------

--- Worker functions to run side by side (parallel.waitForAny, or sim:spawn each in tests): UDP receivers, TCP acceptors, secondary refresh.
function Server:workers(n)
  local stack = self.stack
  local udp = socket.udp(stack)
  udp:setoption("broadcast", false)
  local ok, err = udp:bind(nil, 53)
  if not ok then return nil, err end
  local tcp = socket.tcp(stack)
  tcp:bind(nil, 53)
  assert(tcp:listen(8))
  self.udp, self.tcp = udp, tcp
  local jobs = {}
  for _ = 1, n or 3 do
    jobs[#jobs + 1] = function()
      while not self.stop do
        local data, ip, port = udp:receivefrom(1)
        if data then
          local out = self:handle(data, B.ip(ip), false)
          if out then udp:sendto(out, ip, port) end
        end
      end
    end
  end
  jobs[#jobs + 1] = function()
    while not self.stop do
      local c = tcp:accept(1)
      if c then
        local srcIp = B.ip((c:getpeername()))
        local len = c:receive(2, 5)
        if len then
          local data = c:receive(B.rd16(len, 1), 5)
          local q = data and W.decode(data)
          if q and q.questions and q.questions[1] and q.questions[1].type == W.TYPES.AXFR then
            self:transfer(q, srcIp, c)
          elseif data then
            local out = self:handle(data, srcIp, true)
            if out then c:send(self:frame(out)) end
          end
        end
        c:close()
      end
    end
  end
  jobs[#jobs + 1] = function()
    while not self.stop do
      for origin, z in pairs(self.zones) do
        if z.secondary then
          local refresh = (z.zone.soa and z.zone.soa.data.refresh) or 30
          if not z.loaded or stack.clock() - (z.lastPull or 0) >= refresh then self:pullZone(origin) z.lastPull = stack.clock() end
        end
      end
      stack.wait(function() return self.stop end, 5)
    end
  end
  return jobs
end

return M
