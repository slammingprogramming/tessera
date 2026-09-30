-- SPDX-License-Identifier: AGPL-3.0-or-later
-- disks: everything you want to do with floppy disks and disk drives.
--   disks                      list drives: side, label, id and free space
--   disks info [side]          contents of a disk (files, sizes, free space)
--   disks label <side> <text>  set the label ("" clears it)
--   disks copy <from> <to>     copy a file or folder; a disk side like "right" stands for its mount path
--   disks wipe <side> [-y]     delete everything on a disk
--   disks startup <side> <program>   make the disk run <program> (a path on the disk) when inserted and booted
--   disks eject <side>
local cli = require("tsrapps.cli")
local util = require("tsr.util")

local M = {}

M.SPEC = { yes = "bool", _alias = { y = "yes" } }

local function api(env) return (env and env.disk) or disk end
local function per(env) return (env and env.peripheral) or peripheral end

--- Sides that have a drive attached (with or without a disk).
function M.drives(env)
  local out = {}
  local p = per(env)
  for _, name in ipairs(p.getNames()) do
    if p.getType(name) == "drive" then out[#out + 1] = name end
  end
  return out
end

--- One line describing a drive.
function M.describe(side, env)
  local d = api(env)
  if not d.isPresent(side) then return side .. ": empty" end
  if d.hasAudio and d.hasAudio(side) then return ("%s: music disc \"%s\""):format(side, tostring(d.getAudioTitle and d.getAudioTitle(side) or "?")) end
  local label = d.getLabel(side)
  local mount = d.getMountPath(side)
  local free = mount and fs.getFreeSpace(mount)
  return ("%s: %s (id %s)%s"):format(side, label and ('"' .. label .. '"') or "unlabelled", tostring(d.getID and d.getID(side) or "?"),
    free and (", " .. util.fmtBytes(free) .. " free") or "")
end

--- Resolve "right" to its mount path when it names a drive with a disk; otherwise the text is a path.
function M.resolve(spec, env)
  local d = api(env)
  if d.isPresent(spec) then return d.getMountPath(spec) end
  return spec
end

--- List files under `path`: array of { path, size, dir }.
function M.tree(path)
  local out = {}
  local function walk(p)
    for _, name in ipairs(fs.list(p)) do
      local full = fs.combine(p, name)
      if fs.isDir(full) then
        out[#out + 1] = { path = full, dir = true, size = 0 }
        walk(full)
      else
        out[#out + 1] = { path = full, dir = false, size = fs.getSize(full) }
      end
    end
  end
  walk(path)
  return out
end

--- Delete everything inside `path` (not the path itself). Returns the number of entries removed.
function M.wipe(path)
  local n = 0
  for _, name in ipairs(fs.list(path)) do
    fs.delete(fs.combine(path, name))
    n = n + 1
  end
  return n
end

--- Write a startup file that runs `program` (a path relative to the disk).
function M.makeStartup(mount, program)
  if not fs.exists(fs.combine(mount, program)) then return false, "the disk has no file " .. program end
  local h = fs.open(fs.combine(mount, "startup.lua"), "w")
  if not h then return false, "cannot write startup.lua" end
  h.write('local disk = fs.getDir(shell.getRunningProgram())\nshell.run(fs.combine(disk, "' .. program .. '"))\n')
  h.close()
  return true
end

function M.main(args, io, env)
  io = io or cli.io()
  local pos, opts = cli.parse(args, M.SPEC)
  if not pos then io.err(opts) return false end
  local cmd = pos[1]
  local d = api(env)
  if not cmd then
    local list = M.drives(env)
    if #list == 0 then io.say("No disk drives attached.") return true end
    for _, side in ipairs(list) do io.say(M.describe(side, env)) end
    return true
  end
  local side = pos[2]
  if cmd == "info" then
    side = side or M.drives(env)[1]
    if not side or not d.isPresent(side) then io.err("No disk in " .. tostring(side or "any drive") .. ".") return false end
    io.say(M.describe(side, env))
    local mount = d.getMountPath(side)
    if not mount then return true end
    local total = 0
    for _, f in ipairs(M.tree(mount)) do
      io.say(("  %s%s%s"):format(f.path:gsub("^" .. mount:gsub("%p", "%%%0") .. "/?", ""), f.dir and "/" or "", f.dir and "" or ("  (" .. f.size .. " B)")))
      total = total + f.size
    end
    io.say(("  %d bytes used"):format(total))
  elseif cmd == "label" then
    if not (side and d.isPresent(side)) then io.err("usage: disks label <side> <text> (with a disk in the drive)") return false end
    local text = table.concat(pos, " ", 3)
    d.setLabel(side, text ~= "" and text or nil)
    io.say(text ~= "" and ("Labelled " .. side .. ' "' .. text .. '".') or "Label cleared.")
  elseif cmd == "copy" then
    local from, to = pos[2], pos[3]
    if not (from and to) then io.err("usage: disks copy <from> <to>") return false end
    from, to = M.resolve(from, env), M.resolve(to, env)
    if not fs.exists(from) then io.err("Nothing at " .. from) return false end
    if fs.exists(to) and fs.isDir(to) and not fs.isDir(from) then to = fs.combine(to, fs.getName(from)) end
    if fs.exists(to) then io.err(to .. " already exists") return false end
    fs.copy(from, to)
    io.say(("Copied %s to %s."):format(from, to))
  elseif cmd == "wipe" then
    if not (side and d.isPresent(side)) then io.err("usage: disks wipe <side> [-y]") return false end
    local mount = d.getMountPath(side)
    if not mount then io.err("The disk has no data.") return false end
    if not opts.yes and not io.ask(("Delete EVERYTHING on the disk in %s?"):format(side), false) then io.say("Cancelled.") return false end
    io.say(("Removed %d item(s)."):format(M.wipe(mount)))
  elseif cmd == "startup" then
    local program = pos[3]
    if not (side and program and d.isPresent(side)) then io.err("usage: disks startup <side> <program on the disk>") return false end
    local ok, err = M.makeStartup(d.getMountPath(side), program)
    if not ok then io.err(err) return false end
    io.say("The disk now runs " .. program .. " when a computer boots from it.")
  elseif cmd == "eject" then
    if not (side and d.isPresent(side)) then io.err("Nothing to eject.") return false end
    d.eject(side)
    io.say("Ejected.")
  else
    io.say("usage: disks [info|label|copy|wipe|startup|eject] ...")
    return false
  end
  return true
end

return M
