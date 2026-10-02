-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Virtual computers: a sandbox with a disk of its own that you can start, leave and come back to.
--   vm create <name> [kb]      a new virtual computer (default disk 200 KB)       vm list      vm delete <name>
--   vm start <name>            run its CraftOS shell on this terminal (type `exit` to leave)
--   vm run <name> <file> [args...]   run one program from the virtual disk
--   vm put <name> <real file> [path in vm]    copy a file in      vm get <name> <path in vm> <real file>   copy a file out
-- A virtual computer cannot see the real file system, network, peripherals or other virtual computers, and cannot shut the real
-- computer down. Its disk is /var/vm/<name>/disk.
local sandbox = require("tsr.sandbox")
local vfs = require("tsr.vfs")

local M = {}

M.DIR = "/var/vm"
M.DEFAULT_QUOTA_KB = 200
M.CPU_SECONDS = 3600

local function validName(name) return type(name) == "string" and name:match("^[%w_%-]+$") ~= nil and #name <= 24 end

local function dir(name) return M.DIR .. "/" .. name end
local function config(name) return vfs.readJSON(dir(name) .. "/vm.json") end

function M.create(name, quotaKb)
  if not validName(name) then return nil, "names use letters, digits, - and _ (up to 24 characters)" end
  if fs.exists(dir(name)) then return nil, "a virtual computer called " .. name .. " already exists" end
  fs.makeDir(dir(name) .. "/disk")
  vfs.writeJSON(dir(name) .. "/vm.json", { name = name, quota = (quotaKb or M.DEFAULT_QUOTA_KB) * 1024, created = os.epoch and os.epoch("utc") or 0 })
  return true
end

function M.list()
  local out = {}
  if not fs.isDir(M.DIR) then return out end
  for _, name in ipairs(fs.list(M.DIR)) do
    local c = config(name)
    if c then out[#out + 1] = { name = name, quota = c.quota } end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

function M.delete(name)
  if not validName(name) or not fs.exists(dir(name)) then return nil, "no such virtual computer: " .. tostring(name) end
  fs.delete(dir(name))
  return true
end

local function open(name)
  local c = validName(name) and config(name)
  if not c then return nil, "no such virtual computer: " .. tostring(name) end
  return c
end

local function jailFor(name, c)
  return sandbox.jail(dir(name) .. "/disk", { quota = c.quota })
end

--- Run a program from the virtual disk. opts: timeout, args. Returns the sandbox results (ok, ...).
function M.run(name, file, opts)
  opts = opts or {}
  local c, err = open(name)
  if not c then return false, err end
  local jail = jailFor(name, c)
  if not jail.exists(file) or jail.isDir(file) then return false, "no such file in the virtual computer: " .. tostring(file) end
  local h = jail.open(file, "r")
  local source = h.readAll()
  h.close()
  return sandbox.run(nil, { fs = jail, source = source, timeout = opts.timeout or M.CPU_SECONDS, args = opts.args, allow = opts.allow })
end

--- Start the CraftOS shell (after /startup.lua if the disk has one) inside the sandbox.
function M.start(name, opts)
  opts = opts or {}
  local c, err = open(name)
  if not c then return false, err end
  local jail = jailFor(name, c)
  local source = [[
    if fs.exists("startup.lua") then dofile("startup.lua") elseif fs.exists("startup") then dofile("startup") end
    local fn, err = loadfile("rom/programs/shell.lua")
    if not fn then error(err, 0) end
    return fn()
  ]]
  local ok, res = sandbox.run(nil, { fs = jail, source = source, timeout = opts.timeout or M.CPU_SECONDS, allow = opts.allow })
  return ok, res
end

--- Copy a real file into the virtual disk.
function M.put(name, realPath, vmPath)
  local c, err = open(name)
  if not c then return nil, err end
  local data = vfs.readFile(realPath, true)
  if not data then return nil, "cannot read " .. tostring(realPath) end
  local jail = jailFor(name, c)
  if #data > jail.getFreeSpace() then return nil, "the virtual disk is full" end
  vmPath = vmPath or fs.getName(realPath)
  local dirOfFile = fs.getDir(vmPath)
  if dirOfFile ~= "" and not jail.exists(dirOfFile) then jail.makeDir(dirOfFile) end
  local h = jail.open(vmPath, "wb")
  h.write(data)
  h.close()
  return true
end

function M.get(name, vmPath, realPath)
  local c, err = open(name)
  if not c then return nil, err end
  local jail = jailFor(name, c)
  if not jail.exists(vmPath) or jail.isDir(vmPath) then return nil, "no such file in the virtual computer: " .. tostring(vmPath) end
  local h = jail.open(vmPath, "rb")
  local data = h.readAll()
  h.close()
  vfs.writeFile(realPath, data, true)
  return true
end

local function defaultIO()
  local io = {}
  function io.say(t) print(t) end
  function io.err(t) if term.isColor() then term.setTextColor(colors.red) end print(t) term.setTextColor(colors.white) end
  return io
end

function M.cli(args, io)
  io = io or defaultIO()
  local cmd = args[1] or "list"
  local function real(p) return (rawget(_G, "shell") and shell.resolve(p)) or p end
  if cmd == "list" then
    local list = M.list()
    if #list == 0 then io.say("No virtual computers. Create one: vm create <name>") end
    for _, v in ipairs(list) do io.say(("%-16s disk %d KB"):format(v.name, math.floor(v.quota / 1024))) end
    return true
  elseif cmd == "create" then
    local ok, err = M.create(args[2], tonumber(args[3]))
    if not ok then io.err(err) return false end
    io.say("Created " .. args[2] .. ". Start it with: vm start " .. args[2])
    return true
  elseif cmd == "delete" then
    local ok, err = M.delete(args[2])
    if not ok then io.err(err) return false end
    io.say("Deleted.")
    return true
  elseif cmd == "start" then
    local ok, res = M.start(args[2])
    if not ok then io.err(tostring(res)) return false end
    term.setBackgroundColor(colors.black) term.setTextColor(colors.white) term.clear() term.setCursorPos(1, 1)
    return true
  elseif cmd == "run" then
    if not args[2] or not args[3] then io.err("usage: vm run <name> <file> [args...]") return false end
    local ok, res = M.run(args[2], args[3], { args = { table.unpack(args, 4) } })
    if not ok then io.err(tostring(res)) return false end
    return true
  elseif cmd == "put" then
    if not args[2] or not args[3] then io.err("usage: vm put <name> <real file> [path in vm]") return false end
    local ok, err = M.put(args[2], real(args[3]), args[4])
    if not ok then io.err(tostring(err)) return false end
    io.say("Copied.")
    return true
  elseif cmd == "get" then
    if not args[2] or not args[3] or not args[4] then io.err("usage: vm get <name> <path in vm> <real file>") return false end
    local ok, err = M.get(args[2], args[3], real(args[4]))
    if not ok then io.err(tostring(err)) return false end
    io.say("Copied.")
    return true
  end
  io.err("usage: vm list | create | delete | start | run | put | get")
  return false
end

function M.main(args) return M.cli(args) end

return M
