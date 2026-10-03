-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Transactional install/remove.
--   1. every payload is fetched, verified (SHA-256) and staged in /var/cache/tsr/stage — nothing else is touched yet
--   2. a journal is written, then staged files are moved into place (fs.move costs no extra space); replaced files are
--      first moved aside to <path>.tsr-old
--   3. the package database is saved, the journal is marked done, old files are removed
-- A crash or failure before step 3 rolls everything back (M.recover() at boot); after it, cleanup is finished.
-- Files that existed before and are not owned by any package (e.g. the user's own startup.lua) are kept in
-- /etc/tsr/backup/ rather than deleted.
local hash = require("tsr.hash")
local vfs = require("tsr.vfs")
local db = require("tsr.pkg.db")
local source = require("tsr.pkg.source")
local config = require("tsr.config")
local log = require("tsr.log").get("pkg")

local M = {}

M.stageDir = "/var/cache/tsr/stage"
M.journalPath = "/var/lib/tsr/pkg/txn.json"
M.backupDir = "/etc/tsr/backup"

local PROTECTED = { ["/"] = true, ["/sys"] = true, ["/usr"] = true, ["/etc"] = true, ["/var"] = true, ["/home"] = true,
                    ["/mnt"] = true, ["/tmp"] = true, ["/rom"] = true }

local function emit(opts, ...)
  if opts and opts.progress then pcall(opts.progress, ...) end
end

local function rawWrite(path, data)
  vfs.mkdirp(vfs.dirname(path))
  local h, err = fs.open(path, "wb")
  if not h then return false, err end
  h.write(data)
  h.close()
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- Planning helpers
---------------------------------------------------------------------------------------------------------------------

--- Net bytes a plan adds to the disk (replaced files are subtracted).
function M.spaceNeeded(plan)
  local need = 0
  for _, e in ipairs(plan) do
    local old = db.get(e.name)
    local oldSize = {}
    if old then
      for _, f in ipairs(old.files or {}) do oldSize[f.path] = f.size or 0 end
    end
    for _, f in ipairs(e.manifest.files or {}) do need = need + (f.size or 0) - (oldSize[f.path] or 0) end
  end
  return need
end

local function checkPlan(plan)
  local claimed = {}
  local inPlan = {}
  for _, e in ipairs(plan) do inPlan[e.name] = true end
  for _, e in ipairs(plan) do
    for _, f in ipairs(e.manifest.files or {}) do
      if not f.path or f.path:sub(1, 1) ~= "/" or f.path:find("..", 1, true) then
        return nil, e.name .. ": unsafe file path " .. tostring(f.path)
      end
      if f.path:sub(1, 5) == "/rom/" or f.path == "/rom" then return nil, e.name .. ": may not write to /rom" end
      if claimed[f.path] then return nil, ("%s and %s both install %s"):format(claimed[f.path], e.name, f.path) end
      claimed[f.path] = e.name
      local owner = db.owner(f.path)
      if owner and owner ~= e.name and not inPlan[owner] then
        return nil, ("%s: %s is owned by package %s"):format(e.name, f.path, owner)
      end
      if fs.isDir(f.path) then return nil, e.name .. ": " .. f.path .. " is a directory" end
    end
  end
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- Journal / rollback / cleanup
---------------------------------------------------------------------------------------------------------------------

local function writeJournal(j) return vfs.writeJSON(M.journalPath, j) end

local function rollback(j)
  for i = #j.files, 1, -1 do
    local f = j.files[i]
    local old = f.path .. ".tsr-old"
    if f.existed then
      if fs.exists(old) then
        if fs.exists(f.path) then fs.delete(f.path) end
        fs.move(old, f.path)
      end
    elseif fs.exists(f.path) then
      fs.delete(f.path)
    end
  end
  if fs.exists(M.stageDir) then fs.delete(M.stageDir) end
  if fs.exists(M.journalPath) then fs.delete(M.journalPath) end
end

local function pruneEmptyDirs(path)
  local dir = vfs.dirname(path)
  while dir ~= "/" and not PROTECTED[dir] and fs.isDir(dir) and #fs.list(dir) == 0 do
    fs.delete(dir)
    dir = vfs.dirname(dir)
  end
end

local function finishCleanup(j)
  for _, f in ipairs(j.files or {}) do
    local old = f.path .. ".tsr-old"
    if fs.exists(old) then
      if f.backup then
        local dest = M.backupDir .. f.path
        vfs.mkdirp(vfs.dirname(dest))
        if fs.exists(dest) then fs.delete(dest) end
        fs.move(old, dest)
      else
        fs.delete(old)
      end
    end
  end
  for _, path in ipairs(j.obsolete or {}) do
    if fs.exists(path) and not fs.isDir(path) then
      fs.delete(path)
      pruneEmptyDirs(path)
    end
  end
  if fs.exists(M.stageDir) then fs.delete(M.stageDir) end
  if fs.exists(M.journalPath) then fs.delete(M.journalPath) end
end

--- Repair an interrupted transaction. Returns "rolled back", "finished" or nil (nothing to do).
function M.recover()
  local j = vfs.readJSON(M.journalPath)
  if not j then return nil end
  if j.phase == "done" then
    finishCleanup(j)
    log.info("finished an interrupted package transaction")
    return "finished"
  end
  if j.phase == "commit" then
    rollback(j)
    log.warn("rolled back an interrupted package transaction")
    return "rolled back"
  end
  if fs.exists(M.stageDir) then fs.delete(M.stageDir) end
  fs.delete(M.journalPath)
  return "rolled back"
end

---------------------------------------------------------------------------------------------------------------------
-- Hooks
---------------------------------------------------------------------------------------------------------------------

local function runHook(entry, hookName)
  local hooks = entry.manifest.hooks
  local path = hooks and hooks[hookName]
  if not path or not fs.exists(path) then return end
  local chunk, err = loadfile(path, "t", require("tsr.loader").env)
  if not chunk then return log.warn("%s hook of %s: %s", hookName, entry.name, tostring(err)) end
  local ok, e = pcall(chunk, entry.name, entry.version, entry.action)
  if not ok then log.warn("%s hook of %s failed: %s", hookName, entry.name, tostring(e)) end
end

---------------------------------------------------------------------------------------------------------------------
-- Lazy stubs
---------------------------------------------------------------------------------------------------------------------

local function isExecutable(path)
  return path:sub(1, 9) == "/usr/bin/" or path:sub(1, 9) == "/sys/bin/"
end

local function stubFor(name, path)
  return table.concat({
    "-- tessera lazy stub for package '" .. name .. "': installs it on first run, then runs the real program",
    "local pkg = (rawget(_G, 'tsr') and tsr.require or require)('tsr.pkg')",
    "local ok, err = pkg.ensure('" .. name .. "')",
    "if not ok then printError('cannot install " .. name .. ": ' .. tostring(err)) return end",
    "os.run(setmetatable({ shell = shell, multishell = multishell }, { __index = _G }), '" .. path .. "', ...)",
    "",
  }, "\n")
end

---------------------------------------------------------------------------------------------------------------------
-- Apply a plan
---------------------------------------------------------------------------------------------------------------------

--- plan: array from resolve.plan. opts: progress(event, ...), lazy (bool: install stubs only), keepCache (bool)
--- Returns true, or nil + error message.
function M.apply(plan, opts)
  opts = opts or {}
  if fs.exists(M.journalPath) then M.recover() end
  local okPlan, perr = checkPlan(plan)
  if not okPlan then return nil, perr end

  local margin = config.get("pkg.free_margin", 8192)
  local need = M.spaceNeeded(plan)
  local free = require("tsr.util").freeSpace()
  if not opts.lazy and need + margin > free then
    return nil, ("not enough disk space: need %.0f bytes (+%.0f margin), %.0f free"):format(need, margin, free)
  end

  -- 1. stage payloads ------------------------------------------------------------------------------------------------
  local staged, uses = {}, {}
  local total, done = 0, 0
  if not opts.lazy then
    for _, e in ipairs(plan) do total = total + #(e.manifest.files or {}) end
  end
  local function fail(msg)
    if fs.exists(M.stageDir) then fs.delete(M.stageDir) end
    return nil, msg
  end

  local files = {} -- flat list of { entry, file }
  if not opts.lazy then
    for _, e in ipairs(plan) do
      for _, f in ipairs(e.manifest.files or {}) do
        files[#files + 1] = { entry = e, file = f }
        uses[f.sha256] = (uses[f.sha256] or 0) + 1
      end
    end
    for _, item in ipairs(files) do
      local f = item.file
      done = done + 1
      emit(opts, "fetch", item.entry.name, f.path, done, total)
      if not staged[f.sha256] then
        local data, err = source.getBlob(f.sha256, item.entry.source)
        if not data then return fail(("%s: cannot fetch %s: %s"):format(item.entry.name, f.path, tostring(err))) end
        if #data ~= f.size then return fail(item.entry.name .. ": size mismatch for " .. f.path) end
        -- the anti-virus (if installed and switched on with `av config set scan_packages=true`) looks at what is about to be installed
        local okAv, av = pcall(require, "tsr.av")
        if okAv and av.settings().scan_packages then
          local r = av.scanData(data, { path = f.path })
          if r.verdict == "malicious" then return fail(("%s: %s was blocked by the anti-virus (%s)"):format(item.entry.name, f.path, av.describe(r))) end
          if r.verdict == "suspicious" then log.warn("%s", ("%s: %s looks suspicious (%s)"):format(item.entry.name, f.path, av.describe(r))) end
        end
        local wok, werr = rawWrite(M.stageDir .. "/" .. f.sha256, data)
        if not wok then return fail("cannot stage " .. f.path .. ": " .. tostring(werr)) end
        staged[f.sha256] = true
      end
    end
  else
    for _, e in ipairs(plan) do
      for _, f in ipairs(e.manifest.files or {}) do
        if isExecutable(f.path) then
          local stub = stubFor(e.name, f.path)
          local sha = hash.sha256(stub)
          files[#files + 1] = { entry = e, file = { path = f.path, sha256 = sha, size = #stub }, stub = stub }
        end
      end
    end
  end

  -- 2. commit -------------------------------------------------------------------------------------------------------------
  local journal = { phase = "commit", files = {}, obsolete = {} }
  local newPaths = {}
  for _, item in ipairs(files) do
    local path = item.file.path
    newPaths[path] = true
    local existed = fs.exists(path)
    local owned = existed and db.owner(path) ~= nil
    journal.files[#journal.files + 1] = { path = path, existed = existed, backup = existed and not owned or nil }
  end
  for _, e in ipairs(plan) do
    local old = db.get(e.name)
    if old then
      for _, f in ipairs(old.files or {}) do
        if not newPaths[f.path] then journal.obsolete[#journal.obsolete + 1] = f.path end
      end
    end
  end
  local jok, jerr = writeJournal(journal)
  if not jok then return fail("cannot write journal: " .. tostring(jerr)) end
  emit(opts, "commit", #files)

  local remaining = {}
  for sha, n in pairs(uses) do remaining[sha] = n end
  local cok, cerr = pcall(function()
    for _, item in ipairs(files) do
      local path = item.file.path
      vfs.mkdirp(vfs.dirname(path))
      if fs.exists(path) then fs.move(path, path .. ".tsr-old") end
      if item.stub then
        local h = fs.open(path, "w")
        h.write(item.stub)
        h.close()
      else
        local sha = item.file.sha256
        local stagePath = M.stageDir .. "/" .. sha
        remaining[sha] = remaining[sha] - 1
        if remaining[sha] > 0 then fs.copy(stagePath, path) else fs.move(stagePath, path) end
      end
    end
  end)
  if not cok then
    rollback(journal)
    return nil, "install failed and was rolled back: " .. tostring(cerr)
  end

  -- 3. database, then cleanup --------------------------------------------------------------------------------------------
  local now = os.epoch and os.epoch("utc") or 0
  local before = {}
  for _, e in ipairs(plan) do
    before[e.name] = db.get(e.name)
    local recFiles = {}
    for _, item in ipairs(files) do
      if item.entry == e then recFiles[#recFiles + 1] = { path = item.file.path, sha256 = item.file.sha256, size = item.file.size } end
    end
    db.set(e.name, {
      version = e.version, reason = e.reason, files = recFiles, requires = e.manifest.requires,
      provides = e.manifest.provides, lazy = opts.lazy or nil, time = now,
      license = e.manifest.license, source = e.manifest.source,
    })
  end
  local sok, serr = db.save()
  if not sok then
    for name, rec in pairs(before) do db.set(name, rec) end
    for _, e in ipairs(plan) do if not before[e.name] then db.remove(e.name) end end
    rollback(journal)
    return nil, "cannot save package database: " .. tostring(serr)
  end
  journal.phase = "done"
  writeJournal(journal)
  finishCleanup(journal)
  if not opts.lazy then
    for _, e in ipairs(plan) do runHook(e, "post_install") end
  end
  if not (opts.keepCache or config.get("pkg.keep_cache", false)) then source.clean() end
  emit(opts, "done", #plan)
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- Remove
---------------------------------------------------------------------------------------------------------------------

--- Remove installed packages. opts.force skips the reverse-dependency and `core` checks.
function M.remove(names, opts)
  opts = opts or {}
  local removing = {}
  for _, n in ipairs(names) do
    if not db.get(n) then return nil, n .. " is not installed" end
    removing[n] = true
  end
  if not opts.force then
    for _, n in ipairs(names) do
      if n == "core" then return nil, "refusing to remove core (use --force)" end
      for _, dep in ipairs(db.dependents(n)) do
        if not removing[dep] then return nil, ("%s is required by %s"):format(n, dep) end
      end
    end
  end
  for _, n in ipairs(names) do
    local rec = db.get(n)
    for _, f in ipairs(rec.files or {}) do
      if fs.exists(f.path) and not fs.isDir(f.path) then
        fs.delete(f.path)
        pruneEmptyDirs(f.path)
      end
    end
    db.remove(n)
    emit(opts, "removed", n)
  end
  local ok, err = db.save()
  if not ok then return nil, tostring(err) end
  return true
end

return M
