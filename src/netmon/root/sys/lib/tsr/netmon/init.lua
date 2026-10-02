-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Network monitor: see what travels over the in-game network, like tcpdump or Wireshark.
--   Monitor.attach(node, opts)    watch every message that goes through this computer's node (needs the network daemon or another reader)
--   Monitor.sniffer(opts)         "promiscuous mode": listen on modem channels for rednet traffic between OTHER computers in range
-- Records are { at, dir, peer, to, kind, size, protection }; the payload is not kept, only what kind of message it is and whether it
-- was protected (encrypted, signed or plain). This also shows why unprotected messages should not carry secrets: anybody with a modem
-- in range can do exactly what the sniffer mode does.
local M = {}

local PROTOCOL = "tsr.net"

local function sizeOf(msg)
  if type(msg) == "string" then return #msg end
  local ok, text = pcall(textutils.serialise, msg)
  return ok and #text or 0
end

--- What kind of message is this, and how well is it protected?
function M.classify(msg)
  if type(msg) ~= "table" then return type(msg) == "string" and "text" or type(msg), "plain" end
  local t = msg.t
  if t == "ssh" then
    local k = msg.k
    if k == "rec" or k == "rep" then return "ssh/" .. k, "encrypted" end
    return "ssh/" .. tostring(k), "public handshake"
  elseif t == "rpc" or t == "rpc.r" then
    return t, msg.enc and "encrypted" or "signed"
  elseif t == "p2p" then
    return "p2p/" .. tostring(msg.k), "plain (hash-checked)"
  elseif t and tostring(t):match("^pair%.") then
    return t, "code-protected"
  elseif t then
    return tostring(t), "plain"
  end
  return "other", "plain"
end

local Monitor = {}
Monitor.__index = Monitor
M.Monitor = Monitor

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    limit = opts.limit or 200,
    records = {},
    total = 0,
    kinds = {},          -- kind -> { packets, bytes }
    peers = {},          -- peer -> { packets, bytes, drops }
    filter = opts.filter or {},
    clock = opts.clock or os.clock,
    onRecord = opts.onRecord,
    dropped = 0,
  }, Monitor)
end

local function inSet(set, value)
  return set == nil or next(set) == nil or set[value] == true
end

--- Does this record pass the filter? filter: types (set of kind prefixes), peers (set of ids), drops (only refused messages), dir.
function Monitor:wants(rec)
  local f = self.filter
  if f.dropsOnly and rec.dir ~= "drop" then return false end
  if f.dir and rec.dir ~= f.dir then return false end
  if f.peers and next(f.peers) and not (f.peers[rec.peer] or f.peers[rec.to]) then return false end
  if f.types and next(f.types) then
    local hit = false
    for prefix in pairs(f.types) do
      if rec.kind == prefix or rec.kind:sub(1, #prefix + 1) == prefix .. "/" then hit = true end
    end
    if not hit then return false end
  end
  return true
end

function Monitor:record(dir, peer, to, msg)
  local kind, protection = M.classify(msg)
  local rec = { at = self.clock(), dir = dir, peer = peer, to = to, kind = kind, size = sizeOf(msg), protection = protection }
  self.total = self.total + 1
  local k = self.kinds[kind] or { packets = 0, bytes = 0 }
  k.packets, k.bytes = k.packets + 1, k.bytes + rec.size
  self.kinds[kind] = k
  local who = peer or to
  if who ~= nil then
    local p = self.peers[who] or { packets = 0, bytes = 0, drops = 0 }
    p.packets, p.bytes = p.packets + 1, p.bytes + rec.size
    if dir == "drop" then p.drops = p.drops + 1 end
    self.peers[who] = p
  end
  if dir == "drop" then self.dropped = self.dropped + 1 end
  if not self:wants(rec) then return nil end
  self.records[#self.records + 1] = rec
  if #self.records > self.limit then table.remove(self.records, 1) end
  if self.onRecord then pcall(self.onRecord, rec) end
  return rec
end

--- Start watching a net node. Returns the monitor; monitor:stop() detaches.
function M.attach(node, opts)
  local mon = M.new(opts)
  mon.detach = node:tap(function(direction, n, peer, msg)
    if direction == "out" then mon:record("out", n.id, peer, msg)
    elseif direction == "bcast" then mon:record("out", n.id, "*", msg)
    elseif direction == "in" then mon:record("in", peer, n.id, msg)
    else mon:record("drop", peer, n.id, msg) end
  end)
  return mon
end

function Monitor:stop()
  if self.detach then self.detach() self.detach = nil end
  if self.closeChannels then self.closeChannels() self.closeChannels = nil end
end

--- Promiscuous mode: open `channels` (a list of numbers, e.g. computer ids) on every modem and decode rednet envelopes seen there.
--- Feed it the events with monitor:event(ev) (the CLI does). Returns the monitor and how many channels were opened.
function M.sniffer(opts)
  local mon = M.new(opts)
  local opened = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      local modem = peripheral.wrap(name)
      for _, ch in ipairs(opts.channels or {}) do
        if pcall(modem.open, ch) then opened[#opened + 1] = { modem = modem, channel = ch } end
      end
    end
  end
  mon.closeChannels = function() for _, o in ipairs(opened) do pcall(o.modem.close, o.channel) end end
  return mon, #opened
end

--- Handle an event table { "modem_message", side, channel, replyChannel, message, distance }. Returns the record or nil.
function Monitor:event(ev)
  if ev[1] ~= "modem_message" then return nil end
  local channel, reply, message = ev[3], ev[4], ev[5]
  local inner = message
  if type(message) == "table" and (message.nRecipient ~= nil or message.sProtocol ~= nil) then
    if message.sProtocol ~= PROTOCOL then
      -- some other rednet protocol: we only know it exists
      local rec = self:record("sniff", reply, channel, { t = "rednet:" .. tostring(message.sProtocol) })
      return rec
    end
    inner = message.message
  end
  return self:record("sniff", reply, channel, inner)
end

--- One line of text for a record.
function M.format(rec, base)
  local arrow = rec.dir == "out" and ">" or rec.dir == "in" and "<" or rec.dir == "drop" and "X" or "~"
  local peer = tostring(rec.dir == "out" and rec.to or rec.peer)
  if rec.dir == "sniff" then peer = tostring(rec.peer) .. "->" .. tostring(rec.to) end
  return ("%8.2f %s %-10s %-14s %5dB  %s"):format(rec.at - (base or 0), arrow, peer, rec.kind, rec.size, rec.protection)
end

--- A summary: totals by kind and by peer, and a note about plain traffic.
function Monitor:summary()
  local lines = { ("%d message(s) seen%s"):format(self.total, self.dropped > 0 and (", " .. self.dropped .. " refused by the firewall") or "") }
  local kinds = {}
  for kind, k in pairs(self.kinds) do kinds[#kinds + 1] = kind end
  table.sort(kinds, function(a, b) if self.kinds[a].packets ~= self.kinds[b].packets then return self.kinds[a].packets > self.kinds[b].packets end return a < b end)
  for _, kind in ipairs(kinds) do
    local k = self.kinds[kind]
    lines[#lines + 1] = ("  %-16s %5d message(s) %7d bytes"):format(kind, k.packets, k.bytes)
  end
  local peers = {}
  for id in pairs(self.peers) do peers[#peers + 1] = id end
  table.sort(peers, function(a, b) return tostring(a) < tostring(b) end)
  for _, id in ipairs(peers) do
    local p = self.peers[id]
    lines[#lines + 1] = ("  computer %-6s %5d message(s) %7d bytes%s"):format(tostring(id), p.packets, p.bytes, p.drops > 0 and (", " .. p.drops .. " refused") or "")
  end
  return lines
end

--- Save the recorded messages as tab-separated text (netmon read <file> shows them again) / load them.
function Monitor:save(path)
  local vfs = require("tsr.vfs")
  local out = {}
  for _, r in ipairs(self.records) do
    out[#out + 1] = table.concat({ ("%.3f"):format(r.at), r.dir, tostring(r.peer), tostring(r.to), r.kind, r.size, r.protection }, "\t")
  end
  return vfs.writeFile(path, table.concat(out, "\n") .. "\n")
end

function M.load(path)
  local vfs = require("tsr.vfs")
  local text = vfs.readFile(path)
  if not text then return nil, "cannot read " .. path end
  local mon = M.new({ limit = math.huge })
  for line in text:gmatch("[^\n]+") do
    local at, dir, peer, to, kind, size, protection = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
    if not at then return nil, "not a netmon capture: " .. line:sub(1, 30) end
    local rec = { at = tonumber(at), dir = dir, peer = tonumber(peer) or (peer ~= "nil" and peer or nil), to = tonumber(to) or (to ~= "nil" and to or nil),
      kind = kind, size = tonumber(size) or 0, protection = protection }
    mon.records[#mon.records + 1] = rec
    mon.total = mon.total + 1
    local k = mon.kinds[kind] or { packets = 0, bytes = 0 }
    k.packets, k.bytes = k.packets + 1, k.bytes + rec.size
    mon.kinds[kind] = k
  end
  return mon
end

return M
