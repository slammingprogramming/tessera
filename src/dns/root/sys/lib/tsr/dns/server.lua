-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The name server: answers "dns.q" questions from the zone files in /etc/tsr/zones/*.zone and from names that computers registered by
-- themselves. Registration goes through the authenticated service "dns" (see tsr.net pairing), so only computers paired with the server
-- can claim names, and a computer can only register for itself (its own id) and only in the zones the config allows:
--   /etc/tsr/dns.cfg  { serve = true, dynamic = { "base" }, register = { server = "ns1", name = "farm1.base" }, ttl = 600 }
-- Dynamic records expire after their time to live unless renewed; zone-file records are static. Answers are not signed: like classic DNS
-- this is a convenience for a friendly network, not a defence against a hostile one (use `ssh` host key checks for that).
local zone = require("tsr.dns.zone")
local resolver = require("tsr.dns.resolver")
local vfs = require("tsr.vfs")
local log = require("tsr.log").get("dns")

local M = {}

M.ZONES = "/etc/tsr/zones"
M.MAX_DYNAMIC = 200

local function now() return os.epoch and os.epoch("utc") / 1000 or os.clock() end

--- The server's database: static records from the zone files plus live dynamic ones.
function M.new(opts)
  opts = opts or {}
  local db = { static = {}, dynamic = {}, clock = opts.clock or now, problems = {} }
  function db:load()
    self.static, self.problems = {}, {}
    if fs.isDir(M.ZONES) then
      local names = fs.list(M.ZONES)
      table.sort(names)
      for _, f in ipairs(names) do
        if f:match("%.zone$") then
          local z, problems = zone.parse(vfs.readFile(M.ZONES .. "/" .. f) or "")
          for _, r in ipairs(z.records) do self.static[#self.static + 1] = r end
          for _, p in ipairs(problems) do self.problems[#self.problems + 1] = f .. ": " .. p end
        end
      end
    end
    return self
  end

  --- Records for a name and type (CNAME records answer for every type).
  function db:answer(name, rtype)
    local out = {}
    local t = self.clock()
    local function scan(list)
      for _, r in ipairs(list) do
        if r.name == name and (r.type == rtype or r.type == "CNAME") and (not r.expires or r.expires > t) then
          out[#out + 1] = { name = r.name, type = r.type, value = r.value, ttl = r.expires and math.max(1, math.floor(r.expires - t)) or r.ttl }
        end
      end
    end
    scan(self.static)
    scan(self.dynamic)
    return out
  end

  --- Register `name` -> `id` dynamically (replaces an older registration of that name).
  function db:register(name, id, ttl)
    local t = self.clock()
    local keep = {}
    for _, r in ipairs(self.dynamic) do if r.expires > t and r.name ~= name then keep[#keep + 1] = r end end
    if #keep >= M.MAX_DYNAMIC then return nil, "the dynamic table is full" end
    keep[#keep + 1] = { name = name, type = "A", value = id, expires = t + (ttl or 600) }
    self.dynamic = keep
    return true
  end

  function db:unregister(name)
    local keep, n = {}, 0
    for _, r in ipairs(self.dynamic) do if r.name == name then n = n + 1 else keep[#keep + 1] = r end end
    self.dynamic = keep
    return n
  end

  return db
end

local function allowedZone(cfg, name)
  for _, z in ipairs(cfg.dynamic or {}) do
    if name == z or name:sub(-(#z + 1)) == "." .. z then return true end
  end
  return false
end

--- Serve on a net node: questions from anybody (plain messages), registrations from paired computers. Returns the database.
function M.serve(node, db, cfg)
  db = db or M.new():load()
  cfg = cfg or resolver.config()
  node.handlers = node.handlers or {}
  node.handlers["dns.q"] = function(self, from, msg)
    if type(msg.name) ~= "string" or type(msg.q) ~= "string" then return end
    local name = zone.normalize(msg.name)
    local rtype = zone.TYPES[tostring(msg.type)] and msg.type or "A"
    if not name then return self:send(from, { t = "dns.r", q = msg.q, rcode = "bad name" }) end
    local answers = db:answer(name, rtype)
    self:send(from, { t = "dns.r", q = msg.q, name = name, type = rtype, answers = answers, rcode = "ok" })
  end
  node:serve("dns", function(from, method, a)
    local peer = node:peer(from)
    if method == "register" then
      local name = zone.normalize(type(a) == "table" and a.name or "")
      if not name then error("bad name", 0) end
      if not allowedZone(cfg, name) then error("this server does not accept registrations for " .. name, 0) end
      local ok, err = db:register(name, from, tonumber(a.ttl) or cfg.ttl or 600)
      if not ok then error(err, 0) end
      log.info("%s registered %s -> %d", peer and peer.name or "?", name, from)
      return { name = name, id = from, ttl = tonumber(a.ttl) or cfg.ttl or 600 }
    elseif method == "unregister" then
      local name = zone.normalize(type(a) == "table" and a.name or "")
      for _, r in ipairs(db.dynamic) do
        if r.name == name and r.value ~= from then error("that name belongs to another computer", 0) end
      end
      return { removed = db:unregister(name) }
    end
    error("unknown method " .. tostring(method), 0)
  end)
  return db
end

--- The dnsd service: serve when configured, and keep this computer's own name registered at a name server.
function M.daemon()
  local net = require("tsr.net")
  local node = net.default()
  local cfg = resolver.config()
  if cfg.serve then
    local db = M.new():load()
    for _, p in ipairs(db.problems) do log.warn("zone file: %s", p) end
    M.serve(node, db, cfg)
    log.info("name server up: %d static record(s)", #db.static)
  end
  while true do
    cfg = resolver.config()
    local reg = vfs.readTable(resolver.CONFIG) and vfs.readTable(resolver.CONFIG).register
    if type(reg) == "table" and reg.server and reg.name then
      local res, err = node:call(reg.server, "dns", "register", { name = reg.name, ttl = (cfg.ttl or 600) }, { timeout = 5 })
      if not res then log.warn("could not register %s at %s: %s", reg.name, tostring(reg.server), tostring(err)) end
    end
    sleep(math.max(30, (cfg.ttl or 600) / 2))
  end
end

return M
