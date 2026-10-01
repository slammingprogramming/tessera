-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Central logging.
--   Collector (one computer):  logd service -> /var/log/remote/<computer name>.log (rotated at 32 KB)
--   Shippers (the others):     logship service sends warnings and errors to the collector named in config `log.remote`
--   logship tail <name> [n]    show the last lines collected from a computer
local vfs = require("tsr.vfs")

local M = {}

M.DIR = "/var/log/remote"
M.MAX_FILE = 32 * 1024
M.MAX_QUEUE = 200
M.BATCH = 20

---------------------------------------------------------------------------------------------------------------------
-- Collector
---------------------------------------------------------------------------------------------------------------------

local function safeName(name) return (tostring(name):gsub("[^%w_%-%.]", "_")) end

local function append(peerName, lines)
  local path = M.DIR .. "/" .. safeName(peerName) .. ".log"
  local ok, size = pcall(fs.getSize, path)
  if ok and size > M.MAX_FILE then
    pcall(fs.delete, path .. ".1")
    pcall(fs.move, path, path .. ".1")
  end
  if not fs.exists(M.DIR) then fs.makeDir(M.DIR) end
  local h = fs.open(path, "a")
  if not h then return false end
  for _, l in ipairs(lines) do h.writeLine((tostring(l):gsub("[\r\n]", " "))) end
  h.close()
  return true
end

--- Register the "log" service on `node`.
function M.serve(node)
  node:serve("log", function(from, method, a)
    if method ~= "write" or type(a) ~= "table" or type(a.lines) ~= "table" then error("bad request", 0) end
    local peer = node:peer(from)
    local lines = {}
    for i = 1, math.min(#a.lines, 100) do
      if type(a.lines[i]) == "string" then lines[#lines + 1] = a.lines[i]:sub(1, 300) end
    end
    append(peer and peer.name or from, lines)
    return #lines
  end)
end

function M.tail(name, n)
  local text = vfs.readFile(M.DIR .. "/" .. safeName(name) .. ".log")
  if not text then return nil end
  local lines = {}
  for l in text:gmatch("[^\n]+") do lines[#lines + 1] = l end
  local out = {}
  for i = math.max(1, #lines - (n or 20) + 1), #lines do out[#out + 1] = lines[i] end
  return out
end

---------------------------------------------------------------------------------------------------------------------
-- Shipper
---------------------------------------------------------------------------------------------------------------------

local queue = {}
local hooked = false

local LEVEL_RANK = { debug = 1, info = 2, warn = 3, error = 4 }

--- Start collecting log lines at or above `level` (default warn) for shipping.
function M.hook(level)
  if hooked then return end
  hooked = true
  local min = LEVEL_RANK[level or "warn"] or 3
  require("tsr.log").addSink(function(line, levelName)
    if (LEVEL_RANK[levelName] or 0) < min then return end
    queue[#queue + 1] = line
    while #queue > M.MAX_QUEUE do table.remove(queue, 1) end
  end)
end

function M.pending() return #queue end

--- Send queued lines to `peer` through `node`. Returns the number sent, or nil + error (the lines stay queued).
function M.flush(node, peer)
  if #queue == 0 then return 0 end
  local batch = {}
  for i = 1, math.min(#queue, M.BATCH) do batch[i] = queue[i] end
  local sent, err = node:call(peer, "log", "write", { lines = batch }, { timeout = 5 })
  if sent == nil then return nil, err end
  for _ = 1, #batch do table.remove(queue, 1) end
  return #batch
end

function M.reset() queue, hooked = {}, false end

--- The logship service: keep sending to the collector named in config `log.remote`.
function M.shipDaemon()
  local config = require("tsr.config")
  local node = require("tsr.net").default()
  M.hook(config.get("log.remote_level", "warn"))
  while true do
    local peer = config.get("log.remote")
    if peer and #queue > 0 then
      local n = M.flush(node, peer)
      if n and #queue > 0 then n = 0 end       -- more waiting: loop again at once
      if n == nil then sleep(10) end
    end
    sleep(2)
  end
end

--- The logd service.
function M.collectDaemon()
  M.serve(require("tsr.net").default())
  while true do os.pullEvent("logd_never") end
end

local function defaultIO()
  local io = {}
  function io.say(t) print(t) end
  function io.err(t) if term.isColor() then term.setTextColor(colors.red) end print(t) term.setTextColor(colors.white) end
  return io
end

--- logship tail <computer> [n] | to <collector> | status
function M.run(args, io)
  io = io or defaultIO()
  local cmd = args[1]
  if cmd == "tail" and args[2] then
    local lines = M.tail(args[2], tonumber(args[3]))
    if not lines then io.err("nothing collected from " .. args[2]) return false end
    for _, l in ipairs(lines) do io.say(l) end
    return true
  elseif cmd == "to" and args[2] then
    require("tsr.config").set("log.remote", args[2], "system")
    io.say("Warnings and errors will be sent to " .. args[2] .. " (service logship; `svc enable logship`).")
    return true
  elseif cmd == "status" or cmd == nil then
    io.say("collector: " .. tostring(require("tsr.config").get("log.remote") or "none") .. ", queued lines: " .. #queue)
    if fs.isDir(M.DIR) then
      for _, f in ipairs(fs.list(M.DIR)) do io.say("  " .. f .. "  " .. fs.getSize(M.DIR .. "/" .. f) .. " B") end
    end
    return true
  end
  io.err("usage: logship tail <computer> [n] | to <collector> | status")
  return false
end

function M.main(args) return M.run(args) end

return M
