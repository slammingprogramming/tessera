-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Turning names into computers. net's own lookup asks everybody within modem range "who is called X?"; the name service adds names that
-- work anywhere you can reach a name server, aliases and a hosts file. Lookup order for a name:
--   1. /etc/hosts          "<id> name [alias...]" lines, always trusted, no network
--   2. the cache           answers remembered for their time to live
--   3. the name servers    /etc/tsr/dns.cfg { servers = { 3, "ns1" }, search = { "base" }, timeout = 2 }
-- A name without a dot is also tried with each search suffix ("farm1" -> "farm1.base"). tsr.net calls `lookup` automatically when this
-- package is installed, so every command that takes a computer (ssh, ntpdate, torrent get ...) accepts names from the zone.
local zone = require("tsr.dns.zone")
local vfs = require("tsr.vfs")

local M = {}

M.HOSTS = "/etc/hosts"
M.CONFIG = "/etc/tsr/dns.cfg"
M.NEGATIVE_TTL = 30
M.MAX_CNAME = 8

local cache = {}          -- "name|type" -> { answers, expires }

function M.config()
  local c = vfs.readTable(M.CONFIG) or {}
  c.servers = c.servers or {}
  c.search = c.search or {}
  c.timeout = c.timeout or 2
  return c
end

local function now() return os.epoch and os.epoch("utc") / 1000 or os.clock() end

function M.flush() cache = {} end

--- The hosts file as { [name] = id }.
function M.hosts()
  local out = {}
  for line in ((vfs.readFile(M.HOSTS) or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    line = line:gsub("#.*$", "")
    local id, rest = line:match("^%s*(%d+)%s+(.+)$")
    if id then
      for name in rest:gmatch("%S+") do out[name:lower()] = tonumber(id) end
    end
  end
  return out
end

local function candidates(name, search)
  local list = {}
  local base, err = zone.normalize(name)
  if not base then return list, err end
  list[1] = base
  if not base:find(".", 1, true) then
    for _, suffix in ipairs(search) do list[#list + 1] = base .. "." .. suffix:lower() end
  end
  return list
end

--- Ask one server. Returns answers or nil + reason. `answers` is a list of { name, type, value, ttl }.
local function ask(node, server, name, rtype, timeout)
  local id = node:resolve(server, 1)
  if not id then return nil, "cannot reach name server " .. tostring(server) end
  local q = tostring(math.floor(os.clock() * 1000)) .. tostring(math.random(100000))
  node:send(id, { t = "dns.q", q = q, name = name, type = rtype })
  local reply = node:await(id, function(m) return m.t == "dns.r" and m.q == q end, timeout)
  if not reply then return nil, "no answer from name server " .. tostring(server) end
  if reply.rcode ~= "ok" then return nil, tostring(reply.rcode) end
  return reply.answers or {}
end

--- Resolve `name` to records of `rtype` (default "A"), following aliases. Returns answers (possibly empty, with .server and .cached set) or nil + reason.
function M.query(node, name, rtype, opts)
  opts = opts or {}
  rtype = rtype or "A"
  local cfg = M.config()
  local list, err = candidates(name, cfg.search)
  if err then return nil, err end
  local hosts = M.hosts()
  local lastErr = "not found"
  for _, candidate in ipairs(list) do
    local target = candidate
    for _ = 1, M.MAX_CNAME do
      -- hosts file
      if rtype == "A" and hosts[target] then
        return { { name = target, type = "A", value = hosts[target], ttl = 0 }, source = "hosts" }
      end
      local key = target .. "|" .. rtype
      local hit = cache[key]
      local answers, source
      if hit and hit.expires > now() then
        if hit.negative then break end
        answers, source = hit.answers, "cache"
      else
        for _, server in ipairs(cfg.servers) do
          local got, e = ask(node, server, target, rtype, opts.timeout or cfg.timeout)
          if got then answers, source = got, tostring(server) break end
          lastErr = e or lastErr
        end
        if answers and #answers > 0 then
          local ttl
          for _, a in ipairs(answers) do ttl = math.min(ttl or math.huge, a.ttl or 60) end
          if ttl and ttl > 0 then cache[key] = { answers = answers, expires = now() + ttl } end
        elseif answers then
          cache[key] = { negative = true, expires = now() + M.NEGATIVE_TTL }
        end
      end
      if not answers or #answers == 0 then break end
      -- an alias: follow it; the final records are the answer
      local alias
      for _, a in ipairs(answers) do if a.type == "CNAME" and rtype ~= "CNAME" then alias = a.value end end
      if alias then target = alias
      else
        answers.source = source
        return answers
      end
    end
  end
  return nil, lastErr
end

--- The computer id for a name, or nil + reason (used by tsr.net).
local busy = false

function M.lookup(node, name, timeout)
  if busy or type(name) ~= "string" or name:find("[^%w_%-%.]") then return nil end
  busy = true                       -- asking a name server may itself need to find a computer: never recurse
  local ok, answers, err = pcall(M.query, node, name, "A", { timeout = timeout })
  busy = false
  if not ok then return nil, tostring(answers) end
  if not answers then return nil, err end
  for _, a in ipairs(answers) do if a.type == "A" then return a.value end end
  return nil, "no address record"
end

return M
