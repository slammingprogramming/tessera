-- SPDX-License-Identifier: AGPL-3.0-or-later
-- svc: control background services.
--   svc [list]              show all services
--   svc status <name>       details for one service
--   svc start|stop|restart <name>
--   svc enable|disable <name>   start at boot (or not)
--   svc reload              re-read /etc/tsr/services.d
--   svc log <name> [n]      recent log lines that mention the service
local req = (rawget(_G, "tsr") and tsr.require) or dofile("/sys/lib/tsr/loader.lua").require
local svc = req("tsr.svc")
local args = { ... }
local cmd = args[1] or "list"

local function color(c) if term.isColor() then term.setTextColor(c) end end

local function fail(msg) color(colors.red) print("svc: " .. msg) color(colors.white) return false end

if #svc.names() == 0 then svc.load() end

local function needName()
  if not args[2] then return nil, fail("usage: svc " .. cmd .. " <name>") end
  return args[2]
end

local STATE_COLOR = { running = colors.lime, failed = colors.red, backoff = colors.orange, stopped = colors.lightGray }

if cmd == "list" then
  local list = svc.list()
  if #list == 0 then print("No services defined.") return true end
  for _, s in ipairs(list) do
    color(STATE_COLOR[s.state] or colors.white)
    write(("%-9s"):format(s.state))
    color(colors.white)
    print(("%-16s %s%s"):format(s.name, s.enabled and "* " or "  ", s.description))
  end
  print("(* = starts at boot)")
  return true
elseif cmd == "status" then
  local name = needName()
  if not name then return false end
  local s = svc.status(name)
  if not s then return fail("no such service: " .. name) end
  print(s.name .. " - " .. s.description)
  print("state:    " .. s.state .. (s.pid and (" (pid " .. s.pid .. ")") or ""))
  print("at boot:  " .. (s.enabled and "yes" or "no"))
  print("restart:  " .. s.restart .. ", restarted " .. s.restarts .. " times")
  if #s.requires > 0 then print("needs:    " .. table.concat(s.requires, ", ")) end
  if s.lastError then print("last error: " .. s.lastError) end
  return true
elseif cmd == "start" or cmd == "stop" or cmd == "restart" or cmd == "enable" or cmd == "disable" then
  local name = needName()
  if not name then return false end
  local ok, err = svc[cmd](name)
  if not ok then return fail(tostring(err)) end
  print(cmd .. ": " .. name .. " ok")
  return true
elseif cmd == "reload" then
  local n, problems = svc.load()
  print(n .. " service definitions loaded")
  for _, p in ipairs(problems) do print("  problem: " .. p) end
  return #problems == 0
elseif cmd == "log" then
  local name = needName()
  if not name then return false end
  local lines = req("tsr.log").tail()
  local shown, want = {}, tonumber(args[3]) or 15
  for _, l in ipairs(lines) do
    if l:find(name, 1, true) then shown[#shown + 1] = l end
  end
  for i = math.max(1, #shown - want + 1), #shown do print(shown[i]) end
  return true
end
return fail("unknown command '" .. cmd .. "' (try: list, status, start, stop, restart, enable, disable, reload, log)")
