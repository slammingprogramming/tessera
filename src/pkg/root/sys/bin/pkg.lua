-- SPDX-License-Identifier: AGPL-3.0-or-later
-- pkg: the Tessera package manager command.
local args = { ... }
local pkgApi = (rawget(_G, "tsr") and tsr.require or require)("tsr.pkg")
local util = (rawget(_G, "tsr") and tsr.require or require)("tsr.util")
local config = (rawget(_G, "tsr") and tsr.require or require)("tsr.config")

local function color(c) if term.isColor() then term.setTextColor(c) end end
local function say(c, s) color(c) print(s) color(colors.white) end
local function die(s) say(colors.red, s) error("", 0) end

local flags, words = {}, {}
for _, a in ipairs(args) do
  if a:sub(1, 2) == "--" then flags[a:sub(3)] = true
  elseif a == "-y" then flags.yes = true
  else words[#words + 1] = a end
end
local cmd = table.remove(words, 1)

local function confirm(question)
  if flags.yes then return true end
  color(colors.yellow)
  write(question .. " [y/N] ")
  color(colors.white)
  local a = read()
  return a and a:lower():sub(1, 1) == "y"
end

local function progress(event, a, b, c, d)
  if event == "fetch" then
    write(("\r(%d/%d) %s"):format(c, d, b))
    local _, y = term.getCursorPos()
    local w = term.getSize()
    write(string.rep(" ", math.max(0, w - #b - 12)))
    term.setCursorPos(1, y)
  elseif event == "commit" then print() print("installing...")
  end
end

local function showPlan(plan)
  local total = 0
  for _, e in ipairs(plan) do
    local size = e.manifest.size and e.manifest.size.installed or 0
    total = total + size
    color(e.action == "upgrade" and colors.orange or colors.lime)
    write(("%-9s"):format(e.action))
    color(colors.white)
    print(("%s %s (%s)"):format(e.name, e.version, util.fmtBytes(size)))
  end
  print(("total: %s, %s free"):format(util.fmtBytes(total), util.fmtBytes(util.freeSpace())))
end

local commands = {}

function commands.list()
  local rows = pkgApi.list()
  if #rows == 0 then return print("nothing installed") end
  for _, row in ipairs(rows) do
    local r = row.record
    write(("%-22s %-8s"):format(row.name, r.version))
    color(colors.lightGray)
    print((r.lazy and "lazy " or "") .. (r.reason == "auto" and "auto" or ""))
    color(colors.white)
  end
end

function commands.search()
  local results = pkgApi.search(words[1] or "")
  if #results == 0 then return print("no matches (run `pkg update` to refresh the registry)") end
  for _, r in ipairs(results) do
    write(("%-22s %-8s"):format(r.name, r.entry.version or "?"))
    color(colors.lightGray)
    print((r.installed and "[installed] " or "") .. (r.entry.description or ""))
    color(colors.white)
  end
end

function commands.info()
  local name = words[1] or die("usage: pkg info <name>")
  local info, err = pkgApi.info(name)
  if not info then die(err) end
  say(colors.yellow, name)
  if info.manifest then
    local m = info.manifest
    print(m.description or "")
    print("latest:   " .. info.latest .. "   license: " .. tostring(m.license))
    if m.size then print("size:     " .. util.fmtBytes(m.size.installed or 0) .. " installed") end
    local deps = {}
    for d, r in pairs(m.requires or {}) do deps[#deps + 1] = d .. (r ~= "*" and (" " .. r) or "") end
    table.sort(deps)
    print("requires: " .. (#deps > 0 and table.concat(deps, ", ") or "-"))
    if m.source and m.source.repo then print("source:   " .. m.source.repo) end
  end
  if info.installed then print("installed: " .. info.installed.version .. (info.installed.lazy and " (lazy)" or "")) end
end

function commands.install()
  if #words == 0 then die("usage: pkg install <name>[@range] ... [--lazy] [--dry] [-y]") end
  local plan, err = pkgApi.installPackages(words, { dry = true, reinstall = flags.reinstall })
  if not plan then die(err) end
  if #plan == 0 then return say(colors.lime, "already installed") end
  showPlan(plan)
  if flags.dry then return end
  if not confirm("Proceed?") then return print("aborted") end
  local ok, e = pkgApi.installPackages(words, { lazy = flags.lazy, reinstall = flags.reinstall, progress = progress })
  if not ok then die(e) end
  say(colors.lime, "done")
end

function commands.remove()
  if #words == 0 then die("usage: pkg remove <name> ... [--force] [-y]") end
  if not confirm("Remove " .. table.concat(words, ", ") .. "?") then return print("aborted") end
  local ok, err = pkgApi.remove(words, { force = flags.force })
  if not ok then die(err) end
  say(colors.lime, "removed")
end

function commands.update()
  for name, res in pairs(pkgApi.update()) do
    if res == true then say(colors.lime, name .. ": ok") else say(colors.red, name .. ": " .. tostring(res)) end
  end
end

function commands.upgrade()
  commands.update()
  local plan, err = pkgApi.upgrade(#words > 0 and words or nil, { dry = true })
  if not plan then die(err) end
  if #plan == 0 then return say(colors.lime, "everything is up to date") end
  showPlan(plan)
  if not confirm("Proceed?") then return print("aborted") end
  local ok, e = pkgApi.upgrade(#words > 0 and words or nil, { progress = progress })
  if not ok then die(e) end
  say(colors.lime, "done")
end

function commands.verify()
  local problems = pkgApi.verify(words[1])
  if #problems == 0 then return say(colors.lime, "all files match") end
  for _, p in ipairs(problems) do say(colors.red, ("%s: %s %s"):format(p.package, p.path, p.problem)) end
  error("", 0)
end

function commands.clean()
  pkgApi.clean(flags.all)
  say(colors.lime, "cache cleared")
end

commands["import"] = function()
  local b
  if words[1] then
    local h = fs.open(words[1], "rb")
    if not h then die("cannot read " .. words[1]) end
    local data = h.readAll()
    h.close()
    local err
    b, err = (rawget(_G, "tsr") and tsr.require or require)("tsr.bundle").parse(data)
    if not b then die(tostring(err)) end
  else
    b = (rawget(_G, "tsr") and tsr.require or require)("tsr.pkg.importer").interactive()
    if not b then return end
  end
  local res, err = pkgApi.importBundle(b)
  if not res then die(err) end
  say(colors.lime, ("imported %d package(s), %d file payload(s)"):format(res.packages, res.blobs))
  print("now run: pkg install <name>")
end

function commands.source()
  local sub = words[1] or "list"
  local list = config.get("pkg.sources", {})
  if sub == "list" then
    for _, s in ipairs(pkgApi.source.list()) do
      print(("%-12s %-9s %s"):format(s.name, s.type, s.path or (s.bases and table.concat(s.bases, ", ")) or s.snapshot or ""))
    end
  elseif sub == "add" then
    local name, url = words[2], words[3]
    if not (name and url) then die("usage: pkg source add <name> <base-url>") end
    list[#list + 1] = { name = name, type = "http", bases = { url } }
    config.set("pkg.sources", list, "system")
    config.save("system")
    say(colors.lime, "added " .. name .. " (third-party registries are untrusted; packages are still hash-checked)")
  elseif sub == "remove" then
    for i, s in ipairs(list) do
      if s.name == words[2] then table.remove(list, i) end
    end
    config.set("pkg.sources", list, "system")
    config.save("system")
    say(colors.lime, "removed")
  else
    die("usage: pkg source [list | add <name> <url> | remove <name>]")
  end
end

function commands.help()
  print("pkg <command>")
  print("  install <pkg>...   [--lazy] [--dry] [-y]")
  print("  remove <pkg>...    [--force] [-y]")
  print("  update | upgrade   refresh index / upgrade all")
  print("  search [text] | info <pkg> | list")
  print("  verify [pkg] | clean [--all]")
  print("  import [file]      offline install data (drop file or paste)")
  print("  source [list|add|remove]")
end

if not cmd or not commands[cmd] then
  if cmd then say(colors.red, "unknown command: " .. cmd) end
  return commands.help()
end

local ok, err = pcall(commands[cmd])
if not ok and err ~= "" then say(colors.red, tostring(err)) end
