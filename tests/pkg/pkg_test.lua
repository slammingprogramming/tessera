-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Integration tests for the package manager against a registry laid out in a plain directory (type "dir").
local pkg = require("tsr.pkg")
local db = require("tsr.pkg.db")
local source = require("tsr.pkg.source")
local install = require("tsr.pkg.install")
local config = require("tsr.config")
local hash = require("tsr.hash")
local vfs = require("tsr.vfs")

local REG = "/tmp-reg"
local ROOT = "/tmp-pkgtest"

local function reset()
  for _, p in ipairs({ REG, ROOT, "/tmp-state", "/etc/tsr/backup" .. ROOT }) do
    if fs.exists(p) then fs.delete(p) end
  end
  db.path = "/tmp-state/db.json"
  db.reload()
  install.stageDir = "/tmp-state/stage"
  install.journalPath = "/tmp-state/txn.json"
  install.backupDir = "/tmp-state/backup"
  source.cacheDir = "/tmp-state/cache"
  source.offlineDir = "/tmp-state/cache/offline"
  config.reset()
  config.set("pkg.sources", { { name = "test", type = "dir", path = REG } }, "user")
end

--- pkgs: { name = { version=, requires=, provides=, conflicts=, files = { [path] = content }, hooks = {...} } }
--- (several versions: list of specs under `versions`)
local function publish(pkgs)
  local index = { format = 1, packages = {} }
  for name, spec in pairs(pkgs) do
    local doc = { name = name, versions = {} }
    local specs = spec.versions or { spec }
    for _, s in ipairs(specs) do
      local files = {}
      for path, content in pairs(s.files or {}) do
        local sha = hash.sha256(content)
        vfs.writeFile(REG .. "/blobs/" .. sha, content, true)
        files[#files + 1] = { path = path, sha256 = sha, size = #content }
      end
      table.sort(files, function(a, b) return a.path < b.path end)
      doc.versions[s.version] = {
        format = 1, name = name, version = s.version, type = "lib", description = s.description or (name .. " package"),
        requires = s.requires or {}, provides = s.provides or {}, conflicts = s.conflicts or {},
        license = "AGPL-3.0-or-later", files = files, hooks = s.hooks,
        size = { installed = 0 },
      }
      doc.latest = s.version
    end
    vfs.writeJSON(REG .. "/registry/packages/" .. name .. ".json", doc)
    index.packages[name] = { version = doc.latest, type = "lib", description = doc.versions[doc.latest].description,
                             provides = specs[#specs].provides }
  end
  vfs.writeJSON(REG .. "/registry/index.json", index)
end

local function read(path) return vfs.readFile(path) end

test("install pulls in dependencies and records ownership", function()
  reset()
  publish({
    app = { version = "1.0.0", requires = { lib = "^1.0" }, files = { [ROOT .. "/bin/app.lua"] = "print('app')" } },
    lib = { version = "1.2.0", files = { [ROOT .. "/lib/lib.lua"] = "return 1", [ROOT .. "/lib/extra.lua"] = "return 2" } },
  })
  local done, plan = pkg.installPackages({ "app" })
  ok(done, tostring(plan))
  eq(#plan, 2)
  eq(read(ROOT .. "/bin/app.lua"), "print('app')")
  eq(read(ROOT .. "/lib/lib.lua"), "return 1")
  eq(db.get("app").reason, "manual")
  eq(db.get("lib").reason, "auto")
  eq(db.get("lib").version, "1.2.0")
  eq((db.owner(ROOT .. "/lib/extra.lua")), "lib")
  eq(pkg.verify(), {})
  ok(not fs.exists(install.stageDir), "stage dir must be cleaned")
  ok(not fs.exists(install.journalPath), "journal must be removed")
end)

test("dry run changes nothing", function()
  reset()
  publish({ a = { version = "1.0.0", files = { [ROOT .. "/a.lua"] = "x" } } })
  local plan = pkg.installPackages({ "a" }, { dry = true })
  eq(#plan, 1)
  ok(not fs.exists(ROOT .. "/a.lua"))
  eq(db.names(), {})
end)

test("upgrade replaces changed files and removes obsolete ones", function()
  reset()
  publish({ a = { versions = {
    { version = "1.0.0", files = { [ROOT .. "/a/old.lua"] = "old", [ROOT .. "/a/keep.lua"] = "keep-1" } },
  } } })
  ok(pkg.installPackages({ "a" }))
  publish({ a = { versions = {
    { version = "1.0.0", files = { [ROOT .. "/a/old.lua"] = "old", [ROOT .. "/a/keep.lua"] = "keep-1" } },
    { version = "1.1.0", files = { [ROOT .. "/a/keep.lua"] = "keep-2", [ROOT .. "/a/new.lua"] = "new" } },
  } } })
  local ok2, plan = pkg.upgrade()
  ok(ok2, tostring(plan))
  eq(plan[1].action, "upgrade")
  eq(read(ROOT .. "/a/keep.lua"), "keep-2")
  eq(read(ROOT .. "/a/new.lua"), "new")
  ok(not fs.exists(ROOT .. "/a/old.lua"), "obsolete file should be removed")
  ok(not fs.exists(ROOT .. "/a/keep.lua.tsr-old"))
  eq(db.get("a").version, "1.1.0")
  -- nothing left to do
  local _, plan2 = pkg.upgrade()
  eq(#plan2, 0)
end)

test("a corrupted payload aborts the install without touching the system", function()
  reset()
  publish({ a = { version = "1.0.0", files = { [ROOT .. "/a.lua"] = "good" } } })
  local sha = hash.sha256("good")
  vfs.writeFile(REG .. "/blobs/" .. sha, "evil", true)
  local ok2, err = pkg.installPackages({ "a" })
  ok(ok2 == nil and err:find("cannot fetch"), tostring(err))
  ok(not fs.exists(ROOT .. "/a.lua"))
  eq(db.names(), {})
  ok(not fs.exists(install.stageDir))
end)

test("a failure while committing rolls everything back", function()
  reset()
  fs.makeDir(ROOT)
  vfs.writeFile(ROOT .. "/existing.lua", "ORIGINAL")
  vfs.writeFile(ROOT .. "/blocker", "i am a file")
  publish({ a = { version = "1.0.0", files = {
    [ROOT .. "/existing.lua"] = "REPLACED",
    [ROOT .. "/zz/first.lua"] = "1",
    [ROOT .. "/blocker/child.lua"] = "cannot create: parent is a file",
  } } })
  local ok2, err = pkg.installPackages({ "a" })
  ok(ok2 == nil and err:find("rolled back"), tostring(err))
  eq(read(ROOT .. "/existing.lua"), "ORIGINAL")
  ok(not fs.exists(ROOT .. "/existing.lua.tsr-old"))
  ok(not fs.exists(ROOT .. "/zz/first.lua"))
  eq(db.names(), {})
  ok(not fs.exists(install.journalPath))
end)

test("recover() rolls back an interrupted commit", function()
  reset()
  fs.makeDir(ROOT)
  vfs.writeFile(ROOT .. "/f.lua", "NEW-PARTIAL")
  vfs.writeFile(ROOT .. "/f.lua.tsr-old", "ORIGINAL")
  vfs.writeFile(ROOT .. "/created.lua", "half")
  vfs.writeJSON(install.journalPath, { phase = "commit", obsolete = {}, files = {
    { path = ROOT .. "/f.lua", existed = true }, { path = ROOT .. "/created.lua", existed = false } } })
  eq(pkg.recover(), "rolled back")
  eq(read(ROOT .. "/f.lua"), "ORIGINAL")
  ok(not fs.exists(ROOT .. "/created.lua"))
  ok(not fs.exists(install.journalPath))
  eq(pkg.recover(), nil)
end)

test("recover() finishes cleanup of a completed commit", function()
  reset()
  fs.makeDir(ROOT)
  vfs.writeFile(ROOT .. "/f.lua", "NEW")
  vfs.writeFile(ROOT .. "/f.lua.tsr-old", "OLD")
  vfs.writeFile(ROOT .. "/gone.lua", "obsolete")
  vfs.writeJSON(install.journalPath, { phase = "done", obsolete = { ROOT .. "/gone.lua" },
    files = { { path = ROOT .. "/f.lua", existed = true } } })
  eq(pkg.recover(), "finished")
  eq(read(ROOT .. "/f.lua"), "NEW")
  ok(not fs.exists(ROOT .. "/f.lua.tsr-old") and not fs.exists(ROOT .. "/gone.lua"))
end)

test("existing user files are backed up, not lost", function()
  reset()
  fs.makeDir(ROOT)
  vfs.writeFile(ROOT .. "/startup.lua", "-- my own startup")
  publish({ a = { version = "1.0.0", files = { [ROOT .. "/startup.lua"] = "-- tessera" } } })
  ok(pkg.installPackages({ "a" }))
  eq(read(ROOT .. "/startup.lua"), "-- tessera")
  eq(read(install.backupDir .. ROOT .. "/startup.lua"), "-- my own startup")
end)

test("files owned by another package cannot be overwritten", function()
  reset()
  publish({
    a = { version = "1.0.0", files = { [ROOT .. "/shared.lua"] = "a" } },
    b = { version = "1.0.0", files = { [ROOT .. "/shared.lua"] = "b" } },
  })
  ok(pkg.installPackages({ "a" }))
  local ok2, err = pkg.installPackages({ "b" })
  ok(ok2 == nil and err:find("owned by package a"), tostring(err))
  eq(read(ROOT .. "/shared.lua"), "a")
end)

test("unsafe paths are refused", function()
  reset()
  publish({ a = { version = "1.0.0", files = { ["/rom/programs/evil.lua"] = "x" } } })
  local ok2, err = pkg.installPackages({ "a" })
  ok(ok2 == nil and err:find("/rom"), tostring(err))
end)

test("remove checks dependents, deletes files and prunes empty directories", function()
  reset()
  publish({
    app = { version = "1.0.0", requires = { lib = "*" }, files = { [ROOT .. "/deep/dir/app.lua"] = "app" } },
    lib = { version = "1.0.0", files = { [ROOT .. "/lib.lua"] = "lib" } },
  })
  ok(pkg.installPackages({ "app" }))
  local ok2, err = pkg.remove({ "lib" })
  ok(ok2 == nil and err:find("required by app"))
  ok(pkg.remove({ "app" }))
  ok(not fs.exists(ROOT .. "/deep"), "empty directories should be pruned")
  eq(db.names(), { "lib" })
  ok(pkg.remove({ "lib" }))
  eq(db.names(), {})
  local ok3, err3 = pkg.remove({ "nothing" })
  ok(ok3 == nil and err3:find("not installed"))
end)

test("core cannot be removed without --force", function()
  reset()
  publish({ core = { version = "1.0.0", files = { [ROOT .. "/core.lua"] = "c" } } })
  ok(pkg.installPackages({ "core" }))
  local ok2, err = pkg.remove({ "core" })
  ok(ok2 == nil and err:find("refusing"))
  ok(pkg.remove({ "core" }, { force = true }))
end)

test("lazy installs create stubs that install the real package on demand", function()
  reset()
  publish({ tool = { version = "1.0.0", files = { ["/usr/bin/tsr-lazytool.lua"] = "LAZY_RAN = (LAZY_RAN or 0) + 1",
                                                   ["/usr/lib/tsrlazy/data.lua"] = "return 1" } } })
  local ok1 = pkg.installPackages({ "tool" }, { lazy = true })
  ok(ok1)
  ok(db.get("tool").lazy)
  ok(fs.exists("/usr/bin/tsr-lazytool.lua"))
  ok(not fs.exists("/usr/lib/tsrlazy/data.lua"), "non-executable files are not installed lazily")
  ok(read("/usr/bin/tsr-lazytool.lua"):find("lazy stub", 1, true))
  ok(pkg.ensure("tool"))
  ok(not db.get("tool").lazy)
  eq(read("/usr/bin/tsr-lazytool.lua"), "LAZY_RAN = (LAZY_RAN or 0) + 1")
  ok(fs.exists("/usr/lib/tsrlazy/data.lua"))
  ok(pkg.remove({ "tool" }))
  ok(not fs.exists("/usr/bin/tsr-lazytool.lua") and not fs.exists("/usr/lib/tsrlazy"))
end)

test("verify detects modified and missing files", function()
  reset()
  publish({ a = { version = "1.0.0", files = { [ROOT .. "/a.lua"] = "a", [ROOT .. "/b.lua"] = "b" } } })
  ok(pkg.installPackages({ "a" }))
  vfs.writeFile(ROOT .. "/a.lua", "tampered")
  fs.delete(ROOT .. "/b.lua")
  local problems = pkg.verify("a")
  eq(#problems, 2)
  local by = {}
  for _, p in ipairs(problems) do by[p.path] = p.problem end
  eq(by[ROOT .. "/a.lua"], "modified")
  eq(by[ROOT .. "/b.lua"], "missing")
end)

test("search and info", function()
  reset()
  publish({
    alpha = { version = "1.0.0", description = "Fast turtle miner", files = {} },
    beta = { version = "2.0.0", description = "Storage sorter", files = {} },
  })
  local r = pkg.search("turtle")
  eq(#r, 1)
  eq(r[1].name, "alpha")
  eq(#pkg.search(""), 2)
  local info = pkg.info("beta")
  eq(info.latest, "2.0.0")
  eq(info.source, "test")
  local none, err = pkg.info("nope")
  ok(none == nil and err)
end)

test("post_install hooks run after a successful install", function()
  reset()
  publish({ a = { version = "1.0.0", hooks = { post_install = ROOT .. "/hook.lua" },
    files = { [ROOT .. "/hook.lua"] = "HOOK_ARGS = { ... }" } } })
  ok(pkg.installPackages({ "a" }))
  -- hook globals live in the loader env, not _G
  local loaderEnv = require("tsr.loader").env
  eq(rawget(loaderEnv, "HOOK_ARGS"), { "a", "1.0.0", "install" })
  loaderEnv.HOOK_ARGS = nil
end)

test("space accounting", function()
  reset()
  publish({ a = { version = "1.0.0", files = { [ROOT .. "/a"] = string.rep("x", 100) } } })
  local plan = pkg.installPackages({ "a" }, { dry = true })
  eq(install.spaceNeeded(plan), 100)
  ok(pkg.installPackages({ "a" }))
  publish({ a = { version = "1.0.0", files = { [ROOT .. "/a"] = string.rep("x", 100) } } })
  local plan2 = pkg.installPackages({ "a" }, { dry = true, reinstall = true })
  eq(install.spaceNeeded(plan2), 0)
end)

test("conflicts and missing dependencies produce readable errors", function()
  reset()
  publish({ app = { version = "1.0.0", requires = { ghost = "*" }, files = {} } })
  local ok2, err = pkg.installPackages({ "app" })
  ok(ok2 == nil and err:find("ghost"), tostring(err))
end)

test("the anti-virus can stop a package that carries malware", function()
  reset()
  local av = require("tsr.av")
  local savedConfig = av.CONFIG
  av.CONFIG = "/tmp-state/av.json"
  vfs.writeFile(av.CONFIG, textutils.serializeJSON({ scan_packages = true }))
  publish({
    clean = { version = "1.0.0", files = { [ROOT .. "/bin/clean.lua"] = "print('hello')" } },
    evil = { version = "1.0.0", files = { [ROOT .. "/bin/evil.lua"] = 'fs.delete("/")' } },
  })
  local done, plan = pkg.installPackages({ "clean" })
  ok(done, tostring(plan))
  local blocked, why = pkg.installPackages({ "evil" })
  ok(not blocked and tostring(why):find("blocked by the anti-virus", 1, true) and tostring(why):find("WIPE_DISK", 1, true), tostring(why))
  ok(not fs.exists(ROOT .. "/bin/evil.lua") and db.get("evil") == nil, "nothing of the package was installed")
  -- switched off: installs normally
  vfs.writeFile(av.CONFIG, textutils.serializeJSON({ scan_packages = false }))
  local allowed = pkg.installPackages({ "evil" })
  ok(allowed)
  av.CONFIG = savedConfig
end)
