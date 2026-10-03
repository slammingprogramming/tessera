-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The anti-virus engine. "Virus" in ComputerCraft means programs that harm other players' computers and servers: scripts that wipe disks, download and run unknown
-- code, copy themselves to floppies, switch off Ctrl+T, steal passwords or flood the network.
--   local result = av.scanData(text, { path = "/disk/startup.lua" })    -- result.verdict is "clean", "suspicious" or "malicious"; result.findings tells why
--   local summary = av.scanTree("/", { action = "quarantine" })
-- Three layers: (1) the checksum of the whole file against lists of known bad (and known good) files, (2) signature patterns from the definitions, (3) behaviour
-- rules (tsr.av.rules). Lists can be updated from signed definition files (tsr.av.defs). Other programs use it too: the package manager can scan what it installs
-- (config av.scan_packages), the mail server scans attachments (av.installMail), and the avd service scans floppies when they are inserted.
local hash = require("tsr.hash")
local vfs = require("tsr.vfs")
local rules = require("tsr.av.rules")
local defsMod = require("tsr.av.defs")

local M = {}

M.CONFIG = "/etc/tsr/av/av.json"
M.LOG = "/var/log/av.log"
M.DEFAULTS = { suspicious_at = 5, malicious_at = 10, max_size = 262144, action = "report", scan_disks = true, scan_packages = false, watch = {}, sources = {}, update_hours = 24 }

M.rules, M.defs = rules, defsMod

--- The settings: defaults plus /etc/tsr/av/av.json.
function M.settings()
  local s = {}
  for k, v in pairs(M.DEFAULTS) do s[k] = v end
  local text = vfs.readFile(M.CONFIG)
  if text then
    local ok, t = pcall(textutils.unserializeJSON, text)
    if ok and type(t) == "table" then for k, v in pairs(t) do s[k] = v end end
  end
  return s
end

function M.saveSettings(s)
  vfs.mkdirp("/etc/tsr/av")
  return vfs.writeFile(M.CONFIG, textutils.serializeJSON(s))
end

local cachedDefs, cachedAt
--- The merged definitions (cached for a minute).
function M.loadDefs(force)
  local now = os.clock()
  if force or not cachedDefs or now - cachedAt > 60 then
    cachedDefs, cachedAt = defsMod.load(), now
  end
  return cachedDefs
end

local function verdictFor(score, s)
  if score >= s.malicious_at then return "malicious" end
  if score >= s.suspicious_at then return "suspicious" end
  return "clean"
end

local function isBinary(data)
  return data:sub(1, 512):find("\0", 1, true) ~= nil
end

local function extOf(path)
  return ((path or ""):lower():match("%.([%w]+)$"))
end

--- Scan text. opts: path (the name the file will have; used for startup files), defs, settings.
--- Returns { verdict, score, findings = { { id, score, description, line } }, sha256, size, skipped, allowed }.
function M.scanData(data, opts)
  opts = opts or {}
  local s = opts.settings or M.settings()
  local defs = opts.defs or M.loadDefs()
  local sha = hash.sha256(data)
  local r = { verdict = "clean", score = 0, findings = {}, sha256 = sha, size = #data }
  if defs.allow[sha] then r.allowed = defs.allow[sha] return r end
  if defs.hashes[sha] then
    r.findings[#r.findings + 1] = { id = "KNOWN:" .. defs.hashes[sha], score = 100, description = "a file that is on the list of known malware" }
  end
  if data:find(rules.TEST_STRING, 1, true) then
    r.findings[#r.findings + 1] = { id = "TEST_FILE", score = 100, description = "the standard anti-virus test file (harmless)" }
  end
  for _, p in ipairs(defs.patterns) do
    local ok, found = pcall(string.find, data, p.pattern, 1, p.plain and true or false)
    if ok and found then r.findings[#r.findings + 1] = { id = p.id, score = p.score or 10, description = p.name or p.id } end
  end
  if isBinary(data) then
    r.skipped = "binary"
  elseif #data > s.max_size then
    r.skipped = "too large"
  elseif opts.kind == "lua" or extOf(opts.path) == "lua" or (opts.kind ~= "data" and rules.looksLikeLua(data)) then
    local code = rules.strip(data)
    local found, _ = rules.run(code, opts.path)
    for _, f in ipairs(found) do r.findings[#r.findings + 1] = f end
  else
    r.skipped = "not a program"
  end
  local score = 0
  for _, f in ipairs(r.findings) do score = score + f.score end
  r.score = score
  r.verdict = verdictFor(score, s)
  return r
end

--- Scan a file. Returns the same table (plus path) or nil + reason.
function M.scanFile(path, opts)
  opts = opts or {}
  local data = vfs.readFile(vfs.normalize(path), true)
  if not data then return nil, "cannot read " .. path end
  local o = {}
  for k, v in pairs(opts) do o[k] = v end
  o.path = o.path or path
  local r = M.scanData(data, o)
  r.path = path
  return r
end

--- path -> sha256 of the files that belong to installed packages (the package manager's records).
function M.knownFiles()
  local known = {}
  local okD, db = pcall(require, "tsr.pkg.db")
  if not okD then return known end
  for _, name in ipairs(db.names()) do
    local rec = db.get(name)
    for _, f in ipairs(rec and rec.files or {}) do known[f.path] = f.sha256 end
  end
  return known
end

local SKIP = { ["/rom"] = true, ["/var/lib/tsr/av"] = true, ["/var/cache/tsr"] = true, ["/tmp"] = false }

local function log(line)
  vfs.mkdirp("/var/log")
  local h = fs.open(M.LOG, "a")
  if h then h.writeLine(("%.0f %s"):format(os.epoch and os.epoch("utc") / 1000 or os.clock(), line)) h.close() end
end
M.log = log

--- Scan a file or folder. opts: action ("report" | "quarantine" | "delete"), recursive (default true), progress(path, result), skipKnown (default true), settings.
--- Returns { scanned, clean, suspicious, malicious, skipped, errors, found = { result... } }.
function M.scanTree(root, opts)
  opts = opts or {}
  local s = opts.settings or M.settings()
  local action = opts.action or s.action
  local summary = { scanned = 0, clean = 0, suspicious = 0, malicious = 0, skipped = 0, known = 0, errors = 0, found = {} }
  local known = (opts.skipKnown ~= false) and M.knownFiles() or {}
  local q = require("tsr.av.quarantine")
  local defs = M.loadDefs()
  local function visit(path, depth)
    if depth > 24 then return end
    if SKIP[path] then return end
    if vfs.fs.isDir(path) then
      if opts.recursive == false and depth > 0 then return end
      local okL, list = pcall(vfs.fs.list, path)
      if not okL then summary.errors = summary.errors + 1 return end
      table.sort(list)
      for _, name in ipairs(list) do visit((path == "/" and "" or path) .. "/" .. name, depth + 1) end
      return
    end
    local size = vfs.fs.getSize(path)
    if known[path] and opts.skipKnown ~= false then
      -- an installed package file: it is fine as long as it still has the checksum of the installed version
      local data = (size <= s.max_size) and vfs.readFile(path, true)
      if data and hash.sha256(data) == known[path] then summary.known = summary.known + 1 return end
    end
    local r, err = M.scanFile(path, { settings = s, defs = defs })
    if not r then summary.errors = summary.errors + 1 return end
    summary.scanned = summary.scanned + 1
    if r.skipped and r.verdict == "clean" then summary.skipped = summary.skipped + 1 end
    summary[r.verdict] = summary[r.verdict] + 1
    if r.verdict ~= "clean" then
      summary.found[#summary.found + 1] = r
      local ids = {}
      for _, f in ipairs(r.findings) do ids[#ids + 1] = f.id end
      log(("%s %s (score %d: %s)"):format(r.verdict, path, r.score, table.concat(ids, ",")))
      if r.verdict == "malicious" and action == "quarantine" then
        local id, why = q.add(path, r)
        r.quarantined = id
        r.quarantineError = not id and why or nil
      elseif r.verdict == "malicious" and action == "delete" then
        vfs.fs.delete(path)
        r.deleted = true
      end
    end
    if opts.progress then opts.progress(path, r) end
  end
  root = vfs.normalize(root)
  if vfs.fs.exists(root) then visit(root, 0) end
  return summary
end

--- Does this scan result mean the file should be refused? (malicious always; suspicious when strict.)
function M.blocks(result, strict)
  return result.verdict == "malicious" or (strict and result.verdict == "suspicious")
end

--- A one-line explanation of a result.
function M.describe(r)
  local ids = {}
  for _, f in ipairs(r.findings) do ids[#ids + 1] = f.id .. (f.line and (" (line " .. f.line .. ")") or "") end
  if #ids == 0 then return r.allowed and ("known good: " .. r.allowed) or "clean" end
  return ("%s, score %d: %s"):format(r.verdict, r.score, table.concat(ids, ", "))
end

---------------------------------------------------------------------------------------------------------------------
-- Mail
---------------------------------------------------------------------------------------------------------------------

local msg_ok, msg = pcall(require, "tsr.mail.message")

local function scanMessage(raw, s)
  local defs = M.loadDefs()
  local m = msg.parse(raw)
  local worst, worstName = nil, nil
  local function consider(r, name)
    r.name = name
    if not worst or r.score > worst.score then worst, worstName = r, name end
  end
  for _, a in ipairs(m:attachments()) do
    if #a.data <= s.max_size * 2 then
      -- only the file name counts (a path in the name must not make the file look like part of the system)
      local name = tostring(a.name or "attachment"):match("([^/\\]+)$") or "attachment"
      consider(M.scanData(a.data, { path = name, settings = s, defs = defs }), name)
    end
  end
  -- program text pasted into the message body
  local text = m:text()
  if #text > 200 and rules.looksLikeLua(text) then consider(M.scanData(text, { kind = "lua", settings = s, defs = defs }), "message text") end
  return worst, defs
end

--- Hook the scanner into a mail system (see tsr.mail): incoming mail with malware is refused, doubtful mail goes to the Spam folder with a header, and users cannot
--- send malware out. cfg: action ("reject" | "quarantine" | "tag").
function M.installMail(mail, cfg)
  if not msg_ok then return nil, "the mail package is not installed" end
  cfg = cfg or {}
  local s = M.settings()
  mail:addFilter("av", function(ctx)
    local worst, defs = scanMessage(ctx.raw, s)
    ctx.add[#ctx.add + 1] = "X-Virus-Scanned: tessera-av " .. tostring(defs.version)
    if not worst or worst.verdict == "clean" then
      ctx.add[#ctx.add + 1] = "X-Virus-Status: Clean"
      return nil
    end
    local ids = {}
    for _, f in ipairs(worst.findings) do ids[#ids + 1] = f.id end
    local label = ("%s in %s (%s)"):format(worst.verdict, worst.name, table.concat(ids, ","))
    ctx.add[#ctx.add + 1] = "X-Virus-Status: " .. (worst.verdict == "malicious" and "Infected" or "Suspicious") .. " - " .. label
    mail.stats.virus = (mail.stats.virus or 0) + 1
    if worst.verdict == "malicious" and cfg.action ~= "tag" then
      mail:note("virus refused from " .. tostring(ctx.ip) .. ": " .. label)
      if cfg.action == "quarantine" then return { "spam", "virus: " .. label, 100 } end
      return { "reject", 554, "5.7.1 The message contains malware: " .. label }
    end
    return { "spam", "virus-suspect: " .. label, worst.score }
  end, 20)
  mail:addOutboundFilter("av", function(ctx)
    local worst = scanMessage(ctx.raw, s)
    if worst and worst.verdict == "malicious" then
      local ids = {}
      for _, f in ipairs(worst.findings) do ids[#ids + 1] = f.id end
      return { "reject", 554, ("5.7.1 Not sent: %s looks like malware (%s)"):format(worst.name, table.concat(ids, ",")) }
    end
    return nil
  end)
  mail.av = M
  return true
end

return M
