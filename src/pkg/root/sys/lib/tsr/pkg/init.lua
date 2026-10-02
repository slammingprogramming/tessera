-- SPDX-License-Identifier: AGPL-3.0-or-later
-- tsr.pkg: the package manager API used by the `pkg` command, the installer wizard and lazy stubs.
local db = require("tsr.pkg.db")
local source = require("tsr.pkg.source")
local resolve = require("tsr.pkg.resolve")
local install = require("tsr.pkg.install")
local semver = require("tsr.pkg.semver")
local hash = require("tsr.hash")
local vfs = require("tsr.vfs")
local bundle = require("tsr.bundle")

local P = { db = db, source = source, semver = semver, install = install, resolve = resolve }

---------------------------------------------------------------------------------------------------------------------
-- Queries
---------------------------------------------------------------------------------------------------------------------

--- Refresh the cached registry indexes. Returns { [source] = true | error }.
function P.update() return source.update() end

--- Packages whose name or description contains `query` (case-insensitive). Sorted array of { name, entry, installed }.
function P.search(query)
  query = (query or ""):lower()
  local out = {}
  for name, entry in pairs(source.allPackages()) do
    local tagHit = false
    for _, t in ipairs(entry.tags or {}) do if t:lower():find(query, 1, true) then tagHit = true end end
    if query == "" or tagHit or name:lower():find(query, 1, true) or (entry.description or ""):lower():find(query, 1, true) then
      local rec = db.get(name)
      out[#out + 1] = { name = name, entry = entry, installed = rec and rec.version or nil }
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

--- Details for one package: { doc, source, latest, manifest, installed }.
function P.info(name)
  local doc, src = source.findPackage(name)
  local rec = db.get(name)
  if not doc and not rec then return nil, "package not found: " .. name end
  local info = { name = name, installed = rec, source = src and src.name }
  if doc then
    info.doc = doc
    info.latest = semver.best((function()
      local v = {}
      for k in pairs(doc.versions) do v[#v + 1] = k end
      return v
    end)(), "*")
    info.manifest = doc.versions[info.latest]
  end
  return info
end

--- Installed packages: sorted array of { name, record }.
function P.list()
  local out = {}
  for _, name in ipairs(db.names()) do out[#out + 1] = { name = name, record = db.get(name) } end
  return out
end

---------------------------------------------------------------------------------------------------------------------
-- Planning and installing
---------------------------------------------------------------------------------------------------------------------

local function makeCtx()
  local sourceOf = {}
  local docs = {}
  local why = {}
  local all
  return {
    sourceOf = sourceOf,
    why = why,
    installed = db.get,
    installedProvider = db.provider,
    lookup = function(name)
      if docs[name] ~= nil then return docs[name] or nil end
      local doc, src = source.findPackage(name)
      docs[name] = doc or false
      if doc then sourceOf[name] = src.name else why[name] = src end
      return doc
    end,
    providers = function(virt)
      all = all or source.allPackages()
      local out = {}
      for name, entry in pairs(all) do
        for _, p in ipairs(entry.provides or {}) do
          if p == virt then out[#out + 1] = name end
        end
      end
      table.sort(out)
      return out
    end,
  }
end

--- Resolve `requests` ("name" or "name@range") into an install plan. Returns plan or nil, errors.
function P.plan(requests, opts)
  local ctx = makeCtx()
  local plan, errs = resolve.plan(requests, ctx, opts)
  if plan then
    for _, e in ipairs(plan) do e.source = ctx.sourceOf[e.name] end
  end
  return plan, errs
end

--- Install packages. opts: dry (return the plan only), upgrade, reinstall, lazy, progress, keepCache.
--- Returns true (or the plan when dry), or nil + message.
function P.installPackages(requests, opts)
  opts = opts or {}
  local plan, errs = P.plan(requests, opts)
  if not plan then return nil, table.concat(errs, "\n") end
  if opts.dry then return plan end
  if #plan == 0 then return true, plan end
  local ok, err = install.apply(plan, opts)
  if not ok then return nil, err end
  return true, plan
end

--- Upgrade everything installed (or just `names`). opts as for installPackages.
function P.upgrade(names, opts)
  opts = opts or {}
  opts.upgrade = true
  if not names or #names == 0 then
    names = {}
    for _, n in ipairs(db.names()) do
      if not db.get(n).lazy then names[#names + 1] = n end
    end
  end
  return P.installPackages(names, opts)
end

function P.remove(names, opts) return install.remove(names, opts) end

--- Make sure a package is really installed (used by lazy stubs). Returns true or nil, err.
function P.ensure(name, opts)
  local rec = db.get(name)
  if rec and not rec.lazy then return true end
  opts = opts or {}
  if rec and rec.lazy then opts.reinstall = true end
  local ok, err = P.installPackages({ name }, opts)
  if not ok then return nil, err end
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- Integrity, maintenance, offline import
---------------------------------------------------------------------------------------------------------------------

--- Check installed files against the database. Returns array of { package, path, problem }.
function P.verify(name)
  local problems = {}
  local names = name and { name } or db.names()
  for _, n in ipairs(names) do
    local rec = db.get(n)
    if rec then
      for _, f in ipairs(rec.files or {}) do
        if not fs.exists(f.path) then
          problems[#problems + 1] = { package = n, path = f.path, problem = "missing" }
        else
          local data = vfs.readFile(f.path, true)
          if hash.sha256(data) ~= f.sha256 then
            problems[#problems + 1] = { package = n, path = f.path, problem = "modified" }
          end
        end
      end
    end
  end
  return problems
end

--- Free space: remove the staging area, offline store and (with `all`) the registry cache.
function P.clean(all)
  source.clean(all)
  if fs.exists(install.stageDir) then fs.delete(install.stageDir) end
end

--- Repair an interrupted transaction (call early at boot).
function P.recover() return install.recover() end

--- Import an offline bundle: `data` is file content (TSRZ file or text of TSR1 lines) or an assembler from
--- tsr.bundle.newAssembler(). Returns { packages = n, blobs = n } or nil, err.
function P.importBundle(data)
  local b, err
  if type(data) == "string" then b, err = bundle.parse(data)
  elseif data.blobs then b = data                  -- an already parsed bundle
  else b, err = data:result() end                  -- a tsr.bundle assembler
  if not b then return nil, err end
  return source.importBundle(b)
end

return P
