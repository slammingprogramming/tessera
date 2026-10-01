-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Command-line front ends for the auth package: useradd, userdel, usermod, passwd, users, whoami, su, sudo, lock.
-- Each function is (args, io) -> boolean; io has say, err and secret so tests can script it.
local auth = require("tsr.auth")

local M = {}

local function defaultIO()
  local io = {}
  local function color(c) if term.isColor() then term.setTextColor(c) end end
  function io.say(t) print(t) end
  function io.err(t) color(colors.red) print(t) color(colors.white) end
  function io.secret(prompt) write(prompt .. ": ") return read("*") end
  return io
end

--- Allowed when nobody has an account yet (bootstrap), when nobody is logged in (the system itself), or for administrators.
local function needAdmin(io)
  if not auth.hasUsers() then return true end
  local me = auth.current()
  if me == nil or auth.can(me, "auth.manage") then return true end
  io.err("only administrators can do that")
  return false
end

local function askNewPassword(io, who)
  local a = io.secret("New password for " .. who)
  if a == nil then io.err("cancelled") return nil end
  local b = io.secret("Repeat password")
  if a ~= b then io.err("the passwords do not match") return nil end
  return a
end

function M.useradd(args, io)
  io = io or defaultIO()
  if not needAdmin(io) then return false end
  local name, role = nil, nil
  local i = 1
  while i <= #args do
    if args[i] == "--role" then role = args[i + 1] i = i + 2
    elseif args[i] == "--admin" then role = "admin" i = i + 1
    else name = name or args[i] i = i + 1 end
  end
  if not name then io.err("usage: useradd <name> [--admin | --role admin|user|guest]") return false end
  if not auth.hasUsers() then role = "admin" end      -- the first account must be able to manage the others
  local pass = askNewPassword(io, name)
  if not pass then return false end
  local ok, err = auth.addUser(name, pass, { role = role })
  if not ok then io.err(err) return false end
  io.say("User " .. name .. " created" .. ((role == "admin") and " (administrator)" or "") .. ".")
  return true
end

function M.userdel(args, io)
  io = io or defaultIO()
  if not needAdmin(io) then return false end
  if not args[1] then io.err("usage: userdel <name>") return false end
  local ok, err = auth.removeUser(args[1])
  if not ok then io.err(err) return false end
  io.say("User " .. args[1] .. " removed (the home directory was kept).")
  return true
end

function M.usermod(args, io)
  io = io or defaultIO()
  if not needAdmin(io) then return false end
  local name = args[1]
  if not name or not args[2] then io.err("usage: usermod <name> --role <role> | --lock | --unlock") return false end
  local ok, err
  if args[2] == "--role" then ok, err = auth.setRole(name, args[3] or "")
  elseif args[2] == "--lock" then ok, err = auth.setLocked(name, true)
  elseif args[2] == "--unlock" then ok, err = auth.setLocked(name, false)
  else io.err("unknown option " .. args[2]) return false end
  if not ok then io.err(err) return false end
  io.say("Updated " .. name .. ".")
  return true
end

function M.passwd(args, io)
  io = io or defaultIO()
  local me = auth.current()
  local target = args[1] or me
  if not target or target == auth.ROOT then io.err("usage: passwd <user>") return false end
  if target ~= me then
    if not needAdmin(io) then return false end
  else
    local old = io.secret("Current password")
    if old == nil or not auth.verify(target, old) then io.err("wrong password") return false end
  end
  local pass = askNewPassword(io, target)
  if not pass then return false end
  local ok, err = auth.setPassword(target, pass)
  if not ok then io.err(err) return false end
  io.say("Password changed.")
  return true
end

function M.users(_, io)
  io = io or defaultIO()
  local list = auth.list()
  if #list == 0 then io.say("No users: the system is open (create the first with useradd).") return true end
  for _, u in ipairs(list) do
    io.say(("%-16s %-6s %s%s"):format(u.name, u.role, u.home, u.locked and "  (locked)" or ""))
  end
  return true
end

function M.whoami(_, io)
  io = io or defaultIO()
  io.say(auth.current() or "system")
  return true
end

--- `sudo <command...>` runs the command unrestricted after the current administrator retypes their password.
function M.sudo(args, io, run)
  io = io or defaultIO()
  local me = auth.current()
  if not me then io.err("sudo: not logged in") return false end
  if me == auth.ROOT then io.err("sudo: already unrestricted") return false end
  if #args == 0 then io.err("usage: sudo <command> [args...]") return false end
  if not auth.can(me, "auth.sudo") then io.err(me .. " is not allowed to use sudo") return false end
  local pass = io.secret("Password for " .. me)
  if pass == nil or not auth.verify(me, pass) then io.err("sudo: wrong password") return false end
  run = run or function() return shell.run(table.concat(args, " ")) end
  return auth.asUser(auth.ROOT, run)
end

--- `su <user>`: a new shell as that user after their password.
function M.su(args, io, run)
  io = io or defaultIO()
  local name = args[1]
  if not name then io.err("usage: su <user>") return false end
  local pass = io.secret("Password for " .. name)
  local user = pass and auth.verify(name, pass)
  if not user then io.err("su: authentication failed") return false end
  run = run or function()
    local okRepl, repl = pcall(require, "tsr.shell.repl")
    if okRepl then
      local exec = require("tsr.shell.exec")
      return repl.run(exec.new({ parentShell = rawget(_G, "shell"), home = user.home, user = name }))
    end
    return shell.run("/rom/programs/shell.lua")
  end
  return auth.asUser(name, run)
end

function M.lock(_, io)
  local ok, why = require("tsr.login").lock({ io = io and io.lockIO })
  if not ok then (io or defaultIO()).err(why or "cannot lock") end
  return ok
end

return M
