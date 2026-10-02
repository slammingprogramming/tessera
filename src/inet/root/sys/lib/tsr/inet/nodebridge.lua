-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Lets everything that talks through tsr.net (pairing, remote calls, ssh, rsh, netfs, torrent, the key server, ...) run over the IP network instead of
-- plain rednet: the same messages travel in UDP datagrams on port 7777. Computers are still addressed by their computer id:
--   * a message for an id whose address we know (from the configuration, from earlier messages, from DNS name "cc<id>" or "<hostname>") is sent to that address;
--   * otherwise it is broadcast on every network this computer is connected to, and the computer with that id answers (like rednet does);
--   * `peers` in /etc/tsr/inet/nodes.lua are told about broadcasts too, so computers behind routers can find each other.
-- Turn it on with the setting net.transport = "ip" (settings app or `tsr config net.transport ip`).
--   /etc/tsr/inet/nodes.lua:   return { ids = { [15] = "10.2.0.15", [16] = "fileserver.lan" }, peers = { "10.9.0.1" } }
local B = require("tsr.inet.bytes")
local socket = require("tsr.inet.socket")
local vfs = require("tsr.vfs")

local M = {}

M.PORT = 7777
M.CONFIG = "/etc/tsr/inet/nodes.lua"

local function loadConfig()
  local text = vfs.readFile(M.CONFIG)
  if not text then return {} end
  local chunk = load(text, "=nodes.lua", "t", {})
  local ok, cfg = pcall(chunk or function() end)
  return ok and type(cfg) == "table" and cfg or {}
end

--- opts: stack, id (this computer's id), config (instead of the file), domain (suffix for DNS names).
function M.transport(opts)
  opts = opts or {}
  local stack = opts.stack or socket.default()
  local myId = opts.id or os.getComputerID()
  local cfg = opts.config or loadConfig()
  local known = {}                                  -- id -> ip number (learned)
  local u
  local t = { known = known, stats = { sent = 0, broadcasts = 0, received = 0 } }

  local function sock()
    if not u then
      u = socket.udp(stack)
      u:setoption("broadcast", true)
      u:setoption("reuse", true)
      assert(u:bind(nil, M.PORT))
    end
    return u
  end

  local function ipOf(id)
    if known[id] then return known[id] end
    local static = cfg.ids and cfg.ids[id]
    if static then return stack:resolve(static, 2) end
    if stack.resolver then
      local name = "cc" .. id
      local ip = stack:resolve(name, 2)
      if ip then return ip end
    end
    return nil
  end
  t.ipOf = ipOf

  local function packet(to, msg) return textutils.serialise({ from = myId, to = to, msg = msg }) end

  local function broadcastAll(data)
    t.stats.broadcasts = t.stats.broadcasts + 1
    local s = sock()
    for _, iface in ipairs(stack.ifaceList) do
      if iface.up and iface.kind ~= "loopback" and #iface.addrs > 0 then s:sendto(data, "255.255.255.255", M.PORT, { iface = iface.name }) end
    end
    for _, p in ipairs(cfg.peers or {}) do
      local ip = stack:resolve(p, 2)
      if ip then s:sendto(data, B.ipStr(ip), M.PORT) end
    end
  end

  function t.send(id, msg)
    t.stats.sent = t.stats.sent + 1
    local data = packet(id, msg)
    local ip = ipOf(id)
    if ip then
      sock():sendto(data, B.ipStr(ip), M.PORT)
    else
      broadcastAll(data)
    end
  end

  function t.broadcast(msg) broadcastAll(packet(nil, msg)) end

  -- Several coroutines read from one node (the daemon loop, a blocked call, ssh...). Rednet gives each of them every message; to behave the same, every
  -- reader has its own queue and a datagram that one of them takes from the socket is copied into all of them.
  local subs = {}
  local function subscriber()
    local co = coroutine.running()
    local sub = subs[co]
    if not sub then sub = { queue = {} } subs[co] = sub end
    sub.seen = stack.clock()
    return sub
  end
  local function distribute(from, msg)
    local now = stack.clock()
    for co, sub in pairs(subs) do
      if now - sub.seen > 60 or coroutine.status(co) == "dead" then subs[co] = nil
      else
        if #sub.queue >= 64 then table.remove(sub.queue, 1) end
        sub.queue[#sub.queue + 1] = { from, msg }
      end
    end
  end

  function t.receive(timeout)
    local s = sock()
    local sub = subscriber()
    local deadline = timeout and (stack.clock() + timeout)
    while true do
      if #sub.queue > 0 then
        local item = table.remove(sub.queue, 1)
        return item[1], item[2]
      end
      local left = deadline and math.max(0, deadline - stack.clock()) or nil
      if deadline and left <= 0 then return nil end
      local data, ip = s:receivefrom(left and math.min(left, 1) or 1)
      if data then
        local d = textutils.unserialise(data)
        if type(d) == "table" and type(d.from) == "number" and d.from ~= myId and (d.to == nil or d.to == myId) then
          known[d.from] = B.ip(ip)
          t.stats.received = t.stats.received + 1
          distribute(d.from, d.msg)
        end
      end
    end
  end

  function t.available() return #stack.ifaceList > 1 end
  function t.close() if u then u:close() u = nil end end
  return t
end

return M
