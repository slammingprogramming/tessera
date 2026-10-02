-- SPDX-License-Identifier: AGPL-3.0-or-later
-- fm: a file manager for any screen, built on the text UI toolkit (keyboard first, mouse where available).
--   Enter opens a folder or shows the actions for a file.  Backspace goes up a folder, or leaves at the top.
local vfs = require("tsr.vfs")

local M = {}

---------------------------------------------------------------------------------------------------------------------
-- Model
---------------------------------------------------------------------------------------------------------------------

local function human(n)
  if n >= 1048576 then return ("%.1fM"):format(n / 1048576) elseif n >= 1024 then return ("%.1fk"):format(n / 1024) end
  return n .. "B"
end
M.human = human

--- Folder listing: directories first, each group alphabetical.
function M.entries(path)
  local ok, names = pcall(fs.list, path)
  if not ok then return nil, tostring(names) end
  local out = {}
  for _, name in ipairs(names) do
    local full = vfs.join(path, name)
    local dir = fs.isDir(full)
    out[#out + 1] = { name = name, path = full, dir = dir, size = dir and 0 or (select(2, pcall(fs.getSize, full)) or 0) }
  end
  table.sort(out, function(a, b)
    if a.dir ~= b.dir then return a.dir end
    return a.name:lower() < b.name:lower()
  end)
  return out
end

local function protected(path) return path == "/" or path == "/rom" or path:sub(1, 5) == "/rom/" end

local function validName(name) return name ~= "" and not name:find("[/\\]") and name ~= "." and name ~= ".." end

--- Copy a file or a whole folder. Returns true or nil + reason.
function M.copy(from, to)
  if fs.exists(to) then return nil, "the destination already exists" end
  local ok, err = pcall(fs.copy, from, to)
  if not ok then return nil, tostring(err) end
  return true
end

function M.move(from, to)
  if protected(from) then return nil, "this cannot be moved" end
  if fs.exists(to) then return nil, "the destination already exists" end
  local ok, err = pcall(fs.move, from, to)
  if not ok then return nil, tostring(err) end
  return true
end

function M.delete(path)
  if protected(path) then return nil, "this cannot be deleted" end
  local okTrash, trash = pcall(require, "tsr.trash")      -- the safety package's recycle bin, when installed
  if okTrash then return trash.discard(path) end
  local ok, err = pcall(fs.delete, path)
  if not ok then return nil, tostring(err) end
  return true
end

function M.mkdir(parent, name)
  if not validName(name) then return nil, "not a valid name" end
  local path = vfs.join(parent, name)
  if fs.exists(path) then return nil, "already exists" end
  local ok, err = pcall(fs.makeDir, path)
  if not ok then return nil, tostring(err) end
  return true
end

function M.rename(path, newName)
  if not validName(newName) then return nil, "not a valid name" end
  return M.move(path, vfs.join(vfs.dirname(path), newName))
end

--- Text for the info screen.
function M.info(path)
  local lines = { "Path: " .. path }
  if fs.isDir(path) then
    local n, bytes = 0, 0
    local function walk(p)
      for _, name in ipairs(fs.list(p)) do
        local full = vfs.join(p, name)
        if fs.isDir(full) then walk(full) else n = n + 1 bytes = bytes + fs.getSize(full) end
      end
    end
    pcall(walk, path)
    lines[#lines + 1] = ("Folder: %d files, %s"):format(n, human(bytes))
  else
    lines[#lines + 1] = "Size: " .. human(fs.getSize(path))
  end
  if fs.attributes then
    local ok, a = pcall(fs.attributes, path)
    if ok and type(a) == "table" then
      if a.modified and a.modified > 0 then lines[#lines + 1] = "Modified: " .. os.date("%Y-%m-%d %H:%M", a.modified / 1000) end
      if a.isReadOnly then lines[#lines + 1] = "Read-only" end
    end
  end
  return lines
end

---------------------------------------------------------------------------------------------------------------------
-- Screens
---------------------------------------------------------------------------------------------------------------------

--- opts: path (start), ui (the tui module, for tests), run(line) (execute a command line), edit(path)
function M.run(opts)
  opts = opts or {}
  local ui = opts.ui or require("tsr.ui.tui")
  local path = vfs.normalize(opts.path or "/")
  local clipboard
  local run = opts.run or function(line)
    term.clear() term.setCursorPos(1, 1)
    shell.run(line)
    print() print("Press any key") os.pullEvent("key")
  end
  local edit = opts.edit or function(p)
    local okEd = fs.exists("/sys/bin/ted.lua")
    run((okEd and "ted " or "edit ") .. p)
  end

  local function message(title, text) ui.message(title, type(text) == "table" and text or { text }) end

  local function ask(title, prompt, default) return ui.input(title, prompt, default) end

  local function fileActions(e)
    local items = {
      { label = "Open / edit" }, { label = "Run" }, { label = "View info" }, { label = "Copy" }, { label = "Move" },
      { label = "Rename" }, { label = "Delete" }, { label = "Cancel" },
    }
    if e.dir then items = { { label = "View info" }, { label = "Copy" }, { label = "Move" }, { label = "Rename" }, { label = "Delete" }, { label = "Cancel" } } end
    local pick = ui.menu(e.name, items)
    if not pick then return end
    local label = items[pick].label
    if label == "Open / edit" then edit(e.path)
    elseif label == "Run" then run(e.path)
    elseif label == "View info" then message(e.name, M.info(e.path))
    elseif label == "Copy" then clipboard = { path = e.path, cut = false } message("Copy", e.name .. " is ready to paste")
    elseif label == "Move" then clipboard = { path = e.path, cut = true } message("Move", e.name .. " is ready to paste")
    elseif label == "Rename" then
      local name = ask("Rename", "New name:", e.name)
      if name and name ~= "" then
        local ok, err = M.rename(e.path, name)
        if not ok then message("Rename failed", err) end
      end
    elseif label == "Delete" then
      if ui.confirm("Delete", { "Delete " .. e.name .. (e.dir and " and everything in it?" or "?") }, { default = false }) then
        local ok, err = M.delete(e.path)
        if not ok then message("Delete failed", err) end
      end
    end
  end

  while true do
    local entries, err = M.entries(path)
    if not entries then message("Cannot open " .. path, err) entries = {} end
    local items = {}
    if path ~= "/" then items[#items + 1] = { label = "../", desc = "Go up" } end
    for _, e in ipairs(entries) do
      items[#items + 1] = { label = e.name .. (e.dir and "/" or ""), tag = e.dir and "" or human(e.size) }
    end
    items[#items + 1] = { label = "[ New folder ]" }
    if path ~= "/" then items[#items + 1] = { label = "[ Folder actions ]", desc = "Copy, move, rename or delete this folder" } end
    if clipboard then items[#items + 1] = { label = "[ Paste " .. vfs.basename(clipboard.path) .. " here ]" } end
    items[#items + 1] = { label = "[ Quit ]" }
    local pick = ui.menu(path, items, { footer = "Enter select  Bksp up/quit" })
    if not pick then
      if path == "/" then return end
      path = vfs.dirname(path)
    else
      local item = items[pick]
      if item.label == "../" then path = vfs.dirname(path)
      elseif item.label == "[ Quit ]" then return
      elseif item.label == "[ Folder actions ]" then
        local here = path
        fileActions({ name = vfs.basename(here), path = here, dir = true })
        if not fs.exists(here) then path = vfs.dirname(here) end
      elseif item.label == "[ New folder ]" then
        local name = ask("New folder", "Name:", "")
        if name and name ~= "" then
          local ok, e2 = M.mkdir(path, name)
          if not ok then message("Cannot create", e2) end
        end
      elseif item.label:sub(1, 8) == "[ Paste " then
        local target = vfs.join(path, vfs.basename(clipboard.path))
        local ok, e2 = (clipboard.cut and M.move or M.copy)(clipboard.path, target)
        if ok then
          if clipboard.cut then clipboard = nil end
        else
          message("Paste failed", e2)
        end
      else
        local offset = (path ~= "/") and 1 or 0
        local e = entries[pick - offset]
        if e then
          if e.dir then path = e.path else fileActions(e) end
        end
      end
    end
  end
end

return M
