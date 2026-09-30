-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Recommendation engine: turns a hardware probe (tsr.hw) into a profile choice and a list of suggested packages, each
-- with a human-readable REASON so the user can judge it. Pure function of the probe — easy to test.
-- Package names are the planned registry names; the wizard shows only the ones that actually exist in the registry.
local hw = require("tsr.hw")
local known = require("tsr.setup.known")

local M = {}

M.PROFILES = {
  { name = "client-lite", label = "Client (basic computer)", needs = "a basic computer" },
  { name = "client", label = "Client (advanced computer)" },
  { name = "server", label = "Server (hosts services)" },
  { name = "turtle", label = "Turtle" },
  { name = "pocket", label = "Pocket computer" },
  { name = "tv", label = "Smart TV (monitor + speakers)" },
  { name = "node", label = "Node (redstone/sensor controller)" },
  { name = "command", label = "Command computer" },
}

--- Which known mods have peripherals attached? Returns array of { id, name, verified, example }.
function M.detectMods(probe)
  local found = {}
  for _, sig in ipairs(known) do
    for _, pat in ipairs(sig.types) do
      local hit, p = hw.hasTypeMatching(probe, pat)
      if hit then
        found[#found + 1] = { id = sig.id, name = sig.name, verified = sig.verified, example = p.types[1] }
        break
      end
    end
  end
  return found
end

--- Profile suggestions. Returns array of { name, label, recommended, reason, blocked }.
function M.profiles(probe)
  local c, kind = probe.counts, probe.computer.kind
  local out = {}
  local default, why
  if kind == "turtle" then default, why = "turtle", "this is a turtle"
  elseif kind == "pocket" then default, why = "pocket", "this is a pocket computer"
  elseif kind == "command" then default, why = "command", "this is a command computer"
  elseif probe.computer.advanced then default, why = "client", "advanced computer with a colour screen and mouse"
  else default, why = "client-lite", "basic computer: no colour or mouse, so a lightweight text-only setup" end

  for _, p in ipairs(M.PROFILES) do
    local entry = { name = p.name, label = p.label, recommended = p.name == default }
    if p.name == default then entry.reason = why end
    if p.name == "client-lite" and probe.computer.advanced then entry.reason = "works, but an advanced computer can do more" end
    if p.name == "client" and not probe.computer.advanced and kind == "computer" then
      entry.blocked = "needs an advanced computer (colour + mouse)"
    end
    if (p.name == "turtle" and kind ~= "turtle") then entry.blocked = "only on turtles" end
    if (p.name == "pocket" and kind ~= "pocket") then entry.blocked = "only on pocket computers" end
    if (p.name == "command" and kind ~= "command") then entry.blocked = "only on command computers" end
    if (kind == "turtle" or kind == "pocket") and p.name ~= kind and p.name ~= "node" then
      if not entry.blocked then entry.blocked = "not suitable for a " .. kind end
    end
    if p.name == "tv" then
      if c.monitors == 0 then entry.blocked = "needs an attached monitor"
      else entry.reason = ("%d monitor(s)%s attached"):format(c.monitors, c.speakers > 0 and " and speakers" or "") end
    end
    if p.name == "server" then
      if probe.hasModem then entry.reason = "has a modem to serve other computers" .. (probe.http.enabled and " and HTTP for updates" or "") end
      if kind ~= "computer" then entry.blocked = "only on regular computers" end
    end
    if p.name == "node" and kind ~= "computer" then entry.blocked = "only on regular computers" end
    out[#out + 1] = entry
  end
  return out, default
end

--- Suggested packages for `profile`. Returns array of { pkg, reason, tier = "recommended" | "optional" }.
function M.packages(probe, profile)
  local items, index = {}, {}
  local function add(pkg, tier, reason)
    if index[pkg] then
      if tier == "recommended" then index[pkg].tier = "recommended" end
      return
    end
    local e = { pkg = pkg, tier = tier, reason = reason }
    items[#items + 1] = e
    index[pkg] = e
  end
  local c = probe.counts
  local kind = probe.computer.kind
  local mods = M.detectMods(probe)
  local modSet = {}
  for _, m in ipairs(mods) do modSet[m.id] = m end

  -- interface ------------------------------------------------------------------------------------------------------
  add("ui-tui", "recommended", "text interface used by the setup wizard and most tools")
  if probe.computer.advanced and profile ~= "node" and profile ~= "turtle" then
    add("ui-gui", "optional", "graphical desktop with windows and mouse (you can also add it later)")
  end
  add("help", "optional", "built-in manuals and first-run tutorial")

  -- networking -----------------------------------------------------------------------------------------------------
  if probe.hasModem then
    add("net", "recommended", "a modem is attached: discovery, secure messaging, remote shell and file access")
  end
  if profile == "server" then
    add("net", "recommended", "servers exist to talk to other computers")
    add("svc-manager", "recommended", "starts and supervises the services this server hosts")
    if probe.http.enabled and probe.hasModem then
      add("svc-pkgmirror", "recommended", "HTTP is enabled here, so this server can fetch packages once and serve them to computers with no HTTP")
    end
    add("svc-auth", "optional", "shared login for the other computers")
    add("svc-metrics", "optional", "logs and dashboards")
    if probe.counts.inventories >= 2 then add("svc-storage", "recommended", ("%d inventories attached: storage indexing, auto-sorting and crafting"):format(c.inventories)) end
  end

  -- turtles / pockets ----------------------------------------------------------------------------------------------------
  if kind == "turtle" then
    add("turtle-core", "recommended", "position tracking that survives chunk unloads, fuel management and job queue")
    add("turtle-jobs", "optional", "ready-made mining, farming, tree-felling and building jobs")
    if probe.hasModem then add("gps", "optional", "GPS lets the turtle know where it is") end
  elseif kind == "pocket" then
    add("mobile", "recommended", "phone-style launcher, notifications and quick settings")
    add("remote", "optional", "control turtles and other computers from your pocket")
    if probe.hasModem then add("gps", "optional", "position and maps") end
  end

  -- media / display ------------------------------------------------------------------------------------------------------
  if c.speakers > 0 then add("audio", "optional", ("%d speaker(s): music player and sound effects"):format(c.speakers)) end
  if c.monitors > 0 then
    add("display", "optional", ("%d monitor(s): dashboards and touch screens"):format(c.monitors))
    if c.speakers > 0 or profile == "tv" then add("media", "optional", "video and image player for monitors") end
  end
  if c.printers > 0 then add("print", "optional", "printing tools for the attached printer") end
  if c.drives > 0 then
    add("disk-tools", "optional", "disk drive attached: installer disks, backups and copying")
    add("access-control", "optional", "disk drive attached: keycard doors (with a redstone output for the door)")
  end
  if probe.hasModem and kind == "computer" then
    add("filesync", "optional", "modem attached: keep folders in sync between computers")
  end

  -- storage / power / redstone ---------------------------------------------------------------------------------------------
  if c.inventories >= 2 and profile ~= "server" then
    add("svc-storage", "optional", ("%d inventories attached: storage indexing and auto-sorting"):format(c.inventories))
  end
  if c.energy > 0 then add("power", "optional", ("%d energy storage block(s): power monitoring"):format(c.energy)) end
  if c.fluid > 0 then add("fluids", "optional", ("%d fluid tank(s): fluid monitoring"):format(c.fluid)) end
  if c.redstoneRelays > 0 or profile == "node" then
    add("redstone", "recommended", "redstone control with rules, timers and safe defaults")
  end

  -- mod integrations ----------------------------------------------------------------------------------------------------------
  local reasonFor = function(m) return ("%s peripherals detected (%s)"):format(m.name, m.example) end
  if modSet.advancedperipherals then
    add("integration-advancedperipherals", "recommended", reasonFor(modSet.advancedperipherals))
    if hw.hasTypeMatching(probe, "^meBridge$") then add("integration-ae2", "recommended", "ME Bridge found: Applied Energistics 2 control") end
    if hw.hasTypeMatching(probe, "^rsBridge$") then add("integration-rs", "recommended", "RS Bridge found: Refined Storage control") end
    if hw.hasTypeMatching(probe, "^chatBox$") then add("svc-chatbot", "optional", "Chat Box found: in-game chat commands") end
  end
  if modSet.mekanism then add("integration-mekanism", "recommended", reasonFor(modSet.mekanism)) end
  if modSet.create then add("integration-create", "recommended", reasonFor(modSet.create)) end
  if modSet.tomsperipherals then add("hal-toms", "recommended", reasonFor(modSet.tomsperipherals)) end
  if modSet.plethora then add("integration-plethora", "optional", reasonFor(modSet.plethora)) end

  return items, mods
end

--- Everything at once: { profiles, default, items, mods }.
function M.recommend(probe)
  local profiles, default = M.profiles(probe)
  local items, mods = M.packages(probe, default)
  return { profiles = profiles, default = default, items = items, mods = mods }
end

return M
