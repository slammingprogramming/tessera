-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Recycle bin. Deleted things are moved to /var/trash/<id>/ together with a note of where they came from, and can be restored
-- until the bin is emptied or grows beyond its size limit (the oldest entries go first).
--   trash <path>...    move to the bin        trash list         what is in it
--   trash restore <n>  put entry n back       trash empty [days] delete everything (or entries older than that many days)
local vfs = require("tsr.vfs")

local M = {}

M.DIR = "/var/trash"
M.MAX_BYTES = 300000

local function entryDir(id) return M.DIR .. "/" .. id end

local function sizeOf(path)
  if not fs.exists(path) then return 0 end
  if not fs.isDir(path) then return fs.getSize(path) end
  local total = 0
  for _, name in ipairs(fs.list(path)) do total = total + sizeOf(path .. "/" .. name) end
  return total
end

local function protected(path)
  path = vfs.normalize(path)
  return path == "/" or path == "/rom" or path:sub(1, 5) == "/rom/" or path == M.DIR or path:sub(1, #M.DIR + 1) == M.DIR .. "/"
end

local function newId()
  local ids = fs.exists(M.DIR) and fs.list(M.DIR) or {}
  local n = 0
  for _, name in ipairs(ids) do n = math.max(n, tonumber(name:match("^(%d+)$")) or 0) end
  return string.format("%06d", n + 1)
end

--- All entries, oldest first: { id, path (original), time (ms), size, name }.
function M.list()
  local out = {}
  if not fs.isDir(M.DIR) then return out end
  local ids = fs.list(M.DIR)
  table.sort(ids)
  for _, id in ipairs(ids) do
    local meta = vfs.readJSON(entryDir(id) .. "/meta.json")
    if meta then out[#out + 1] = { id = id, path = meta.path, time = meta.time, size = meta.size, name = meta.name } end
  end
  return out
end

function M.totalSize()
  local n = 0
  for _, e in ipairs(M.list()) do n = n + e.size end
  return n
end

local function purgeOverflow()
  local entries = M.list()
  local total = 0
  for _, e in ipairs(entries) do total = total + e.size end
  local i = 1
  while total > M.MAX_BYTES and i <= #entries do
    fs.delete(entryDir(entries[i].id))
    total = total - entries[i].size
    i = i + 1
  end
end

--- Move `path` into the bin. Returns the entry id, or nil + reason.
function M.put(path)
  path = vfs.normalize(path)
  if protected(path) then return nil, "this cannot be moved to the bin" end
  if not fs.exists(path) then return nil, "no such file: " .. path end
  local size = sizeOf(path)
  if size > M.MAX_BYTES then return nil, "too big for the bin (" .. size .. " bytes); delete it for real" end
  local id = newId()
  local dir = entryDir(id)
  fs.makeDir(dir)
  local name = vfs.basename(path)
  local ok, err = pcall(fs.move, path, dir .. "/data")
  if not ok then fs.delete(dir) return nil, tostring(err) end
  vfs.writeJSON(dir .. "/meta.json", { path = path, name = name, time = os.epoch and os.epoch("utc") or 0, size = size })
  purgeOverflow()
  return id
end

--- Restore an entry (by id or 1-based position in list()). Returns the path it came back to, or nil + reason.
function M.restore(which)
  local entries = M.list()
  local entry
  if type(which) == "number" then entry = entries[which] else
    for _, e in ipairs(entries) do if e.id == which then entry = e end end
  end
  if not entry then return nil, "no such entry" end
  local target = entry.path
  if fs.exists(target) then
    -- never overwrite: pick a free name next to it
    local base, n = target, 1
    repeat target = base .. ".restored" .. (n > 1 and n or "") n = n + 1 until not fs.exists(target)
  end
  local parent = vfs.dirname(target)
  if not fs.exists(parent) then fs.makeDir(parent) end
  local ok, err = pcall(fs.move, entryDir(entry.id) .. "/data", target)
  if not ok then return nil, tostring(err) end
  fs.delete(entryDir(entry.id))
  return target
end

--- Delete entries for good: all, or those older than `days`. Returns how many were removed.
function M.empty(days)
  local n = 0
  local cutoff = days and ((os.epoch and os.epoch("utc") or 0) - days * 86400000)
  for _, e in ipairs(M.list()) do
    if not cutoff or e.time < cutoff then
      fs.delete(entryDir(e.id))
      n = n + 1
    end
  end
  return n
end

--- For file managers: move to the bin when the safety package is active, otherwise delete. Returns true or nil + reason.
function M.discard(path)
  local config = require("tsr.config")
  local norm = vfs.normalize(path)
  if config.get("trash.enabled", true) and norm ~= "/tmp" and norm:sub(1, 5) ~= "/tmp/" then
    local id, err = M.put(path)
    if id then return true end
    if err and err:find("too big", 1, true) then
      -- fall through to a real delete for things that cannot be kept
    elseif err and err:find("cannot be moved", 1, true) then return nil, err
    else return nil, err end
  end
  local ok, err = pcall(fs.delete, path)
  if not ok then return nil, tostring(err) end
  return true
end

local function defaultIO()
  local io = {}
  function io.say(t) print(t) end
  function io.err(t) if term.isColor() then term.setTextColor(colors.red) end print(t) term.setTextColor(colors.white) end
  return io
end

function M.run(args, io)
  io = io or defaultIO()
  local cmd = args[1]
  if cmd == "list" or cmd == nil then
    local entries = M.list()
    if #entries == 0 then io.say("The bin is empty.") end
    for i, e in ipairs(entries) do io.say(("%2d  %-24s %6d B  %s"):format(i, e.name, e.size, e.path)) end
    if #entries > 0 then io.say(("%d bytes of %d used"):format(M.totalSize(), M.MAX_BYTES)) end
    return true
  elseif cmd == "restore" then
    local n = tonumber(args[2])
    if not n then io.err("usage: trash restore <number from `trash list`>") return false end
    local path, err = M.restore(n)
    if not path then io.err(tostring(err)) return false end
    io.say("Restored to " .. path)
    return true
  elseif cmd == "empty" then
    local n = M.empty(tonumber(args[2]))
    io.say(n .. " entries deleted.")
    return true
  end
  -- anything else is a list of paths to discard
  local ok = true
  for _, p in ipairs(args) do
    local full = (rawget(_G, "shell") and shell.resolve(p)) or p
    local id, err = M.put(full)
    if id then io.say("Moved " .. p .. " to the bin (entry " .. tonumber(id) .. ").") else io.err(p .. ": " .. tostring(err)) ok = false end
  end
  return ok
end

function M.main(args) return M.run(args) end

return M
