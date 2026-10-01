-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Live dashboards for energy stores and fluid tanks, built on the HAL (so any mod's devices that have a driver show up).
--   power [watch] [--monitor <name>]     every energy store: fill bar, stored/capacity, trend and time to full/empty
--   tanks [watch] [--monitor <name>]     every fluid tank: fill (when the capacity is known), amount and trend
-- `watch` refreshes every two seconds until a key is pressed.
local hal = require("tsr.hal")

local M = {}

M.REFRESH = 2
M.HISTORY = 6        -- samples used for the trend

local history = {}   -- device name -> { {t, value}, ... }

function M.resetHistory() history = {} end

--- Units per second over the recent samples, or nil with too little data.
local function trend(name, t, value)
  local h = history[name] or {}
  history[name] = h
  h[#h + 1] = { t, value }
  while #h > M.HISTORY do table.remove(h, 1) end
  if #h < 2 then return nil end
  local dt = h[#h][1] - h[1][1]
  if dt <= 0 then return nil end
  return (h[#h][2] - h[1][2]) / dt
end

local function fmt(n)
  if type(n) ~= "number" then return tostring(n) end
  local a = math.abs(n)
  if a >= 1e9 then return ("%.2fG"):format(n / 1e9) end
  if a >= 1e6 then return ("%.2fM"):format(n / 1e6) end
  if a >= 1e4 then return ("%.1fk"):format(n / 1e3) end
  if n == math.floor(n) then return ("%d"):format(n) end
  return ("%.1f"):format(n)
end
M.fmt = fmt

local function duration(seconds)
  if seconds > 86400 * 2 then return ">2d" end
  if seconds >= 3600 then return ("%dh%02dm"):format(seconds / 3600, (seconds % 3600) / 60) end
  if seconds >= 60 then return ("%dm%02ds"):format(seconds / 60, seconds % 60) end
  return ("%ds"):format(seconds)
end
M.duration = duration

--- One row per device. kind: "power" or "tanks". now: seconds.
function M.sample(kind, env, now)
  now = now or ((os.epoch and os.epoch("utc") or os.clock() * 1000) / 1000)
  local rows = {}
  local cap = kind == "power" and "energy" or "fluid"
  for _, dev in ipairs(hal.find(cap, env)) do
    local row = { name = dev.name }
    if kind == "power" then
      local stored, unit = dev:get("energy.stored")
      local capacity = dev:get("energy.capacity")
      if stored ~= nil then
        row.value, row.capacity, row.unit = stored, capacity, unit or "FE"
        row.percent = (capacity and capacity > 0) and stored / capacity * 100 or nil
      else
        row.error = true
      end
    else
      local amount = dev:get("fluid.amount")
      if amount ~= nil then
        row.value, row.unit, row.fluid = amount, "mB", dev:get("fluid.name")
        local capacity = dev:get("fluid.capacity")
        if capacity and capacity > 0 then row.capacity, row.percent = capacity, amount / capacity * 100 end
      else
        row.error = true
      end
    end
    if row.value ~= nil then
      row.rate = trend(dev.name, now, row.value)
      if row.rate and row.capacity then
        if row.rate > 0.0001 then row.eta = (row.capacity - row.value) / row.rate
        elseif row.rate < -0.0001 then row.eta = -row.value / row.rate end
      end
    end
    rows[#rows + 1] = row
  end
  return rows
end

local function bar(width, percent)
  local filled = math.max(0, math.min(width, math.floor(width * (percent or 0) / 100 + 0.5)))
  return string.rep("\127", 0) .. string.rep("#", filled) .. string.rep("-", width - filled)
end
M.bar = bar

--- The text lines for a row, sized to `width`.
function M.line(row, width)
  if row.error then return ("%s  (unreadable)"):format(row.name) end
  local barWidth = math.max(6, math.min(20, width - 36))
  local left = ("%-12s"):format(row.name:sub(1, 12))
  local mid = row.percent and (bar(barWidth, row.percent) .. ("%4.0f%%"):format(row.percent)) or string.rep(" ", barWidth + 5)
  local amount = row.capacity and (fmt(row.value) .. "/" .. fmt(row.capacity)) or fmt(row.value)
  local text = ("%s %s %s %s"):format(left, mid, amount, row.unit or "")
  if row.rate then
    local per = row.unit .. "/s"
    text = text .. ("  %s%s%s"):format(row.rate >= 0 and "+" or "", fmt(row.rate), per)
    if row.eta then text = text .. ((row.rate > 0) and " full " or " empty ") .. duration(row.eta) end
  end
  if row.fluid and row.fluid ~= "empty" then text = text .. "  " .. row.fluid:gsub("^.-:", "") end
  return text:sub(1, width)
end

--- Entry points for the power and tanks commands.
function M.power(args) return M.run("power", args) end
function M.tanks(args) return M.run("tanks", args) end

local function colorFor(row)
  if row.error then return colors.gray end
  if not row.percent then return colors.white end
  if row.percent < 15 then return colors.red elseif row.percent < 40 then return colors.orange end
  return colors.lime
end

--- Draw rows on a terminal-like object `t`.
function M.render(t, kind, rows)
  local w, h = t.getSize()
  t.setBackgroundColor(colors.black)
  t.clear()
  t.setCursorPos(1, 1)
  t.setTextColor(colors.yellow)
  t.write((kind == "power" and "POWER" or "TANKS") .. string.rep(" ", math.max(0, w - 5 - #os.date("%H:%M"))) .. os.date("%H:%M"))
  local y = 2
  if #rows == 0 then
    t.setCursorPos(1, y)
    t.setTextColor(colors.lightGray)
    t.write(kind == "power" and "No energy storage found." or "No fluid tanks found.")
    return
  end
  for _, row in ipairs(rows) do
    if y > h then break end
    t.setCursorPos(1, y)
    t.setTextColor(colorFor(row))
    t.write(M.line(row, w))
    y = y + 1
  end
  t.setTextColor(colors.white)
end

local function defaultIO()
  local io = {}
  function io.say(t) print(t) end
  function io.err(t) if term.isColor() then term.setTextColor(colors.red) end print(t) term.setTextColor(colors.white) end
  return io
end

--- power | tanks   [watch] [--monitor name]
function M.run(kind, args, io, env)
  io = io or defaultIO()
  env = env or {}
  local watch, monitorName = false, nil
  local i = 1
  while i <= #args do
    if args[i] == "watch" then watch = true
    elseif args[i] == "--monitor" then monitorName = args[i + 1] i = i + 1
    else io.err("usage: " .. kind .. " [watch] [--monitor <name>]") return false end
    i = i + 1
  end
  local target = (env.term) or term.current()
  if monitorName then
    local per = env.peripheral or peripheral
    local mon = per.wrap(monitorName)
    if not mon then io.err("no monitor named " .. monitorName) return false end
    target = mon
  end
  local sample = function() return M.sample(kind, env) end
  if not watch then
    local rows = sample()
    if monitorName then M.render(target, kind, rows) return true end
    if #rows == 0 then io.say(kind == "power" and "No energy storage found." or "No fluid tanks found.") end
    local w = select(1, target.getSize())
    for _, row in ipairs(rows) do io.say(M.line(row, w)) end
    return true
  end
  local rounds = 0
  while true do
    M.render(target, kind, sample())
    rounds = rounds + 1
    if env.maxRounds and rounds >= env.maxRounds then return true end
    local timer = os.startTimer(M.REFRESH)
    while true do
      local ev, a = os.pullEvent()
      if ev == "timer" and a == timer then break end
      if ev == "key" or ev == "mouse_click" then
        target.setCursorPos(1, 1)
        return true
      end
    end
  end
end

return M
