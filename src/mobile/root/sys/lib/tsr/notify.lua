-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Notifications: a small persistent inbox that services push to and the phone interface shows.
--   notify.push("Reactor", "Temperature high", { level = "warn" })     (also queues the event "tsr_notify")
--   notify.list() -> newest first        notify.unread()        notify.markRead()        notify.clear()
local vfs = require("tsr.vfs")

local M = {}

M.PATH = "/var/lib/tsr/notifications.json"
M.MAX = 50

local function load()
  local data = vfs.readJSON(M.PATH)
  if type(data) ~= "table" or type(data.items) ~= "table" then data = { items = {}, nextId = 1 } end
  data.nextId = data.nextId or 1
  return data
end

local function save(data) return vfs.writeJSON(M.PATH, data) end

local function timestamp()
  local ok, s = pcall(function() return textutils.formatTime(os.time("local"), true) end)
  return ok and s or ""
end

--- Add a notification. opts: level ("info" default, "warn", "error"), source.
function M.push(title, text, opts)
  opts = opts or {}
  local data = load()
  local item = { id = data.nextId, title = tostring(title), text = tostring(text or ""), level = opts.level or "info",
                 source = opts.source, time = timestamp(), day = os.day and os.day("ingame") or 0, read = false }
  data.nextId = data.nextId + 1
  data.items[#data.items + 1] = item
  while #data.items > M.MAX do table.remove(data.items, 1) end
  save(data)
  os.queueEvent("tsr_notify", item.id)
  return item.id
end

--- All notifications, newest first.
function M.list()
  local items = load().items
  local out = {}
  for i = #items, 1, -1 do out[#out + 1] = items[i] end
  return out
end

function M.unread()
  local n = 0
  for _, it in ipairs(load().items) do if not it.read then n = n + 1 end end
  return n
end

function M.markRead()
  local data = load()
  for _, it in ipairs(data.items) do it.read = true end
  save(data)
end

function M.clear()
  local data = load()
  data.items = {}
  save(data)
end

return M
