-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Settings: appearance (theme, start at boot), system (hostname, profile), services and about.
local W = require("tsr.gui.widgets")
local theme = require("tsr.gui.theme")

local M = {}

local PAGES = { "Appearance", "System", "Services", "About" }

--- Apply a theme everywhere: the theme module, the saved configuration and every open widget window.
function M.applyTheme(name, desktop, config)
  config = config or require("tsr.config")
  local resolved = theme.set(name, desktop and desktop.t.isColor())
  config.set("ui.theme", name, "system")
  if desktop then
    for _, win in ipairs(desktop.wm:list()) do
      if win.root then
        win.term.setBackgroundColor(theme.get().window)
        win.term.setTextColor(theme.get().windowText)
        win.term.clear()
        win.root:render()
      end
    end
    desktop.t.setBackgroundColor(theme.get().desktop)
    desktop.wm:tick(true)
  end
  return resolved
end

local function page(root, name, desktop, ctx)
  local config = ctx.config or require("tsr.config")
  local area = ctx.area
  area:clear()
  if name == "Appearance" then
    area:add(W.label({ x = 1, y = 1, text = "Theme", role = "accent" }))
    local items = {}
    for i, n in ipairs(theme.order) do items[i] = { text = n, name = n } end
    local list = area:add(W.list({ x = 1, y = 2, w = 16, h = #items, items = items }))
    for i, n in ipairs(theme.order) do if n == theme.currentName then list.selected = i end end
    list.onSelect = function(_, item) ctx.message.text = "Theme: " .. M.applyTheme(item.name, desktop, config) end
    local boot = area:add(W.checkbox({ x = 1, y = #items + 3, text = "Start the desktop at boot",
      checked = config.get("ui.default", "shell") == "gui",
      onChange = function(v) config.set("ui.default", v and "gui" or "shell", "system") ctx.message.text = "Saved." end }))
    if not (desktop and desktop.t.isColor()) then
      area:add(W.label({ x = 1, y = #items + 5, w = area.w - 2, h = 2, wrap = true, role = "textDim",
        text = "This computer has no colour screen, so the grey-scale theme is always used." }))
    end
    ctx.focus = list
  elseif name == "System" then
    area:add(W.label({ x = 1, y = 1, text = "Computer name" }))
    local host = area:add(W.input({ x = 1, y = 2, w = 24, text = config.get("net.hostname", os.getComputerLabel() or ("cc-" .. os.getComputerID())) }))
    area:add(W.button({ x = 1, y = 4, text = "Save", primary = true, onClick = function()
      if host.text:match("^[%w_%-%.]+$") then
        config.set("net.hostname", host.text, "system")
        ctx.message.text = "Saved. Network programs pick the name up after the next restart."
      else
        ctx.message.text = "Use letters, digits, - _ . only."
      end
    end }))
    local profile = "unknown"
    pcall(function() profile = require("tsr.profile").get() end)
    area:add(W.label({ x = 1, y = 6, text = "Profile: " .. profile }))
    area:add(W.label({ x = 1, y = 7, text = "Computer id: " .. os.getComputerID() }))
    ctx.focus = host
  elseif name == "Services" then
    local okSvc, svc = pcall(require, "tsr.svc")
    if not okSvc then
      area:add(W.label({ x = 1, y = 1, w = area.w - 2, h = 3, wrap = true, text = "Install the svc-manager package to manage services here." }))
      return
    end
    if #svc.names() == 0 then svc.load() end
    local function items()
      local out = {}
      for i, s in ipairs(svc.list()) do out[i] = { text = ("%-9s %s%s"):format(s.state, s.name, s.enabled and " *" or ""), name = s.name } end
      return out
    end
    local list = area:add(W.list({ x = 1, y = 1, w = area.w - 1, h = area.h - 2, items = items() }))
    local function act(verb)
      local item = list:selectedItem()
      if not item then return end
      local ok, err = svc[verb](item.name)
      ctx.message.text = ok and (verb .. ": " .. item.name) or tostring(err)
      list:setItems(items(), true)
    end
    local x = 1
    for _, verb in ipairs({ "start", "stop", "restart", "enable", "disable" }) do
      local b = area:add(W.button({ x = x, y = area.h, text = verb, onClick = function() act(verb) end }))
      x = x + b.w + 1
    end
    ctx.focus = list
  else
    local v = require("tsr.version")
    area:add(W.label({ x = 1, y = 1, text = v.name .. " " .. v.version, role = "accent" }))
    area:add(W.label({ x = 1, y = 3, w = area.w - 2, h = 6, wrap = true,
      text = "A modular operating system for ComputerCraft computers.\nFree software under the " .. tostring(v.license) .. "." }))
    local okSrc, src = pcall(function() return tsr.sourceInfo().source end)
    if okSrc and src then area:add(W.label({ x = 1, y = 8, w = area.w - 2, h = 2, wrap = true, text = "Source: " .. tostring(src), role = "textDim" })) end
    area:add(W.label({ x = 1, y = 10, w = area.w - 2, h = 2, wrap = true, text = "Contact and support: run `thelp about`.", role = "textDim" }))
  end
end

function M.build(root, win, desktop, opts)
  opts = opts or {}
  local ctx = { config = opts.config }
  local side = root:add(W.list({ x = 1, y = 1, w = 12, h = #PAGES, items = PAGES }))
  ctx.area = root:add(W.panel({ x = 14, y = 1, w = root.w - 13, h = root.h - 2, border = false }))
  ctx.message = root:add(W.label({ x = 1, y = root.h, w = root.w, text = "", role = "textDim" }))
  local function show(name)
    page(root, name, desktop, ctx)
    if ctx.focus then ctx.focus:focus() ctx.focus = nil end
  end
  side.onSelect = function(_, name) ctx.message.text = "" show(name) end
  show(PAGES[1])
  side:focus()
  return { side = side, ctx = ctx, show = show }
end

return M
