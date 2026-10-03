-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The setup wizard: welcome -> detect hardware -> profile -> use case -> modules -> interface -> name -> review -> install.
-- Everything it needs is injectable (env.ui / env.pkg / env.hw ...), which is how the tests drive it. It can be re-run
-- at any time to add or remove modules: installed packages start ticked, unticking one removes it.
local recommend = require("tsr.setup.recommend")
local usecases = require("tsr.setup.usecases")
local util = require("tsr.util")

local M = {}

local HIDDEN = { core = true, pkg = true, installer = true }   -- never shown as choices

local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

local function sortedNames(set)
  local out = {}
  for k, v in pairs(set) do if v then out[#out + 1] = k end end
  table.sort(out)
  return out
end

--- One-screen summary lines of what the probe found.
function M.summary(probe)
  local c, lines = probe.counts, {}
  local kind = probe.computer.kind
  local label = kind == "computer" and (probe.computer.advanced and "advanced computer" or "basic computer") or kind
  lines[#lines + 1] = ("Computer: %s (id %d)"):format(label, probe.computer.id or 0)
  lines[#lines + 1] = ("Screen: %dx%d, %s%s"):format(probe.screen.width, probe.screen.height,
    probe.screen.color and "colour" or "black & white", probe.screen.mouse and ", mouse" or ", keyboard only")
  local free = probe.storage.free
  lines[#lines + 1] = ("Storage: %s free%s"):format(free == math.huge and "unlimited" or util.fmtBytes(free),
    probe.storage.capacity and (" of " .. util.fmtBytes(probe.storage.capacity)) or "")
  if not probe.http.enabled then
    lines[#lines + 1] = "Network: HTTP is disabled here (offline install)"
  else
    local reach, ok, total = probe.http.reach or {}, 0, 0
    for _, v in pairs(reach) do total = total + 1 if v then ok = ok + 1 end end
    lines[#lines + 1] = total > 0 and ("Network: HTTP enabled, %d of %d test hosts reachable"):format(ok, total)
      or "Network: HTTP enabled"
  end
  local parts = {}
  local function add(n, word) if n > 0 then parts[#parts + 1] = n .. " " .. word end end
  add(c.monitors, "monitor(s)") add(c.speakers, "speaker(s)")
  add(c.wirelessModems, "wireless modem(s)") add(c.wiredModems, "wired modem(s)")
  add(c.drives, "disk drive(s)") add(c.printers, "printer(s)") add(c.redstoneRelays, "redstone relay(s)")
  add(c.inventories, "inventory block(s)") add(c.energy, "energy storage") add(c.fluid, "fluid tank(s)")
  lines[#lines + 1] = "Peripherals: " .. (#parts > 0 and table.concat(parts, ", ") or "none")
  return lines
end

--- A non-interactive stand-in for the TUI: accepts every default and recommendation. Used by `tsr-setup --auto`
--- (unattended installs, scripting, tests). Informational screens are printed instead of shown.
function M.autoUi()
  local ui = {}
  function ui.frame() end
  function ui.status() end
  function ui.bar() end
  function ui.message(title, lines)
    print("== " .. title)
    for _, l in ipairs(lines or {}) do print(l) end
  end
  function ui.confirm(title, lines, opts) return (opts or {}).default ~= false end
  function ui.menu(title, items, opts) return (opts or {}).initial or 1 end
  function ui.checklist(title, items, opts)
    local checks = {}
    for _, it in ipairs(items) do checks[it.id] = ((opts or {}).checked or {})[it.id] and true or false end
    return checks
  end
  function ui.input(title, prompt, default) return default end
  return ui
end

---------------------------------------------------------------------------------------------------------------------

--- env: ui, pkg, hw, config, importer, vfs (all optional, for tests) and auto (bool: unattended, no reboot).
function M.run(env)
  env = env or {}
  local ui = env.ui or (env.auto and M.autoUi()) or require("tsr.ui.tui")
  local pkgApi = env.pkg or require("tsr.pkg")
  local hwApi = env.hw or require("tsr.hw")
  local config = env.config or require("tsr.config")
  local importer = env.importer or require("tsr.pkg.importer")
  local vfs = env.vfs or require("tsr.vfs")
  local source = pkgApi.source

  local S = { selected = {}, removeOnly = {}, lazyOptional = false, uiMode = "tui" }

  local function registry()
    local all = source.allPackages()
    local n = 0
    for _ in pairs(all) do n = n + 1 end
    return all, n
  end

  --- Make sure some registry is reachable; otherwise walk the user through an offline import.
  local function ensureRegistry()
    local _, n = registry()
    while n <= 0 do
      local retry = ui.confirm("No package registry", {
        "This computer cannot reach the Tessera registry, and no offline data has been imported yet.",
        "",
        "Offline install: drop a .tsrbundle file on this window, or paste the numbered TSR1 lines.",
        "Build one at the project's bundle page.",
      }, { default = true })
      if not retry then return false end
      term.setBackgroundColor(colors.black)
      term.clear()
      term.setCursorPos(1, 1)
      local b = importer.interactive({ prompt = "Offline import" })
      if b then
        local res, err = pkgApi.importBundle(b)
        if not res then ui.message("Import failed", { tostring(err) }) end
      end
      _, n = registry()
    end
    return true
  end

  -- steps ---------------------------------------------------------------------------------------------------------------
  local steps = {}

  steps.welcome = function()
    local go = ui.confirm("Tessera setup", {
      "This wizard looks at what this computer is and what is attached to it, then suggests a setup.",
      "You can change every suggestion, and re-run it any time to add or remove features.",
      "",
      "Continue?",
    }, { default = true })
    return go and "next" or "quit"
  end

  steps.detect = function()
    ui.frame("Detecting hardware")
    ui.status("Looking at peripherals and network...")
    local urls = { "https://pastebin.com" }
    for _, s in ipairs(config.get("pkg.sources", {})) do
      for _, b in ipairs(s.bases or {}) do urls[#urls + 1] = b end
    end
    S.probe = hwApi.probe({ net = true, urls = urls })
    S.rec = recommend.recommend(S.probe)
    local lines = M.summary(S.probe)
    if #S.rec.mods > 0 then
      lines[#lines + 1] = ""
      for _, m in ipairs(S.rec.mods) do
        lines[#lines + 1] = ("Recognised mod: %s (%s)%s"):format(m.name, m.example, m.verified and "" or " - detection unverified")
      end
    end
    ui.message("Detected", lines)
    return "next"
  end

  steps.registry = function()
    return ensureRegistry() and "next" or "quit"
  end

  steps.profile = function()
    local items, initial = {}, 1
    for i, p in ipairs(S.rec.profiles) do
      items[i] = { label = p.label, desc = p.blocked and ("Not available: " .. p.blocked) or p.reason or "",
                   disabled = p.blocked ~= nil, tag = p.recommended and "recommended" or nil, tier = p.recommended and "recommended" or nil }
      if S.profile == p.name or (not S.profile and p.recommended) then initial = i end
    end
    local sel = ui.menu("What is this computer for?", items, { initial = initial })
    if not sel then return "back" end
    S.profile = S.rec.profiles[sel].name
    S.items = recommend.packages(S.probe, S.profile)
    return "next"
  end

  --- What the computer is for (router, switch, mail server, smart home ...): its packages join the selection, its settings are applied at the end.
  steps.usecase = function()
    -- packages of a previous choice go away again when another one is picked
    local function forget()
      for _, name in ipairs(S.usecasePackages or {}) do S.selected[name] = nil end
      S.usecasePackages = {}
    end
    local function choose(id)
      forget()
      S.usecase = id
      if not id then return end
      local plan = usecases.plan(id, S.probe, { hostname = S.hostname })
      S.usecasePackages = {}
      local have = {}
      for _, it in ipairs(S.items) do have[it.pkg] = it end
      for _, name in ipairs(plan.packages) do
        if have[name] then have[name].tier = "recommended"
        else S.items[#S.items + 1] = { pkg = name, tier = "recommended", reason = "needed for: " .. plan.label } end
        if not S.selected[name] then S.usecasePackages[#S.usecasePackages + 1] = name end
        S.selected[name] = true
      end
    end
    local list = usecases.available(S.probe, S.profile)
    if env.usecase and not S.usecaseAsked then
      S.usecaseAsked = true
      local known
      for _, u in ipairs(list) do if u.id == env.usecase then known = u end end
      if not known then ui.message("Unknown use case", { tostring(env.usecase) }) elseif known.blocked then ui.message("Use case not possible here", { known.label .. ": " .. known.blocked })
      else choose(env.usecase) end
      return "next"
    end
    local items = { { label = "General purpose", desc = "No special role: you choose the modules yourself.", tag = "default" } }
    local initial = 1
    for i, u in ipairs(list) do
      items[#items + 1] = { label = u.label, desc = u.blocked and ("Not available: " .. u.blocked) or u.summary, disabled = u.blocked ~= nil, tag = u.group }
      if S.usecase == u.id then initial = i + 1 end
    end
    local sel = ui.menu("What should it do?", items, { initial = initial })
    if not sel then return "back" end
    choose(sel > 1 and list[sel - 1].id or nil)
    return "next"
  end

  steps.modules = function()
    local all = registry()
    local items, checked, seen, missing = {}, {}, {}, 0
    for _, it in ipairs(S.items) do
      local entry = all[it.pkg]
      if entry and not HIDDEN[it.pkg] then
        seen[it.pkg] = true
        local installed = pkgApi.db.get(it.pkg)
        items[#items + 1] = { id = it.pkg, label = it.pkg, tier = it.tier, desc = it.reason,
                              tag = entry.size and util.fmtBytes(entry.size) or nil }
        checked[it.pkg] = installed ~= nil or S.selected[it.pkg] or (S.chosen == nil and it.tier == "recommended")
      elseif not entry then
        missing = missing + 1
      end
    end
    -- everything else the registry offers, unticked
    local extra = {}
    for name, entry in pairs(all) do
      if not seen[name] and not HIDDEN[name] then extra[#extra + 1] = name end
    end
    table.sort(extra)
    for _, name in ipairs(extra) do
      local entry = all[name]
      local installed = pkgApi.db.get(name)
      items[#items + 1] = { id = name, label = name, desc = entry.description or "", tag = entry.size and util.fmtBytes(entry.size) or nil }
      checked[name] = installed ~= nil or S.selected[name] or false
    end
    S.chosen = true
    local header = missing > 0 and ("%d suggested module(s) are not in this release yet."):format(missing) or nil
    local res = ui.checklist("Choose modules", items, { checked = checked, header = header })
    if not res then return "back" end
    S.selected, S.removeOnly = {}, {}
    for id, on in pairs(res) do
      local installed = pkgApi.db.get(id)
      if on then S.selected[id] = true
      elseif installed and not HIDDEN[id] then S.removeOnly[id] = true end
    end
    return "next"
  end

  steps.interface = function()
    local all = registry()
    local gui = all["ui-gui"]
    if not gui or not S.probe.computer.advanced or S.profile == "node" or S.profile == "turtle" then
      S.selected["ui-gui"] = nil
      return "next"
    end
    local have = pkgApi.db.get("ui-gui") ~= nil
    local sel = ui.menu("Interface", {
      { label = "Text interface only", desc = "Smallest and fastest. Recommended if disk space is tight." },
      { label = "Graphical desktop", desc = "Windows, mouse and a desktop. Needs more space; can be removed later." },
      { label = "Decide later", desc = "Install the GUI any time with: pkg install ui-gui" },
    }, { initial = (S.selected["ui-gui"] or have) and 2 or 1 })
    if not sel then return "back" end
    S.selected["ui-gui"] = sel == 2 and true or nil
    if sel ~= 2 and have and sel == 1 then S.removeOnly["ui-gui"] = true end
    S.uiMode = sel == 2 and "gui" or "tui"
    return "next"
  end

  steps.name = function()
    local default = config.get("net.hostname") or os.getComputerLabel() or ("cc-" .. os.getComputerID())
    local name = ui.input("Computer name", "Name for this computer (letters, digits, dashes):", default)
    name = util.trim(name or "")
    if name == "" then name = default end
    S.hostname = name:gsub("[^%w%-_]", "-")
    return "next"
  end

  -- plan for review / install
  local function buildPlan()
    local names = sortedNames(S.selected)
    local plan, err = pkgApi.installPackages(names, { dry = true })
    if not plan then return nil, err end
    return plan, nil, names
  end

  steps.review = function()
    local plan, err, names = buildPlan()
    if not plan then
      ui.message("Cannot continue", { tostring(err), "", "Go back and adjust the module selection." })
      return "back"
    end
    local total = 0
    local lines = { ("Profile: %s"):format(S.profile), ("Name: %s"):format(S.hostname), "" }
    for _, e in ipairs(plan) do
      local size = e.manifest.size and e.manifest.size.installed or 0
      total = total + size
      lines[#lines + 1] = ("%s %s %s (%s)"):format(e.action == "upgrade" and "~" or "+", e.name, e.version, util.fmtBytes(size))
    end
    local removes = sortedNames(S.removeOnly)
    for _, n in ipairs(removes) do lines[#lines + 1] = "- " .. n .. " (remove)" end
    local free = util.freeSpace()
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("Total %s, %s free."):format(util.fmtBytes(total), free == math.huge and "plenty" or util.fmtBytes(free))
    S.plan, S.removes = plan, removes
    S.lazyOptional = false
    local margin = config.get("pkg.free_margin", 8192)
    if total + margin > free then
      lines[#lines + 1] = "NOT ENOUGH SPACE."
      ui.message("Review", lines)
      local sel = ui.menu("Not enough disk space", {
        { label = "Go back and remove modules" },
        { label = "Install recommended now, fetch the rest on first use",
          desc = "Optional modules get tiny launchers that download the real program the first time you run it." },
        { label = "Cancel setup" },
      })
      if sel == 2 then S.lazyOptional = true
      elseif sel == 3 then return "quit"
      else return "back" end
    else
      local ok = ui.confirm("Review", lines, { default = true })
      if not ok then return "back" end
    end
    return "next"
  end

  steps.install = function()
    for _, name in ipairs(S.removes or {}) do
      local ok, err = pkgApi.remove({ name })
      if not ok then ui.message("Could not remove " .. name, { tostring(err) }) end
    end
    local recommendedSet = {}
    for _, it in ipairs(S.items or {}) do if it.tier == "recommended" then recommendedSet[it.pkg] = true end end
    local real, lazy = {}, {}
    for _, name in ipairs(sortedNames(S.selected)) do
      if S.lazyOptional and not recommendedSet[name] and name ~= "ui-tui" then lazy[#lazy + 1] = name else real[#real + 1] = name end
    end

    local function run(names, opts)
      opts = opts or {}
      opts.keepCache = true
      opts.progress = function(event, a, b, c, d)
        if event == "fetch" then
          ui.frame("Installing")
          ui.bar(4, d > 0 and (c / d) or 0, ("%s  %s"):format(a, b))
        elseif event == "commit" then
          ui.frame("Installing")
          ui.status("Writing files...")
        end
      end
      while true do
        local ok, err = pkgApi.installPackages(names, opts)
        if ok then return true end
        if tostring(err):find("cannot fetch") then
          local more = ui.confirm("Missing data", {
            tostring(err), "", "If you are installing offline, import the missing bundle now?",
          }, { default = true })
          if more then
            term.setBackgroundColor(colors.black) term.clear() term.setCursorPos(1, 1)
            local b = importer.interactive({ prompt = "Import more data" })
            if b then pkgApi.importBundle(b) end
          else
            return false, err
          end
        else
          local sel = ui.menu("Install failed", {
            { label = "Retry", desc = tostring(err) }, { label = "Give up", desc = tostring(err) },
          })
          if sel ~= 1 then return false, err end
        end
      end
    end

    if #real > 0 then
      local ok, err = run(real)
      if not ok then ui.message("Install stopped", { tostring(err) }) return "back" end
    end
    if #lazy > 0 then
      local ok, err = run(lazy, { lazy = true })
      if not ok then ui.message("Lazy install stopped", { tostring(err) }) end
    end
    return "next"
  end

  steps.finish = function()
    local applied
    if S.usecase then
      applied = usecases.apply(S.usecase, S.probe, { hostname = S.hostname, vfs = vfs, config = config })
    end
    config.set("system.profile", S.profile, "system")
    config.set("net.hostname", S.hostname, "system")
    config.set("ui.mode", S.uiMode, "system")
    config.save("system")
    vfs.writeJSON("/etc/tsr/setup.done", { profile = S.profile, hostname = S.hostname, ui = S.uiMode, usecase = S.usecase,
      packages = sortedNames(S.selected), time = os.epoch and os.epoch("utc") or 0 })
    if not os.getComputerLabel() and os.setComputerLabel then pcall(os.setComputerLabel, S.hostname) end
    source.clean()
    if env.auto then
      if applied then S.result = applied end
      return "done" -- unattended runs never reboot by themselves (see tsr-setup --reboot)
    end
    local lines = { "Tessera is configured as: " .. S.profile }
    if applied then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "Use case: " .. (usecases.get(S.usecase).label)
      for _, p in ipairs(applied.written) do lines[#lines + 1] = "  wrote " .. p end
      for _, p in ipairs(applied.kept) do lines[#lines + 1] = "  kept " .. p .. " (already there)" end
      if #applied.enabled > 0 then lines[#lines + 1] = "  services: " .. table.concat(applied.enabled, ", ") end
      for _, n in ipairs(applied.notes) do lines[#lines + 1] = "  " .. n end
      for _, n in ipairs(applied.problems) do lines[#lines + 1] = "  PROBLEM: " .. n end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Reboot now to start using it?"
    local reboot = ui.confirm("Setup complete", lines, { default = true })
    return reboot and "reboot" or "done"
  end

  -- driver ----------------------------------------------------------------------------------------------------------------
  local order = { "welcome", "detect", "registry", "profile", "usecase", "modules", "interface", "name", "review", "install", "finish" }
  local i = 1
  while i <= #order do
    local result = steps[order[i]]()
    if result == "next" then i = i + 1
    elseif result == "back" then i = math.max(1, i - 1)
      -- skip informational screens when going back
      while i > 1 and (order[i] == "detect" or order[i] == "registry" or order[i] == "welcome") do i = i - 1 end
      if i == 1 and order[1] == "welcome" then i = 4 end
    elseif result == "quit" then return "quit"
    else return result end -- "reboot" / "done"
  end
  return "done"
end

return M
