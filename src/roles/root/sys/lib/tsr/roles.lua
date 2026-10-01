-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Roles: named bundles of packages, services and settings. A role file in /etc/tsr/roles.d/<name>.lua looks like
--   return {
--     description = "what this computer becomes",
--     packages = { "net", "ops" },        -- installed when missing
--     services = { "netd", "metricsd" },  -- enabled (start at boot) and started
--     config = { ["net.hostname"] = "hub" },   -- optional settings written to the system layer
--     notes = "what to do next",
--   }
-- Any package can ship role files; `role apply <name>` does the work, `role remove <name>` turns the services off again
-- (installed packages stay).
local vfs = require("tsr.vfs")

local M = {}

M.dir = "/etc/tsr/roles.d"
M.statePath = "/etc/tsr/roles.state"

--- All defined roles: name -> definition. Returns the map and a list of problems.
function M.load()
  local roles, problems = {}, {}
  if fs.isDir(M.dir) then
    for _, f in ipairs(fs.list(M.dir)) do
      if f:match("%.lua$") then
        local name = f:gsub("%.lua$", "")
        local chunk, err = loadfile(M.dir .. "/" .. f, "t", {})
        local ok, def
        if chunk then ok, def = pcall(chunk) else ok, def = false, err end
        if ok and type(def) == "table" and type(def.description) == "string" then
          def.name = name
          def.packages = def.packages or {}
          def.services = def.services or {}
          roles[name] = def
        else
          problems[#problems + 1] = f .. ": " .. tostring(def)
        end
      end
    end
  end
  return roles, problems
end

function M.names()
  local out = {}
  for n in pairs((M.load())) do out[#out + 1] = n end
  table.sort(out)
  return out
end

local function applied() return (vfs.readTable(M.statePath) or {}).applied or {} end

local function setApplied(name, value)
  local st = vfs.readTable(M.statePath) or {}
  st.applied = st.applied or {}
  st.applied[name] = value
  vfs.writeTable(M.statePath, st)
end

function M.isApplied(name) return applied()[name] == true end

--- What `apply` would do. Returns { role, missing = {packages}, services = {...}, config = {...} } or nil + error.
function M.plan(name)
  local role = (M.load())[name]
  if not role then return nil, "no such role: " .. tostring(name) end
  local db = require("tsr.pkg.db")
  local missing = {}
  for _, p in ipairs(role.packages) do
    local rec = db.get(p)
    if not rec or rec.lazy then missing[#missing + 1] = p end
  end
  return { role = role, missing = missing, services = role.services, config = role.config or {} }
end

--- Apply a role. opts: install (default true; false = never touch packages), start (default true).
--- Returns a result { installed = {...}, enabled = {...}, started = {...}, problems = {...}, notes = "" } or nil + error.
function M.apply(name, opts)
  opts = opts or {}
  local plan, err = M.plan(name)
  if not plan then return nil, err end
  local result = { installed = {}, enabled = {}, started = {}, problems = {}, notes = plan.role.notes }

  if #plan.missing > 0 then
    if opts.install == false then
      result.problems[#result.problems + 1] = "missing packages: " .. table.concat(plan.missing, ", ")
    else
      local ok, e = require("tsr.pkg").installPackages(plan.missing, opts.pkgOpts)
      if not ok then return nil, "installing " .. table.concat(plan.missing, ", ") .. " failed: " .. tostring(e) end
      result.installed = plan.missing
    end
  end

  for key, value in pairs(plan.config) do require("tsr.config").set(key, value, "system") end

  local svc = require("tsr.svc")
  svc.load()          -- definitions that arrived with the packages
  for _, s in ipairs(plan.services) do
    local ok, e = svc.enable(s)
    if ok then
      result.enabled[#result.enabled + 1] = s
      if opts.start ~= false then
        local started, why = svc.start(s)
        if started then result.started[#result.started + 1] = s
        else result.problems[#result.problems + 1] = s .. ": " .. tostring(why) end
      end
    else
      result.problems[#result.problems + 1] = s .. ": " .. tostring(e)
    end
  end
  if #result.problems == 0 then setApplied(name, true) end
  return result
end

--- Stop and disable the role's services (packages stay installed).
function M.remove(name)
  local role = (M.load())[name]
  if not role then return nil, "no such role: " .. tostring(name) end
  local svc = require("tsr.svc")
  svc.load()
  for _, s in ipairs(role.services) do
    if svc.get(s) then svc.stop(s) svc.disable(s) end
  end
  setApplied(name, nil)
  return true
end

local function defaultIO()
  local io = {}
  function io.say(t) print(t) end
  function io.err(t) if term.isColor() then term.setTextColor(colors.red) end print(t) term.setTextColor(colors.white) end
  return io
end

--- role list | show <name> | apply <name> | remove <name>
function M.run(args, io)
  io = io or defaultIO()
  local cmd = args[1] or "list"
  if cmd == "list" then
    local roles = M.load()
    for _, n in ipairs(M.names()) do
      io.say(("%s %-14s %s"):format(M.isApplied(n) and "*" or " ", n, roles[n].description))
    end
    io.say("(* = applied here)")
    return true
  elseif cmd == "show" then
    local plan, err = M.plan(args[2])
    if not plan then io.err(err) return false end
    io.say(plan.role.name .. ": " .. plan.role.description)
    io.say("packages: " .. (#plan.role.packages > 0 and table.concat(plan.role.packages, ", ") or "none")
      .. (#plan.missing > 0 and ("  (to install: " .. table.concat(plan.missing, ", ") .. ")") or ""))
    io.say("services: " .. (#plan.services > 0 and table.concat(plan.services, ", ") or "none"))
    if plan.role.notes then io.say(plan.role.notes) end
    return true
  elseif cmd == "apply" then
    if not args[2] then io.err("usage: role apply <name>") return false end
    local res, err = M.apply(args[2])
    if not res then io.err(tostring(err)) return false end
    if #res.installed > 0 then io.say("installed: " .. table.concat(res.installed, ", ")) end
    io.say("services on: " .. (#res.enabled > 0 and table.concat(res.enabled, ", ") or "none"))
    for _, p in ipairs(res.problems) do io.err("problem: " .. p) end
    if res.notes then io.say(res.notes) end
    return #res.problems == 0
  elseif cmd == "remove" then
    local ok, err = M.remove(args[2] or "")
    if not ok then io.err(tostring(err)) return false end
    io.say("Role removed; its services are stopped and disabled.")
    return true
  end
  io.err("usage: role list | show <name> | apply <name> | remove <name>")
  return false
end

function M.main(args) return M.run(args) end

return M
