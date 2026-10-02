-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Name service commands:
--   host <name>                         the computer a name stands for (and where the answer came from)
--   dig <name> [A|CNAME|TXT|NS]         all records of a name, like dig
--   dns servers [add <id|name> | del <id|name>]       the name servers this computer asks (and the search suffixes: dns search add <suffix>)
--   dns hosts [add <id> <name> | del <name>]          the static hosts file (/etc/hosts)
--   dns zone [add <name> A <id> | add <name> CNAME <target> | del <name>]      the records this computer serves (zone /etc/tsr/zones/local.zone)
--   dns serve on|off                    answer questions for the zone files (needs the dnsd service)
--   dns register <name> <server>        keep this computer registered under <name> at that name server (dnsd renews it)
--   dns flush                           forget cached answers
local zone = require("tsr.dns.zone")
local resolver = require("tsr.dns.resolver")
local server = require("tsr.dns.server")
local vfs = require("tsr.vfs")

local M = {}

local function defaultIO()
  local io = {}
  function io.say(t) print(t) end
  function io.err(t) if term.isColor and term.isColor() then term.setTextColor(colors.red) end print(t) term.setTextColor(colors.white) end
  return io
end

local function needAdmin(io)
  local okAuth, auth = pcall(require, "tsr.auth")
  if not okAuth or not auth.hasUsers() then return true end
  local me = auth.current()
  if me == nil or auth.can(me, "auth.manage") then return true end
  io.err("only administrators can change name service settings")
  return false
end

local function saveConfig(cfg) return vfs.writeTable(resolver.CONFIG, cfg) end

local function removeFrom(list, value)
  local out = {}
  for _, v in ipairs(list) do if tostring(v) ~= tostring(value) then out[#out + 1] = v end end
  return out
end

local function nodeOf(node)
  if node then return node end
  return require("tsr.net").default()
end

function M.host(args, io, node)
  io = io or defaultIO()
  if not args[1] then io.err("usage: host <name>") return false end
  local answers, err = resolver.query(nodeOf(node), args[1], "A")
  if not answers then
    local id = nodeOf(node):resolve(args[1], 1)
    if id then io.say(("%s is computer %d (found by asking the network)"):format(args[1], id)) return true end
    io.err("host " .. args[1] .. " not found: " .. tostring(err))
    return false
  end
  for _, a in ipairs(answers) do
    if a.type == "A" then io.say(("%s has address (computer) %d  [%s]"):format(a.name, a.value, tostring(answers.source)))
    else io.say(("%s is an alias for %s"):format(a.name, tostring(a.value))) end
  end
  return true
end

function M.dig(args, io, node)
  io = io or defaultIO()
  if not args[1] then io.err("usage: dig <name> [A|CNAME|TXT|NS]") return false end
  local rtype = (args[2] or "A"):upper()
  local answers, err = resolver.query(nodeOf(node), args[1], rtype)
  if not answers then io.err(";; no answer: " .. tostring(err)) return false end
  io.say((";; %d answer(s) from %s"):format(#answers, tostring(answers.source)))
  for _, a in ipairs(answers) do io.say(("%-30s %-6d IN %-6s %s"):format(a.name, a.ttl or 0, a.type, tostring(a.value))) end
  return true
end

function M.dns(args, io, node)
  io = io or defaultIO()
  local sub = args[1] or "status"
  local cfg = resolver.config()

  if sub == "status" then
    io.say("name servers: " .. (#cfg.servers > 0 and table.concat(cfg.servers, ", ") or "none"))
    io.say("search suffixes: " .. (#cfg.search > 0 and table.concat(cfg.search, ", ") or "none"))
    local hosts, n = resolver.hosts(), 0
    for _ in pairs(hosts) do n = n + 1 end
    io.say(("hosts file: %d name(s); serving zones: %s"):format(n, cfg.serve and "yes" or "no"))
    return true
  elseif sub == "servers" or sub == "search" then
    local field = sub == "servers" and "servers" or "search"
    if args[2] == "add" and args[3] then
      if not needAdmin(io) then return false end
      local v = tonumber(args[3]) or args[3]
      cfg[field] = removeFrom(cfg[field], v)
      cfg[field][#cfg[field] + 1] = v
      saveConfig(cfg)
    elseif args[2] == "del" and args[3] then
      if not needAdmin(io) then return false end
      cfg[field] = removeFrom(cfg[field], args[3])
      saveConfig(cfg)
    end
    io.say(table.concat(cfg[field], ", "))
    return true
  elseif sub == "hosts" then
    local lines = {}
    for line in ((vfs.readFile(resolver.HOSTS) or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do lines[#lines + 1] = line end
    while #lines > 0 and lines[#lines] == "" do lines[#lines] = nil end
    if args[2] == "add" and tonumber(args[3]) and args[4] then
      if not needAdmin(io) then return false end
      lines[#lines + 1] = ("%d %s"):format(tonumber(args[3]), args[4]:lower())
      vfs.writeFile(resolver.HOSTS, table.concat(lines, "\n") .. "\n")
    elseif args[2] == "del" and args[3] then
      if not needAdmin(io) then return false end
      local keep = {}
      for _, l in ipairs(lines) do
        local drop = false
        for word in l:gsub("#.*$", ""):gmatch("%S+") do if word:lower() == args[3]:lower() and not word:match("^%d+$") then drop = true end end
        if not drop then keep[#keep + 1] = l end
      end
      vfs.writeFile(resolver.HOSTS, table.concat(keep, "\n") .. (#keep > 0 and "\n" or ""))
    end
    for l in (vfs.readFile(resolver.HOSTS) or ""):gmatch("[^\r\n]+") do io.say(l) end
    return true
  elseif sub == "zone" then
    local file = server.ZONES .. "/local.zone"
    local z = zone.parse(vfs.readFile(file) or "")
    if args[2] == "add" and args[3] and args[4] and args[5] then
      if not needAdmin(io) then return false end
      local line = ("%s %s %s"):format(args[3], args[4]:upper(), args[5])
      local parsed, problems = zone.parse((z.origin ~= "" and ("$origin " .. z.origin .. "\n") or "") .. line)
      if #problems > 0 or #parsed.records == 0 then io.err(problems[1] or "cannot read that record") return false end
      local records = z.records
      records[#records + 1] = parsed.records[1]
      vfs.writeFile(file, zone.format(records))
      z.records = records
    elseif args[2] == "del" and args[3] then
      if not needAdmin(io) then return false end
      local name = zone.normalize(args[3], z.origin)
      local keep = {}
      for _, r in ipairs(z.records) do if r.name ~= name then keep[#keep + 1] = r end end
      vfs.writeFile(file, zone.format(keep))
      z.records = keep
    end
    for _, r in ipairs(z.records) do io.say(("%-30s %-6s %s"):format(r.name, r.type, tostring(r.value))) end
    return true
  elseif sub == "serve" then
    if not needAdmin(io) then return false end
    cfg.serve = args[2] == "on"
    cfg.dynamic = cfg.dynamic or {}
    saveConfig(cfg)
    io.say("this computer will " .. (cfg.serve and "" or "no longer ") .. "answer name questions (restart dnsd: svc restart dnsd)")
    return true
  elseif sub == "register" then
    if not needAdmin(io) then return false end
    if not (args[2] and args[3]) then io.err("usage: dns register <name> <name server>") return false end
    local name, err = zone.normalize(args[2])
    if not name then io.err(err) return false end
    cfg.register = { name = name, server = tonumber(args[3]) or args[3] }
    saveConfig(cfg)
    io.say("dnsd will keep " .. name .. " registered at " .. tostring(args[3]))
    return true
  elseif sub == "flush" then
    resolver.flush()
    io.say("cache flushed")
    return true
  end
  io.err("usage: dns status | servers | search | hosts | zone | serve on|off | register <name> <server> | flush")
  return false
end

return M
