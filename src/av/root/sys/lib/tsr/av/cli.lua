-- SPDX-License-Identifier: AGPL-3.0-or-later
-- av: the anti-virus.
--   av scan [path...] [--quarantine | --delete] [--all] [-v]   scan files and folders (default: everything except the system's own files); --all also rescans installed package files
--   av check <file>                                            scan one file and explain
--   av status                                                  definitions, settings, protection
--   av quarantine list | restore <id> [to] | delete <id> | purge <days>
--   av update [source]                                         get newer definitions (a path, or a URL; default: the sources in the settings)
--   av trust list | add <name> <public-key> | del <name>       publishers whose definitions are accepted
--   av defs keygen <file> | sign <definitions-file> <keyfile> | info        for people who publish definitions
--   av config show | set <key>=<value>...
--   av testfile <path>                                         write the harmless standard test file, to check that the scanner works
local av = require("tsr.av")
local q = require("tsr.av.quarantine")
local defs = require("tsr.av.defs")
local rules = require("tsr.av.rules")
local vfs = require("tsr.vfs")
local crypto = require("tsr.crypto")

local M = {}

local function defaultCtx(ctx)
  ctx = ctx or {}
  ctx.say = ctx.say or function(t) print(t) end
  ctx.err = ctx.err or ctx.say
  return ctx
end

local function flags(args)
  local pos, opt = {}, {}
  for _, a in ipairs(args) do
    if a == "--quarantine" or a == "-q" then opt.action = "quarantine"
    elseif a == "--delete" then opt.action = "delete"
    elseif a == "--all" then opt.all = true
    elseif a == "-v" then opt.verbose = true
    else pos[#pos + 1] = a end
  end
  return pos, opt
end

local function scan(args, ctx)
  local pos, opt = flags(args)
  if #pos == 0 then pos = { "/" } end
  local totals = { scanned = 0, clean = 0, suspicious = 0, malicious = 0, known = 0, errors = 0 }
  for _, root in ipairs(pos) do
    if not vfs.fs.exists(vfs.normalize(root)) then ctx.err("no such file or folder: " .. root) totals.errors = totals.errors + 1
    else
      local s = av.scanTree(root, { action = opt.action, skipKnown = not opt.all, progress = function(path, r)
        if r.verdict ~= "clean" then
          ctx.say(("%-10s %s"):format(r.verdict:upper(), path))
          if opt.verbose or r.verdict ~= "clean" then
            for _, f in ipairs(r.findings) do ctx.say(("             %s%s: %s"):format(f.id, f.line and (" (line " .. f.line .. ")") or "", f.description or "")) end
          end
          if r.quarantined then ctx.say("             moved to the quarantine as " .. r.quarantined) end
          if r.deleted then ctx.say("             deleted") end
        elseif opt.verbose then ctx.say(("clean      %s%s"):format(path, r.skipped and (" (" .. r.skipped .. ")") or "")) end
      end })
      for k in pairs(totals) do totals[k] = totals[k] + (s[k] or 0) end
    end
  end
  ctx.say(("scanned %d file(s): %d clean, %d suspicious, %d malicious; %d installed package file(s) skipped, %d error(s)"):format(totals.scanned, totals.clean, totals.suspicious, totals.malicious, totals.known, totals.errors))
  return totals.malicious == 0 and totals.suspicious == 0 and totals.errors == 0
end

local function check(args, ctx)
  local target = args[1]
  if not target then ctx.err("usage: av check <file>") return false end
  local r, err = av.scanFile(target)
  if not r then ctx.err(tostring(err)) return false end
  ctx.say(("%s: %s"):format(target, r.verdict))
  ctx.say(("sha256: %s, %d bytes%s"):format(r.sha256, r.size, r.skipped and (", not analysed: " .. r.skipped) or ""))
  if r.allowed then ctx.say("known good: " .. r.allowed) end
  for _, f in ipairs(r.findings) do ctx.say(("  +%-3d %s%s - %s"):format(f.score, f.id, f.line and (" (line " .. f.line .. ")") or "", f.description or "")) end
  ctx.say(("score %d (suspicious from %d, malicious from %d)"):format(r.score, av.settings().suspicious_at, av.settings().malicious_at))
  return r.verdict == "clean"
end

local function status(ctx)
  local s = av.settings()
  local d = av.loadDefs(true)
  local nHash, nPat = 0, 0
  for _ in pairs(d.hashes) do nHash = nHash + 1 end
  nPat = #d.patterns
  ctx.say("definitions:  " .. (d.sources ~= "" and d.sources or "none") .. (" (%d known files, %d patterns, %d behaviour rules)"):format(nHash, nPat, #rules.RULES))
  ctx.say("publishers:   " .. (#defs.keys() > 0 and tostring(#defs.keys()) .. " trusted" or "none trusted (updates are not accepted until: av trust add <name> <key>)"))
  ctx.say(("thresholds:   suspicious from %d, malicious from %d"):format(s.suspicious_at, s.malicious_at))
  ctx.say("on a hit:     " .. s.action)
  ctx.say("floppies:     " .. (s.scan_disks and "scanned when inserted (avd service)" or "not scanned automatically"))
  ctx.say("packages:     " .. (s.scan_packages and "scanned before installing" or "not scanned before installing"))
  ctx.say("quarantine:   " .. #q.list() .. " item(s)")
  return true
end

local function quarantine(args, ctx)
  local sub = table.remove(args, 1) or "list"
  if sub == "list" then
    local items = q.list()
    if #items == 0 then ctx.say("the quarantine is empty") return true end
    for _, m in ipairs(items) do ctx.say(("%s  %s  (%s)"):format(m.id, m.path, table.concat(m.findings or {}, ", "))) end
    return true
  elseif sub == "restore" then
    local dest, err = q.restore(args[1] or "", args[2])
    if not dest then ctx.err(tostring(err)) return false end
    ctx.say("restored to " .. dest)
    return true
  elseif sub == "delete" then
    local ok, err = q.delete(args[1] or "")
    if not ok then ctx.err(tostring(err)) return false end
    ctx.say("deleted")
    return true
  elseif sub == "purge" then
    local days = tonumber(args[1])
    if not days then ctx.err("usage: av quarantine purge <days>") return false end
    ctx.say(q.purge(days) .. " item(s) removed")
    return true
  end
  ctx.err("usage: av quarantine list | restore <id> [to] | delete <id> | purge <days>")
  return false
end

local function update(args, ctx)
  local sources = args[1] and { args[1] } or av.settings().sources
  if #sources == 0 then ctx.err("no source given and none in the settings (av config set sources=<url or path>)") return false end
  local gotAny = false
  for _, src in ipairs(sources) do
    local version, publisher = defs.update(src, { stack = ctx.stack })
    if version then
      ctx.say(("definitions v%d from %s installed (signed by %s)"):format(version, src, tostring(publisher)))
      gotAny = true
    else
      ctx.err(src .. ": " .. tostring(publisher))
    end
  end
  av.loadDefs(true)
  return gotAny
end

local function trust(args, ctx)
  local sub = table.remove(args, 1) or "list"
  if sub == "list" then
    local keys = defs.keys()
    if #keys == 0 then ctx.say("no publisher is trusted") end
    for _, k in ipairs(keys) do ctx.say(("%-20s %s"):format(k.name, k.key)) end
    return true
  elseif sub == "add" then
    local ok, err = defs.trust(args[1], args[2])
    if not ok then ctx.err(tostring(err)) return false end
    ctx.say("trusted " .. tostring(args[1]))
    return true
  elseif sub == "del" then
    local ok, err = defs.untrust(args[1] or "")
    if not ok then ctx.err(tostring(err)) return false end
    ctx.say("removed")
    return true
  end
  ctx.err("usage: av trust list | add <name> <key> | del <name>")
  return false
end

local function defsCmd(args, ctx)
  local sub = table.remove(args, 1)
  if sub == "keygen" and args[1] then
    local secret, public = defs.keygen()
    local ok, err = vfs.writeFile(vfs.normalize(args[1]), crypto.base64Encode(secret) .. "\n")
    if not ok then ctx.err(tostring(err)) return false end
    ctx.say("secret key saved to " .. args[1] .. " - keep it private")
    ctx.say("public key (give this to everybody who should accept your definitions): " .. public)
    return true
  elseif sub == "sign" and args[1] and args[2] then
    local text = vfs.readFile(vfs.normalize(args[1]))
    local keyText = vfs.readFile(vfs.normalize(args[2]))
    if not text or not keyText then ctx.err("cannot read the files") return false end
    local secret = crypto.base64Decode((keyText:gsub("%s+", "")))
    if not secret or #secret ~= 32 then ctx.err("the key file is damaged") return false end
    local sig = defs.sign(text, secret)
    vfs.writeFile(vfs.normalize(args[1]) .. ".sig", sig)
    ctx.say("wrote " .. args[1] .. ".sig - publish both files together")
    return true
  elseif sub == "info" then
    local d = av.loadDefs(true)
    local st = defs.state()
    ctx.say("version: " .. tostring(d.version) .. "   from: " .. d.sources)
    if st then ctx.say(("updated definitions: v%d, signed by %s"):format(st.version, tostring(st.publisher))) end
    return true
  end
  ctx.err("usage: av defs keygen <file> | sign <definitions-file> <keyfile> | info")
  return false
end

local function config(args, ctx)
  local sub = table.remove(args, 1) or "show"
  local s = av.settings()
  if sub == "show" then
    local keys = {}
    for k in pairs(s) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local v = s[k]
      ctx.say(("%-16s %s"):format(k, type(v) == "table" and table.concat(v, ", ") or tostring(v)))
    end
    return true
  elseif sub == "set" then
    local saved = {}
    local f = io.open and nil
    local text = vfs.readFile(av.CONFIG)
    local stored = text and textutils.unserializeJSON(text) or {}
    for _, a in ipairs(args) do
      local k, v = a:match("^([%w_]+)=(.*)$")
      if not k or av.DEFAULTS[k] == nil then ctx.err("unknown setting: " .. a) return false end
      local d = av.DEFAULTS[k]
      if type(d) == "number" then stored[k] = tonumber(v)
      elseif type(d) == "boolean" then stored[k] = v == "true" or v == "yes" or v == "on"
      elseif type(d) == "table" then
        local list = {}
        for item in v:gmatch("[^,]+") do list[#list + 1] = item end
        stored[k] = list
      else
        if k == "action" and v ~= "report" and v ~= "quarantine" and v ~= "delete" then ctx.err("action is report, quarantine or delete") return false end
        stored[k] = v
      end
      if stored[k] == nil then ctx.err("bad value for " .. k) return false end
    end
    av.saveSettings(stored)
    ctx.say("saved")
    return true
  end
  ctx.err("usage: av config show | set key=value")
  return false
end

function M.run(args, ctx)
  ctx = defaultCtx(ctx)
  local sub = table.remove(args, 1)
  if sub == "scan" then return scan(args, ctx)
  elseif sub == "check" then return check(args, ctx)
  elseif sub == "status" or sub == nil then return status(ctx)
  elseif sub == "quarantine" then return quarantine(args, ctx)
  elseif sub == "update" then return update(args, ctx)
  elseif sub == "trust" then return trust(args, ctx)
  elseif sub == "defs" then return defsCmd(args, ctx)
  elseif sub == "config" then return config(args, ctx)
  elseif sub == "testfile" then
    if not args[1] then ctx.err("usage: av testfile <path>") return false end
    vfs.writeFile(vfs.normalize(args[1]), rules.TEST_STRING .. "\n")
    ctx.say("wrote " .. args[1] .. " (harmless). Now: av check " .. args[1])
    return true
  end
  ctx.err("usage: av scan | check | status | quarantine | update | trust | defs | config | testfile")
  return false
end

return M
