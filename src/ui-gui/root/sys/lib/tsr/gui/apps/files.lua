-- SPDX-License-Identifier: AGPL-3.0-or-later
-- File manager: browse folders, open files, make folders, rename and delete.
local W = require("tsr.gui.widgets")
local vfs = require("tsr.vfs")

local M = {}

---------------------------------------------------------------------------------------------------------------------
-- Model (no UI): everything the window does to the file system
---------------------------------------------------------------------------------------------------------------------

local function human(n)
  if n >= 1024 * 1024 then return ("%.1fM"):format(n / 1048576) end
  if n >= 1024 then return ("%.1fk"):format(n / 1024) end
  return tostring(n) .. "B"
end
M.human = human

--- Entries of a folder: directories first, then files, each alphabetical. Returns { {name, dir, size, path, readonly} ... }.
function M.entries(path)
  path = vfs.normalize(path)
  local out = {}
  local ok, names = pcall(fs.list, path)
  if not ok then return nil, tostring(names) end
  for _, name in ipairs(names) do
    local full = vfs.join(path, name)
    local isDir = fs.isDir(full)
    local okSize, size = pcall(fs.getSize, full)
    out[#out + 1] = { name = name, dir = isDir, size = (okSize and not isDir) and size or 0, path = full,
                      readonly = (fs.isReadOnly and fs.isReadOnly(full)) or false }
  end
  table.sort(out, function(a, b)
    if a.dir ~= b.dir then return a.dir end
    return a.name:lower() < b.name:lower()
  end)
  return out
end

--- The label shown in the list.
function M.label(e)
  if e.dir then return e.name .. "/" end
  return ("%s  (%s)"):format(e.name, human(e.size))
end

local function validName(name)
  return type(name) == "string" and name ~= "" and not name:find("[/\\]") and name ~= "." and name ~= ".."
end

function M.makeDir(parent, name)
  if not validName(name) then return nil, "that is not a valid folder name" end
  local path = vfs.join(parent, name)
  if fs.exists(path) then return nil, name .. " already exists" end
  local ok, err = pcall(fs.makeDir, path)
  if not ok then return nil, tostring(err) end
  return true
end

function M.rename(path, newName)
  if not validName(newName) then return nil, "that is not a valid name" end
  local target = vfs.join(vfs.dirname(path), newName)
  if fs.exists(target) then return nil, newName .. " already exists" end
  local ok, err = pcall(fs.move, path, target)
  if not ok then return nil, tostring(err) end
  return true
end

function M.delete(path)
  if path == "/" or path == "/rom" or path:sub(1, 5) == "/rom/" then return nil, "this cannot be deleted" end
  local ok, err = pcall(fs.delete, path)
  if not ok then return nil, tostring(err) end
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------------------------------------------------

--- Build the file manager on `root`. opts: path (start folder), open(path) (what to do with a file; default: edit it).
function M.build(root, win, desktop, opts)
  opts = opts or {}
  local state = { path = vfs.normalize(opts.path or "/"), entries = {} }
  local pathInput = root:add(W.input({ x = 1, y = 1, w = root.w, text = state.path }))
  local list = root:add(W.list({ x = 1, y = 2, w = root.w, h = root.h - 4 }))
  local status = root:add(W.label({ x = 1, y = root.h - 2, w = root.w, text = "", role = "textDim" }))
  local buttons = {}

  local function say(text, danger)
    status.text = text
    status.role = danger and "danger" or "textDim"
  end

  local function refresh()
    local entries, err = M.entries(state.path)
    if not entries then say(err, true) return end
    state.entries = entries
    local items = {}
    if state.path ~= "/" then items[1] = { text = "../", up = true } end
    for _, e in ipairs(entries) do items[#items + 1] = { text = M.label(e), entry = e } end
    list:setItems(items)
    pathInput:setText(state.path)
    local free = require("tsr.util").freeSpace(state.path)
    say(("%d items  -  free %s"):format(#entries, free == math.huge and "unlimited" or human(free)))
  end

  local function go(path)
    if not fs.isDir(path) then say("not a folder: " .. path, true) return end
    state.path = vfs.normalize(path)
    refresh()
  end

  local function openItem(item)
    if not item then return end
    if item.up then go(vfs.dirname(state.path)) return end
    local e = item.entry
    if e.dir then go(e.path) return end
    if opts.open then opts.open(e.path)
    elseif desktop and desktop.launch then desktop:launch({ name = e.name, w = 46, h = 15, program = "edit " .. e.path }) end
  end

  list.onActivate = function(_, item) openItem(item) end
  pathInput.onSubmit = function(text) go(text) end

  local function selected()
    local item = list:selectedItem()
    return item and item.entry
  end

  local function button(x, text, fn)
    local b = root:add(W.button({ x = x, y = root.h, text = text, onClick = fn }))
    buttons[#buttons + 1] = b
    return b
  end

  local x = 1
  for _, def in ipairs({
    { "Up", function() go(vfs.dirname(state.path)) end },
    { "Open", function() openItem(list:selectedItem()) end },
    { "New", function()
        local nameInput = W.input({ x = 2, y = 2, w = 20 })
        local dlg = W.panel({ title = "New folder", x = 3, y = math.max(2, math.floor(root.h / 2) - 2), w = 26, h = 6 })
        dlg:add(nameInput)
        local function create()
          local ok, err = M.makeDir(state.path, nameInput.text)
          root:remove(dlg)
          if ok then refresh() else say(err, true) end
        end
        nameInput.onSubmit = create
        dlg:add(W.button({ x = 2, y = 4, text = "Create", onClick = create }))
        dlg:add(W.button({ x = 12, y = 4, text = "Cancel", onClick = function() root:remove(dlg) end }))
        root:add(dlg)
        nameInput:focus()
      end },
    { "Rename", function()
        local e = selected()
        if not e then say("select something first", true) return end
        local nameInput = W.input({ x = 2, y = 2, w = 20, text = e.name })
        local dlg = W.panel({ title = "Rename", x = 3, y = math.max(2, math.floor(root.h / 2) - 2), w = 26, h = 6 })
        dlg:add(nameInput)
        local function apply()
          local ok, err = M.rename(e.path, nameInput.text)
          root:remove(dlg)
          if ok then refresh() else say(err, true) end
        end
        nameInput.onSubmit = apply
        dlg:add(W.button({ x = 2, y = 4, text = "Rename", onClick = apply }))
        dlg:add(W.button({ x = 12, y = 4, text = "Cancel", onClick = function() root:remove(dlg) end }))
        root:add(dlg)
        nameInput:focus()
      end },
    { "Delete", function()
        local e = selected()
        if not e then say("select something first", true) return end
        W.dialog(root, { title = "Delete", text = "Delete " .. e.name .. (e.dir and " and everything in it?" or "?"), buttons = { "Yes", "No" },
          restoreFocus = list, onChoice = function(choice)
            if choice == "Yes" then
              local ok, err = M.delete(e.path)
              if ok then refresh() else say(err, true) end
            end
          end })
      end },
  }) do
    local b = button(x, def[1], def[2])
    x = x + b.w + 1
  end

  refresh()
  list:focus()
  return { go = go, refresh = refresh, state = state, list = list, status = status }
end

return M
