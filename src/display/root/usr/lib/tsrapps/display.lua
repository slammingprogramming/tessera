-- SPDX-License-Identifier: AGPL-3.0-or-later
-- display: apps for attached monitors.
--   monclock [side] [--scale N] [--24h] [--real] [--seconds]     a clock that fills the monitor
--   monstat  [side] [--scale N] [--interval S]                    a status board for this computer
--   monwrite <text...> [--side S] [--scale N] [--color name]      show a message (empty text clears the monitor)
-- With no side the first monitor found is used. Colours only show on advanced monitors.
local cli = require("tsrapps.cli")
local util = require("tsr.util")

local M = {}

M.CLOCK_SPEC = { scale = "number", ["24h"] = "bool", real = "bool", seconds = "bool" }
M.STAT_SPEC = { scale = "number", interval = "number" }
M.WRITE_SPEC = { side = "string", scale = "number", color = "string" }

local function per(env) return (env and env.peripheral) or peripheral end

--- The monitor named `side`, or the first one attached. Returns monitor, name  or nil + reason.
function M.find(side, env)
  local p = per(env)
  if side then
    if p.getType(side) ~= "monitor" then return nil, "no monitor on " .. side end
    return p.wrap(side), side
  end
  local found = p.find("monitor")
  if not found then return nil, "no monitor attached" end
  return found, p.getName and p.getName(found) or "monitor"
end

local function setScale(mon, scale)
  if mon.setTextScale and scale then mon.setTextScale(math.max(0.5, math.min(5, scale))) end
end

--- Draw `lines` centred (both ways) on the monitor. opts.colors = array of colours per line.
function M.drawCentered(mon, lines, opts)
  opts = opts or {}
  local w, h = mon.getSize()
  if mon.setBackgroundColor then mon.setBackgroundColor(colors.black) end
  mon.clear()
  local top = math.max(1, math.floor((h - #lines) / 2) + 1)
  for i, line in ipairs(lines) do
    if #line > w then line = line:sub(1, w) end
    mon.setCursorPos(math.max(1, math.floor((w - #line) / 2) + 1), top + i - 1)
    if mon.setTextColor then mon.setTextColor((opts.colors and opts.colors[i]) or colors.white) end
    mon.write(line)
  end
end

--- "HH:MM[:SS]" from an in-game hour (0-24 float) or a unix time.
function M.formatClock(hours, opts)
  opts = opts or {}
  local total = math.floor(hours * 3600 + 0.5)
  local h = math.floor(total / 3600) % 24
  local m = math.floor(total / 60) % 60
  local s = total % 60
  local suffix = ""
  if not opts.h24 then
    suffix = h >= 12 and " PM" or " AM"
    h = h % 12
    if h == 0 then h = 12 end
  end
  if opts.seconds then return ("%02d:%02d:%02d%s"):format(h, m, s, suffix) end
  return ("%02d:%02d%s"):format(h, m, suffix)
end

local function nowHours(opts, env)
  if opts.real then
    local t = (env and env.utcSeconds) and env.utcSeconds() or (os.epoch("utc") / 1000)
    return (t % 86400) / 3600
  end
  return (env and env.ingameHours) and env.ingameHours() or os.time("ingame")
end

--- One frame of the clock.
function M.clockFrame(mon, opts, env)
  local text = M.formatClock(nowHours(opts, env), { h24 = opts["24h"], seconds = opts.seconds })
  M.drawCentered(mon, { text }, { colors = { colors.lime } })
  return text
end

function M.monclock(args, io, env)
  io = io or cli.io()
  local pos, opts = cli.parse(args, M.CLOCK_SPEC)
  if not pos then io.err(opts) return false end
  local mon, name = M.find(pos[1], env)
  if not mon then io.err(name) return false end
  setScale(mon, opts.scale or 2)
  local frames = 0
  while true do
    M.clockFrame(mon, opts, env)
    frames = frames + 1
    if env and env.maxFrames and frames >= env.maxFrames then return true end
    sleep(opts.seconds and 0.5 or 5)
  end
end

--- Lines for the status board.
function M.statusLines(env)
  local p = per(env)
  local lines = { (os.getComputerLabel() or ("Computer " .. os.getComputerID())) }
  local minutes = math.floor(((env and env.uptimeSeconds) and env.uptimeSeconds() or os.clock()) / 60)
  lines[#lines + 1] = ("up %dh %02dm"):format(math.floor(minutes / 60), minutes % 60)
  local hours = (env and env.ingameHours) and env.ingameHours() or os.time("ingame")
  lines[#lines + 1] = "time " .. M.formatClock(hours, { h24 = true })
  local free = util.freeSpace()
  lines[#lines + 1] = "disk " .. (free == math.huge and "unlimited" or util.fmtBytes(free) .. " free")
  local counts = {}
  for _, name in ipairs(p.getNames()) do
    local t = p.getType(name)
    counts[t] = (counts[t] or 0) + 1
  end
  local names = {}
  for t in pairs(counts) do names[#names + 1] = t end
  table.sort(names)
  for _, t in ipairs(names) do lines[#lines + 1] = ("%s x%d"):format(t, counts[t]) end
  return lines
end

function M.monstat(args, io, env)
  io = io or cli.io()
  local pos, opts = cli.parse(args, M.STAT_SPEC)
  if not pos then io.err(opts) return false end
  local mon, name = M.find(pos[1], env)
  if not mon then io.err(name) return false end
  setScale(mon, opts.scale or 1)
  local frames = 0
  while true do
    local lines = M.statusLines(env)
    local cols = { colors.yellow }
    for i = 2, #lines do cols[i] = colors.white end
    M.drawCentered(mon, lines, { colors = cols })
    frames = frames + 1
    if env and env.maxFrames and frames >= env.maxFrames then return true end
    sleep(opts.interval or 5)
  end
end

function M.monwrite(args, io, env)
  io = io or cli.io()
  local pos, opts = cli.parse(args, M.WRITE_SPEC)
  if not pos then io.err(opts) return false end
  local mon, name = M.find(opts.side, env)
  if not mon then io.err(name) return false end
  local color = colors.white
  if opts.color then
    color = colors[opts.color]
    if type(color) ~= "number" then io.err("unknown colour " .. opts.color) return false end
  end
  setScale(mon, opts.scale or 1)
  local text = table.concat(pos, " ")
  if text == "" then
    mon.clear()
    return true
  end
  -- wrap to the monitor width
  local w = mon.getSize()
  local lines = {}
  local line = ""
  for word in text:gmatch("%S+") do
    if line == "" then line = word
    elseif #line + 1 + #word <= w then line = line .. " " .. word
    else lines[#lines + 1] = line line = word end
  end
  lines[#lines + 1] = line
  local cols = {}
  for i = 1, #lines do cols[i] = color end
  M.drawCentered(mon, lines, { colors = cols })
  return true
end

return M
