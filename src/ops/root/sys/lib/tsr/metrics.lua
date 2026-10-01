-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Metrics: a snapshot of how this computer is doing, readable locally (`metrics`) and by paired computers (`metrics <peer>`).
-- Everything is a number or short string so it can be graphed or shown on a monitor by other tools.
local M = {}

local counters = { log_warn = 0, log_error = 0 }
local hooked = false

--- Count warnings/errors written to the system log from now on (the `metricsd` service calls this).
function M.hookLog()
  if hooked then return end
  hooked = true
  require("tsr.log").addSink(function(_, levelName)
    if levelName == "warn" then counters.log_warn = counters.log_warn + 1
    elseif levelName == "error" then counters.log_error = counters.log_error + 1 end
  end)
end

local function try(fn, default)
  local ok, res = pcall(fn)
  if ok and res ~= nil then return res end
  return default
end

--- Collect the gauges. `extra` is an optional table merged in (for tests and plugins).
function M.collect(extra)
  local g = {
    host = try(function() return require("tsr.net").default().hostname end, os.getComputerLabel() or ("cc-" .. os.getComputerID())),
    id = os.getComputerID(),
    uptime = math.floor(os.clock()),
    day = try(function() return os.day("ingame") end, 0),
    time = try(function() return textutils.formatTime(os.time("ingame"), true) end, ""),
    profile = try(function() return require("tsr.profile").get() end, "unknown"),
    version = try(function() return require("tsr.version").version end, ""),
    memory_kb = math.floor(collectgarbage("count")),
    disk_free = try(function() return require("tsr.util").freeSpace("/") end, 0),
    processes = try(function() return #require("tsr.kernel").list() end, 0),
    peripherals = #peripheral.getNames(),
    log_warn = counters.log_warn,
    log_error = counters.log_error,
  }
  if type(g.disk_free) ~= "number" then g.disk_free = -1 end   -- "unlimited"
  if rawget(_G, "turtle") then
    g.fuel = try(function() return turtle.getFuelLevel() end, 0)
    g.fuel_limit = try(function() return turtle.getFuelLimit() end, 0)
  end
  local services = try(function() return require("tsr.svc").list() end, nil)
  if services then
    local running, failed = 0, 0
    for _, s in ipairs(services) do
      if s.state == "running" then running = running + 1 elseif s.state == "failed" then failed = failed + 1 end
    end
    g.services_running, g.services_failed = running, failed
  end
  if extra then for k, v in pairs(extra) do g[k] = v end end
  return g
end

--- Register the "metrics" service on `node` (method "get" returns the snapshot).
function M.serve(node)
  node:serve("metrics", function(_, method)
    if method ~= "get" then error("unknown method", 0) end
    return M.collect()
  end)
end

local function defaultIO()
  local io = {}
  function io.say(t) print(t) end
  function io.err(t) if term.isColor() then term.setTextColor(colors.red) end print(t) term.setTextColor(colors.white) end
  return io
end

local ORDER = { "host", "id", "profile", "version", "uptime", "day", "time", "processes", "services_running", "services_failed",
                "memory_kb", "disk_free", "peripherals", "fuel", "fuel_limit", "log_warn", "log_error" }

--- metrics [peer]
function M.run(args, io, node)
  io = io or defaultIO()
  local g
  if args[1] then
    node = node or require("tsr.net").default()
    local res, err = node:call(tonumber(args[1]) or args[1], "metrics", "get", nil, { timeout = 5 })
    if not res then io.err(tostring(err)) return false end
    g = res
  else
    g = M.collect()
  end
  for _, k in ipairs(ORDER) do
    if g[k] ~= nil then io.say(("%-17s %s"):format(k, tostring(g[k]))) end
  end
  return true
end

function M.main(args) return M.run(args) end

--- The metricsd service.
function M.daemon()
  M.hookLog()
  M.serve(require("tsr.net").default())
  while true do os.pullEvent("metrics_never") end
end

return M
