-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Commands:
--   nslookup <name> [A|NS|MX|TXT|CNAME|SOA|PTR|SRV|ANY] [@server]     ask a name server (the configured ones unless @server is given)
--   dnsctl status | zones | records <zone> | flush | reload
--   dnsctl zone create <origin> <ns-name> <ns-ip>                      new primary zone (SOA, NS and the glue address)
--   dnsctl add <zone> <name> <type> <data...> [ttl N]                  add a record      dnsctl del <zone> <name> [type]
--   dnsctl pull <zone>                                                  refresh a secondary zone now
local B = require("tsr.inet.bytes")
local W = require("tsr.inet.dns.wire")
local zoneMod = require("tsr.inet.dns.zone")
local client = require("tsr.inet.dns.client")
local vfs = require("tsr.vfs")

local M = {}

local function defaultCtx(ctx)
  ctx = ctx or {}
  if not ctx.say then
    ctx.say = function(t) print(t) end
    ctx.err = function(t) print(t) end
  end
  ctx.err = ctx.err or ctx.say
  if not ctx.stack then
    local ok, stack = pcall(function() return require("tsr.inet.socket").default() end)
    if not ok then ctx.err(tostring(stack)) return nil end
    ctx.stack = stack
  end
  return ctx
end

function M.nslookup(args, ctx)
  ctx = defaultCtx(ctx)
  if not ctx then return false end
  local stack = ctx.stack
  local name, qtype, server
  for _, a in ipairs(args) do
    if a:sub(1, 1) == "@" then server = a:sub(2)
    elseif W.TYPES[a:upper()] and name then qtype = a:upper()
    else name = name or a end
  end
  if not name then ctx.err("usage: nslookup <name> [type] [@server]") return false end
  qtype = qtype or "A"
  -- an address means a reverse lookup
  local ip = B.ip(name)
  if ip then name, qtype = W.reverseName(ip), "PTR" end
  local servers = server and { server } or stack.dnsServers
  if not servers or #servers == 0 then ctx.err("no DNS server is configured (use @server or set one in /etc/tsr/inet/network.lua)") return false end
  local result, err = client.lookup(stack, name, qtype, { servers = servers, nocache = true })
  if not result then ctx.err(";; no answer: " .. tostring(err)) return false end
  ctx.say(("Server: %s"):format(result.from or tostring(servers[1])))
  ctx.say((";; status: %s%s"):format(W.RCODE_NAMES[result.rcode] or tostring(result.rcode), result.aa and ", authoritative answer" or ""))
  for _, rr in ipairs(result.answers) do
    ctx.say(("%-30s %6d IN %-6s %s"):format(rr.name .. ".", rr.ttl, W.TYPE_NAMES[rr.type] or tostring(rr.type), W.dataText(rr)))
  end
  if #result.answers == 0 then
    for _, rr in ipairs(result.authority) do
      ctx.say(("%-30s %6d IN %-6s %s   ;; authority"):format(rr.name .. ".", rr.ttl, W.TYPE_NAMES[rr.type] or tostring(rr.type), W.dataText(rr)))
    end
  end
  return result.rcode == W.RCODE.OK and #result.answers > 0
end

--- A name typed in a command: relative to the zone unless it ends with a dot or already ends with the zone name.
local function qualify(name, origin)
  name = name:lower()
  if name == "@" then return origin end
  if name:sub(-1) == "." then return name:sub(1, -2) end
  if name == origin or origin == "" or name:sub(-(#origin + 1)) == "." .. origin then return name end
  return name .. "." .. origin
end

local function saveZone(z)
  if z.file then
    z.zone:bumpSerial()
    return vfs.writeFile(z.file, zoneMod.serialize(z.zone))
  end
  return true
end

local function parseRecord(zone, name, typeName, rest)
  local text = ("%s %s %s"):format(name, typeName, table.concat(rest, " "))
  local z, problems = zoneMod.parse(text, zone.origin)
  if #problems > 0 then return nil, (problems[1]:gsub("^line %d+: ", "")) end
  for _, rr in ipairs(z:all()) do return rr end
  return nil, "nothing to add"
end

function M.dnsctl(args, ctx)
  ctx = defaultCtx(ctx)
  if not ctx then return false end
  local server = ctx.server or require("tsr.inet.dns.daemon").server
  local sub = args[1] or "status"
  if sub == "flush" then client.flush(ctx.stack) ctx.say("cache cleared") return true end
  if not server then ctx.err("the name server (named) is not running on this computer") return false end
  if sub == "status" then
    local s = server.stats
    ctx.say(("queries %d, answered from zones %d, NXDOMAIN %d, recursive %d, refused %d, truncated %d, zone transfers %d"):format(s.queries, s.answers, s.nxdomain, s.recursive, s.refused, s.truncated, s.transfers))
    ctx.say("recursion: " .. (server.recursionOn and "on" or "off"))
    return true
  elseif sub == "zones" then
    local names = {}
    for origin in pairs(server.zones) do names[#names + 1] = origin end
    table.sort(names)
    for _, origin in ipairs(names) do
      local z = server.zones[origin]
      ctx.say(("%-24s %s serial %d, %d records%s"):format(origin == "" and "(root)" or origin, z.secondary and "secondary" or "primary", z.zone:serial(), z.zone.count, z.secondary and not z.loaded and " (not transferred yet)" or ""))
    end
    return true
  elseif sub == "records" then
    local z = server.zones[W.normalize(args[2] or "")]
    if not z then ctx.err("no such zone") return false end
    for _, rr in ipairs(z.zone:all()) do ctx.say(("%-30s %6d IN %-6s %s"):format(rr.name .. ".", rr.ttl, W.TYPE_NAMES[rr.type] or rr.type, W.dataText(rr))) end
    return true
  elseif sub == "reload" then
    server.zones = {}
    local problems = server:loadZones()
    for _, p in ipairs(problems) do ctx.err(p) end
    client.flush(ctx.stack)
    ctx.say("zones reloaded")
    return #problems == 0
  elseif sub == "pull" then
    local ok, err = server:pullZone(W.normalize(args[2] or ""))
    if not ok then ctx.err("transfer failed: " .. tostring(err)) return false end
    ctx.say("zone transferred")
    return true
  elseif sub == "zone" and args[2] == "create" then
    local origin, nsName, nsIp = W.normalize(args[3] or ""), W.normalize(args[4] or ""), B.ip(args[5] or "")
    if origin == "" or nsName == "" or not nsIp then ctx.err("usage: dnsctl zone create <origin> <ns-name> <ns-ip>") return false end
    if server.zones[origin] then ctx.err("that zone exists already") return false end
    local zone = zoneMod.new(origin)
    zone:add({ name = origin, type = W.TYPES.SOA, ttl = 3600, data = { mname = nsName, rname = "hostmaster." .. origin, serial = 1, refresh = 3600, retry = 600, expire = 86400, minimum = 300 } })
    zone:add({ name = origin, type = W.TYPES.NS, ttl = 3600, data = nsName })
    if W.isSubdomain(nsName, origin) then zone:add({ name = nsName, type = W.TYPES.A, ttl = 3600, data = nsIp }) end
    local file = "/etc/tsr/inet/zones/" .. (origin == "" and "root" or origin) .. ".zone"
    server:addZone(zone, { file = file, origin = origin })
    server.zones[origin].file = file
    vfs.writeFile(file, zoneMod.serialize(zone))
    ctx.say("zone " .. origin .. " created in " .. file .. " (add it to /etc/tsr/inet/named.lua to load it after a restart)")
    return true
  elseif sub == "add" then
    local z = server.zones[W.normalize(args[2] or "")]
    if not z or z.secondary then ctx.err("no such primary zone") return false end
    local name, typeName = args[3], args[4] and args[4]:upper()
    if not (name and typeName and W.TYPES[typeName] and args[5]) then ctx.err("usage: dnsctl add <zone> <name> <type> <data...>") return false end
    local rest = {}
    for i = 5, #args do rest[#rest + 1] = args[i] end
    local ttl
    if rest[#rest - 1] == "ttl" then ttl = tonumber(rest[#rest]) rest[#rest] = nil rest[#rest] = nil end
    local rr, err = parseRecord(z.zone, qualify(name, z.zone.origin) .. ".", typeName, rest)
    if not rr then ctx.err(tostring(err)) return false end
    if ttl then rr.ttl = ttl end
    z.zone:add(rr)
    saveZone(z)
    client.flush(ctx.stack)
    ctx.say(("added %s %s %s"):format(rr.name, typeName, W.dataText(rr)))
    return true
  elseif sub == "del" then
    local z = server.zones[W.normalize(args[2] or "")]
    if not z or z.secondary then ctx.err("no such primary zone") return false end
    local n = z.zone:remove(qualify(args[3] or "", z.zone.origin), args[4])
    if n == 0 then ctx.err("no such record") return false end
    saveZone(z)
    client.flush(ctx.stack)
    ctx.say(("removed %d record(s)"):format(n))
    return true
  end
  ctx.err("usage: dnsctl status | zones | records <zone> | zone create ... | add ... | del ... | pull <zone> | flush | reload")
  return false
end

return M
