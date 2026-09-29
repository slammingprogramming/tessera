-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Logging: leveled loggers, in-memory ring buffer, size-rotated file sink.
--   local log = require("tsr.log").get("kernel")
--   log.info("started pid %d", pid)     -- string.format applied when extra arguments are given
local util = require("tsr.util")

local M = {}

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4, off = 5 }
local RING_MAX = 200

local state = {
  level = LEVELS.info,
  file = nil,        -- path of the log file, nil = memory only
  maxSize = 32 * 1024,
  ring = {},
  sinks = {},        -- extra sinks: function(line, levelName, name)
}

function M.setLevel(name)
  assert(LEVELS[name], "unknown log level: " .. tostring(name))
  state.level = LEVELS[name]
end

function M.getLevel()
  for k, v in pairs(LEVELS) do if v == state.level then return k end end
end

function M.setFile(path, maxSize)
  state.file = path
  if maxSize then state.maxSize = maxSize end
  if path then
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then pcall(fs.makeDir, dir) end
  end
end

function M.addSink(fn) state.sinks[#state.sinks + 1] = fn end

local function rotate()
  local path = state.file
  local ok, size = pcall(fs.getSize, path)
  if ok and size > state.maxSize then
    pcall(fs.delete, path .. ".1")
    pcall(fs.move, path, path .. ".1")
  end
end

local function emit(levelName, name, msg)
  local line = string.format("%s [%s] %s: %s", util.timestamp(), levelName:upper():sub(1, 4), name, msg)
  local ring = state.ring
  ring[#ring + 1] = line
  if #ring > RING_MAX then table.remove(ring, 1) end
  if state.file then
    pcall(function()
      rotate()
      local h = fs.open(state.file, "a")
      if h then
        h.writeLine(line)
        h.close()
      end
    end)
  end
  for _, sink in ipairs(state.sinks) do pcall(sink, line, levelName, name) end
end

--- Returns a logger table with debug/info/warn/error functions.
function M.get(name)
  local l = { name = name }
  for levelName, level in pairs(LEVELS) do
    if levelName ~= "off" then
      l[levelName] = function(fmt, ...)
        if level < state.level then return end
        local msg = fmt
        if select("#", ...) > 0 then
          local ok, s = pcall(string.format, fmt, ...)
          msg = ok and s or (tostring(fmt) .. " " .. tostring(s))
        end
        emit(levelName, name, tostring(msg))
      end
    end
  end
  return l
end

--- The last `n` log lines held in memory (default all).
function M.tail(n)
  local ring = state.ring
  n = n or #ring
  local out = {}
  for i = math.max(1, #ring - n + 1), #ring do out[#out + 1] = ring[i] end
  return out
end

function M.clear() state.ring = {} end

return M
