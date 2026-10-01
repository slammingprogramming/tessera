-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Fleet control for turtles.
--   On each turtle:        the fleetd service offers the "turtle" service to paired computers that are on its allow list
--   On the controller:     fleet list | run <turtle|all> <job> [args] | stop <turtle|all> | goto <turtle> x y z | log <turtle>
--                          fleet add <peer> | remove <peer> | roster | allow <peer> | deny <peer> | allowed
-- Jobs are the installed turtle programs (bore, carve, stripmine, quarry, build, treefarm, cropfarm, cobblegen, guard,
-- tresume): a remote turtle runs only programs on its job whitelist, never arbitrary commands. Everything travels over
-- paired, signed (and for `run`, encrypted) net calls.
local vfs = require("tsr.vfs")

local M = {}

M.ROSTER_PATH = "/etc/tsr/fleet.roster"
M.ALLOW_PATH = "/etc/tsr/fleet.allow"
M.JOB_DIR = "/usr/bin"
M.JOBS = { "bore", "carve", "stripmine", "quarry", "build", "treefarm", "cropfarm", "cobblegen", "guard", "tresume", "excavate" }
M.LOG_MAX = 4000

---------------------------------------------------------------------------------------------------------------------
-- Turtle side
---------------------------------------------------------------------------------------------------------------------

local current = nil     -- { pid, name, args, cap, started } for the running remote job

function M.allowed() return vfs.readTable(M.ALLOW_PATH) or {} end

local function isAllowed(peer)
  for _, n in ipairs(M.allowed()) do if n == peer.name then return true end end
  return false
end

local function jobAllowed(name)
  for _, j in ipairs(M.JOBS) do if j == name then return true end end
  return false
end

--- Start a program as a background process with captured output. Replaceable in tests. Returns pid.
function M.spawnJob(path, args, cap)
  local kernel = require("tsr.kernel")
  return kernel.spawn({
    name = "fleet-job", term = cap.term, daemon = true,
    fn = function()
      local fn, err = loadfile(path, "t", setmetatable({ shell = rawget(_G, "shell") }, { __index = _G }))
      if not fn then printError(tostring(err)) return end
      local ok, e = pcall(fn, table.unpack(args))
      if not ok then printError(tostring(e)) end
    end,
  })
end

local function jobAlive()
  if not current then return false end
  local okK, kernel = pcall(require, "tsr.kernel")
  if not okK then return false end
  return kernel.get(current.pid) ~= nil
end

function M.status(node)
  local T = require("tsr.turtle")
  local x, y, z, dir = T.pos()
  local s = {
    host = node and node.hostname or os.getComputerLabel(), id = os.getComputerID(),
    x = x, y = y, z = z, dir = dir, fuel = turtle and turtle.getFuelLevel() or 0, fuelLimit = turtle and turtle.getFuelLimit() or 0,
    busy = jobAlive(),
  }
  if current and s.busy then s.job = current.name .. " " .. table.concat(current.args, " ") end
  local saved = T.job.get()
  if saved and saved.name then s.saved = saved.name end
  local free = 0
  if turtle then for i = 1, 16 do if turtle.getItemCount(i) == 0 then free = free + 1 end end end
  s.freeSlots = free
  return s
end

--- Register the "turtle" service on `node`.
function M.serve(node)
  node:serve("turtle", function(from, method, a)
    if method == "status" then
      return M.status(node)
    elseif method == "run" then
      if type(a) ~= "table" or type(a.job) ~= "string" then error("need a job name", 0) end
      if not jobAllowed(a.job) then error("job not allowed: " .. a.job, 0) end
      if jobAlive() then error("busy with " .. current.name, 0) end
      local path = M.JOB_DIR .. "/" .. a.job .. ".lua"
      if not fs.exists(path) then error("this turtle does not have " .. a.job, 0) end
      local args = {}
      for _, v in ipairs(a.args or {}) do args[#args + 1] = tostring(v) end
      local cap = require("tsr.shell.capture").new()
      local pid, err = M.spawnJob(path, args, cap)
      if not pid then error("cannot start: " .. tostring(err), 0) end
      current = { pid = pid, name = a.job, args = args, cap = cap, started = os.clock() }
      return { pid = pid }
    elseif method == "stop" then
      if not jobAlive() then current = nil return false end
      local kernel = require("tsr.kernel")
      kernel.terminate(current.pid)
      if kernel.get(current.pid) then kernel.kill(current.pid) end
      return true
    elseif method == "goto" then
      if type(a) ~= "table" or not (tonumber(a.x) and tonumber(a.y) and tonumber(a.z)) then error("need x, y and z", 0) end
      if jobAlive() then error("busy with " .. current.name, 0) end
      local ok, why = require("tsr.turtle.nav").goto(tonumber(a.x), tonumber(a.y), tonumber(a.z), { dig = a.dig == true })
      if not ok then error(tostring(why), 0) end
      return true
    elseif method == "log" then
      if not current then return "" end
      local text = current.cap.text()
      if #text > M.LOG_MAX then text = text:sub(-M.LOG_MAX) end
      return text
    end
    error("unknown method " .. tostring(method), 0)
  end, { allow = isAllowed, async = true })
end

function M.reset() current = nil end

---------------------------------------------------------------------------------------------------------------------
-- Controller side
---------------------------------------------------------------------------------------------------------------------

function M.roster() return vfs.readTable(M.ROSTER_PATH) or {} end

local function saveList(path, list) vfs.writeTable(path, list) end

local function without(list, name)
  local out = {}
  for _, n in ipairs(list) do if n ~= name then out[#out + 1] = n end end
  return out
end

--- Names a command applies to: one turtle, or the whole roster for "all".
local function targets(arg)
  if arg == "all" then return M.roster() end
  return { arg }
end

--- Ask every roster turtle for its status. Returns an array of { name, ok, status | error }.
function M.poll(node, names)
  names = names or M.roster()
  local out = {}
  local fns = {}
  for i, name in ipairs(names) do
    fns[i] = function()
      local res, err = node:call(name, "turtle", "status", nil, { timeout = 4 })
      out[i] = { name = name, ok = res ~= nil, status = res, error = err }
    end
  end
  if #fns > 0 then parallel.waitForAll(table.unpack(fns)) end
  return out
end

local DIRNAMES = { [0] = "N", "E", "S", "W" }

local function row(r)
  if not r.ok then return ("%-14s offline (%s)"):format(r.name, tostring(r.error)) end
  local s = r.status
  return ("%-14s %5d,%4d,%5d %s  fuel %s/%s  %s%s"):format(r.name, s.x, s.y, s.z, DIRNAMES[s.dir] or "?", tostring(s.fuel),
    tostring(s.fuelLimit), s.busy and ("busy: " .. tostring(s.job)) or "idle", s.saved and ("  [saved job " .. s.saved .. "]") or "")
end
M.row = row

local function defaultIO()
  local io = {}
  local function color(c) if term.isColor() then term.setTextColor(c) end end
  function io.say(t) print(t) end
  function io.err(t) color(colors.red) print(t) color(colors.white) end
  return io
end

function M.run(args, io, node)
  io = io or defaultIO()
  node = node or require("tsr.net").default()
  local cmd = args[1] or "list"

  if cmd == "list" then
    local roster = M.roster()
    if #roster == 0 then io.say("The roster is empty. Pair a turtle (net pair), then: fleet add <name>") return true end
    for _, r in ipairs(M.poll(node, roster)) do io.say(row(r)) end
    return true
  elseif cmd == "add" or cmd == "remove" then
    if not args[2] then io.err("usage: fleet " .. cmd .. " <peer name>") return false end
    local list = without(M.roster(), args[2])
    if cmd == "add" then
      if not node:peer(args[2]) then io.err("warning: " .. args[2] .. " is not paired yet (net pair)") end
      list[#list + 1] = args[2]
    end
    saveList(M.ROSTER_PATH, list)
    io.say(cmd == "add" and ("Added " .. args[2] .. ".") or ("Removed " .. args[2] .. "."))
    return true
  elseif cmd == "roster" then
    local list = M.roster()
    io.say(#list > 0 and table.concat(list, ", ") or "empty")
    return true
  elseif cmd == "allow" or cmd == "deny" then
    if not args[2] then io.err("usage: fleet " .. cmd .. " <controller name>   (run on the turtle)") return false end
    local list = without(M.allowed(), args[2])
    if cmd == "allow" then list[#list + 1] = args[2] end
    saveList(M.ALLOW_PATH, list)
    io.say(cmd == "allow" and (args[2] .. " may now control this turtle.") or (args[2] .. " may no longer control this turtle."))
    return true
  elseif cmd == "allowed" then
    local list = M.allowed()
    io.say(#list > 0 and table.concat(list, ", ") or "Nobody may control this turtle.")
    return true
  elseif cmd == "run" then
    local who, job = args[2], args[3]
    if not who or not job then io.err("usage: fleet run <turtle|all> <job> [args...]") return false end
    local jobArgs = { table.unpack(args, 4) }
    local allOk = true
    for _, name in ipairs(targets(who)) do
      local res, err = node:call(name, "turtle", "run", { job = job, args = jobArgs }, { timeout = 6, encrypt = true })
      if res then io.say(name .. ": started " .. job) else io.err(name .. ": " .. tostring(err)) allOk = false end
    end
    return allOk
  elseif cmd == "stop" then
    if not args[2] then io.err("usage: fleet stop <turtle|all>") return false end
    local allOk = true
    for _, name in ipairs(targets(args[2])) do
      local res, err = node:call(name, "turtle", "stop", nil, { timeout = 5 })
      if res == nil then io.err(name .. ": " .. tostring(err)) allOk = false
      else io.say(name .. (res and ": stopped" or ": nothing was running")) end
    end
    return allOk
  elseif cmd == "goto" then
    local name, x, y, z = args[2], tonumber(args[3]), tonumber(args[4]), tonumber(args[5])
    if not (name and x and y and z) then io.err("usage: fleet goto <turtle> <x> <y> <z> [dig]") return false end
    local res, err = node:call(name, "turtle", "goto", { x = x, y = y, z = z, dig = args[6] == "dig" }, { timeout = 120 })
    if not res then io.err(name .. ": " .. tostring(err)) return false end
    io.say(name .. ": arrived")
    return true
  elseif cmd == "log" then
    if not args[2] then io.err("usage: fleet log <turtle>") return false end
    local res, err = node:call(args[2], "turtle", "log", nil, { timeout = 5 })
    if res == nil then io.err(tostring(err)) return false end
    io.say(res == "" and "(no output)" or res)
    return true
  end
  io.err("usage: fleet list | add|remove <peer> | roster | run <t|all> <job> | stop <t|all> | goto <t> x y z | log <t> | allow|deny|allowed")
  return false
end

function M.main(args) return M.run(args) end

--- The fleetd service (on turtles).
function M.daemon()
  M.serve(require("tsr.net").default())
  while true do os.pullEvent("fleet_never") end
end

return M
