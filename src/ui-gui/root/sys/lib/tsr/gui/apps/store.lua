-- SPDX-License-Identifier: AGPL-3.0-or-later
-- App store: browse the package registry, install, remove and update, with the package manager doing the work.
local W = require("tsr.gui.widgets")

local M = {}

--- Rows for the list: { name, version, type, description, installed, tags }, sorted by name; `filter` matches name/description/tags.
function M.rows(pkg, filter)
  local db = require("tsr.pkg.db")
  local found = pkg.search(filter or "") or {}
  local rows = {}
  for _, e in ipairs(found) do
    local rec = db.get(e.name)
    rows[#rows + 1] = {
      name = e.name, version = e.version, type = e.type, description = e.description or "",
      installed = rec ~= nil and not rec.lazy, installedVersion = rec and rec.version, size = e.size,
    }
  end
  table.sort(rows, function(a, b) return a.name < b.name end)
  return rows
end

local function label(r)
  local mark = r.installed and (r.installedVersion and r.installedVersion ~= r.version and "^" or "*") or " "
  return ("%s %-16s %s"):format(mark, r.name, r.version or "")
end

--- opts: pkg (the tsr.pkg module, for tests), progress(text) hook
function M.build(root, win, desktop, opts)
  opts = opts or {}
  local pkg = opts.pkg or require("tsr.pkg")
  local state = { rows = {} }
  local search = root:add(W.input({ x = 1, y = 1, w = root.w, placeholder = "search packages..." }))
  local listH = root.h - 6
  local list = root:add(W.list({ x = 1, y = 2, w = root.w, h = listH }))
  local detail = root:add(W.label({ x = 1, y = listH + 3, w = root.w, h = 2, wrap = true, role = "textDim", text = "" }))
  local status = root:add(W.label({ x = 1, y = root.h - 1, w = root.w, text = "* installed   ^ update available", role = "textDim" }))

  local function redraw()
    root:render()
    if desktop and desktop.wm then desktop.wm:tick(true) end
  end

  local function busy(text)
    status.text = text
    status.role = "accent"
    redraw()
  end

  local function done(text, bad)
    status.text = text
    status.role = bad and "danger" or "ok"
  end

  local function refresh(keep)
    state.rows = M.rows(pkg, search.text)
    local items = {}
    for i, r in ipairs(state.rows) do items[i] = { text = label(r), row = r } end
    list:setItems(items, keep)
    local item = list:selectedItem()
    detail.text = item and (item.row.description) or ""
  end

  list.onSelect = function(_, item) detail.text = item.row.description end
  search.onChange = function() refresh() end

  local function current() local item = list:selectedItem() return item and item.row end

  local x = 1
  local function add(text, fn, primary)
    local b = root:add(W.button({ x = x, y = root.h, text = text, onClick = fn, primary = primary }))
    x = x + b.w + 1
  end
  add("Install", function()
    local r = current()
    if not r then return end
    busy("Installing " .. r.name .. "...")
    local ok, err = pkg.installPackages({ r.name }, { upgrade = r.installed })
    if ok then done("Installed " .. r.name) else done(tostring(err):match("^[^\n]*"), true) end
    refresh(true)
  end, true)
  add("Remove", function()
    local r = current()
    if not r or not r.installed then return end
    busy("Removing " .. r.name .. "...")
    local ok, err = pkg.remove({ r.name })
    if ok then done("Removed " .. r.name) else done(tostring(err):match("^[^\n]*"), true) end
    refresh(true)
  end)
  add("Refresh", function()
    busy("Updating the package list...")
    local res = pkg.update()
    local bad = {}
    for name, v in pairs(res or {}) do if v ~= true then bad[#bad + 1] = name end end
    if #bad == 0 then done("Package list is up to date.") else done("Could not reach: " .. table.concat(bad, ", "), true) end
    refresh(true)
  end)
  add("Upgrade all", function()
    busy("Upgrading...")
    local ok, err = pkg.upgrade()
    if ok then done("Everything is up to date.") else done(tostring(err):match("^[^\n]*"), true) end
    refresh(true)
  end)

  refresh()
  list:focus()
  return { refresh = refresh, list = list, search = search, status = status, detail = detail }
end

return M
