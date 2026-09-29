-- SPDX-License-Identifier: AGPL-3.0-or-later
-- End-to-end test of the bootstrap installer (dist/site/install.lua) on a computer with NOTHING installed.
-- Mounts provided by tools/test/run.mjs --bootstrap:  /site (built registry + installer), /bundles, /out.
local tests = {}
local passed, failed = 0, 0
local function check(name, cond, info)
  tests[#tests + 1] = { name = name, ok = cond and true or false, err = (not cond) and tostring(info or "check failed") or nil }
  if cond then passed = passed + 1 else failed = failed + 1 end
end

local function readFile(p)
  local h = fs.open(p, "rb")
  if not h then return nil end
  local s = h.readAll()
  h.close()
  return s
end

local function wipe()
  for _, p in ipairs({ "/sys", "/etc", "/var", "/usr", "/startup.lua", "/tmp-e2e" }) do
    if fs.exists(p) then fs.delete(p) end
  end
end

--- Run the installer with HTTP hidden (the test machine must behave like a server with HTTP disabled).
local lastOutput = ""
local function runInstaller(...)
  local env = { http = false }
  local win = window.create(term.current(), 1, 1, 80, 200, false)
  local prev = term.redirect(win)
  local ok, res = pcall(os.run, env, "/site/install.lua", ...)
  term.redirect(prev)
  local lines = {}
  for y = 1, 200 do
    local l = win.getLine(y):gsub("%s+$", "")
    if l ~= "" then lines[#lines + 1] = l end
  end
  lastOutput = table.concat(lines, " | ")
  if ok and res == false then return false, lastOutput end
  return ok, ok and lastOutput or res
end

local function loadInstalled()
  local loader = dofile("/sys/lib/tsr/loader.lua")
  loader.unload("tsr.pkg.db")
  local db = loader.require("tsr.pkg.db")
  db.reload()
  return loader, db
end

local function verifyInstall(label)
  check(label .. ": core files exist", fs.exists("/sys/boot.lua") and fs.exists("/startup.lua") and fs.exists("/sys/lib/tsr/kernel.lua"))
  check(label .. ": pkg files exist", fs.exists("/sys/bin/pkg.lua") and fs.exists("/sys/lib/tsr/pkg/init.lua"))
  local ok, loader, db = pcall(loadInstalled)
  check(label .. ": package database loads", ok, loader)
  if ok then
    check(label .. ": core and pkg are registered", db.get("core") ~= nil and db.get("pkg") ~= nil, "db names: " .. table.concat(db.names(), ","))
    local pkg = loader.require("tsr.pkg")
    local problems = pkg.verify()
    check(label .. ": every installed file matches its hash", #problems == 0, #problems > 0 and (problems[1].path .. " " .. problems[1].problem) or "")
  end
end

local function scenario(name, fn)
  wipe()
  local ok, err = pcall(fn)
  if not ok then check(name .. ": scenario completed", false, err) end
end

local fatal
local okAll, errAll = pcall(function()
  scenario("directory mirror", function()
    local ok, err = runInstaller("/site", "--yes")
    check("directory mirror: installer ran", ok, err)
    verifyInstall("directory mirror")
  end)

  scenario("bundle file", function()
    local ok, err = runInstaller("--bundle", "/bundles/boot.tsrbundle", "--yes")
    check("bundle file: installer ran", ok, err)
    verifyInstall("bundle file")
    check("bundle file: bundle stored for later installs", fs.exists("/var/cache/tsr/offline/registry/index.json"))
  end)

  scenario("pasted chunks", function()
    local text = readFile("/bundles/boot.txt")
    local n = 0
    for line in text:gmatch("[^\r\n]+") do
      os.queueEvent("paste", line)
      n = n + 1
    end
    local ok, err = runInstaller("--yes")
    check("pasted chunks: installer ran (" .. n .. " lines)", ok, err)
    verifyInstall("pasted chunks")
  end)

  scenario("existing startup.lua is backed up", function()
    local h = fs.open("/startup.lua", "w") h.write("-- my own startup") h.close()
    local ok, err = runInstaller("/site", "--yes")
    check("backup: installer ran", ok, err)
    check("backup: old startup kept", readFile("/etc/tsr/backup/startup.lua") == "-- my own startup")
    check("backup: Tessera startup installed", (readFile("/startup.lua") or ""):find("hold R to skip", 1, true) ~= nil)
  end)

  scenario("setup wizard (unattended) after bootstrap", function()
    local ok, err = runInstaller("/site", "--yes")
    check("wizard: bootstrap ran", ok, err)
    local loader = dofile("/sys/lib/tsr/loader.lua")
    local config = loader.require("tsr.config")
    config.setDefaults(loader.require("tsr.defaults"))
    config.set("pkg.sources", { { name = "mirror", type = "dir", path = "/site" } }, "user")
    local pkg = loader.require("tsr.pkg")
    local iok, ierr = pkg.installPackages({ "installer" })
    check("wizard: installer package (and ui-tui) install from the mirror", iok, ierr)
    check("wizard: tsr-setup exists", fs.exists("/sys/bin/tsr-setup.lua"))
    _G.tsr = { require = loader.require }
    local win = window.create(term.current(), 1, 1, 80, 200, false)
    local prev = term.redirect(win)
    local rok, rres = pcall(os.run, {}, "/sys/bin/tsr-setup.lua", "--auto", "--source", "/site")
    term.redirect(prev)
    _G.tsr = nil
    check("wizard: ran without error", rok and rres ~= false)
    check("wizard: wrote setup.done", fs.exists("/etc/tsr/setup.done"))
    local done = textutils.unserializeJSON(readFile("/etc/tsr/setup.done") or "{}") or {}
    check("wizard: profile recorded", done.profile == "client" or done.profile == "client-lite", tostring(done.profile))
    local db = loader.require("tsr.pkg.db")
    db.reload()
    check("wizard: recommended module ui-tui is installed", db.get("ui-tui") ~= nil)
    local cfg = textutils.unserialize(readFile("/etc/tsr/system.cfg") or "{}") or {}
    check("wizard: configuration saved", cfg.system and cfg.system.profile ~= nil, readFile("/etc/tsr/system.cfg"))
    check("wizard: everything still verifies", #pkg.verify() == 0)
  end)

  scenario("second install is refused", function()
    runInstaller("/site", "--yes")
    local before = readFile("/sys/boot.lua")
    local ok = runInstaller("/site", "--yes")
    check("second install: nothing changed", ok and readFile("/sys/boot.lua") == before)
  end)

  scenario("corrupted bundle is rejected before anything is written", function()
    local data = readFile("/bundles/boot.tsrbundle")
    local i = math.floor(#data / 2)
    local bad = data:sub(1, i - 1) .. string.char((data:byte(i) + 1) % 256) .. data:sub(i + 1)
    fs.makeDir("/tmp-e2e")
    local h = fs.open("/tmp-e2e/bad.tsrbundle", "wb") h.write(bad) h.close()
    local ok = runInstaller("--bundle", "/tmp-e2e/bad.tsrbundle", "--yes")
    check("corrupt bundle: no install happened", not fs.exists("/sys/boot.lua"))
  end)
end)
if not okAll then fatal = tostring(errAll) end

wipe()
local out = fs.open("/out/results.json", "w")
out.write(textutils.serializeJSON({ files = { { file = "e2e/bootstrap", tests = tests } }, passed = passed,
  failed = failed + (fatal and 1 or 0), skipped = 0, fatal = fatal }))
out.close()
os.shutdown()
