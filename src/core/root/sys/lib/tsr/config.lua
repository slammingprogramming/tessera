-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Layered configuration store with dotted keys.
--   config.get("net.hostname", "unnamed")     config.set("log.level", "debug")     config.watch("net.", fn)
-- Layers, lowest to highest priority: defaults (code) < profile < system < user (runtime). Only the `system` and
-- `profile` layers are persisted (under /etc/tsr/), via crash-safe writes.
local util = require("tsr.util")
local vfs = require("tsr.vfs")

local M = {}

local ORDER = { "defaults", "profile", "system", "user" }
local layers = { defaults = {}, profile = {}, system = {}, user = {} }
local paths = { profile = "/etc/tsr/profile.cfg", system = "/etc/tsr/system.cfg" }
local watchers = {}

M.paths = paths

local function getIn(t, key)
  local node = t
  for part in key:gmatch("[^%.]+") do
    if type(node) ~= "table" then return nil end
    node = node[part]
    if node == nil then return nil end
  end
  return node
end

local function setIn(t, key, value)
  local parts = util.split(key, ".")
  local node = t
  for i = 1, #parts - 1 do
    if type(node[parts[i]]) ~= "table" then node[parts[i]] = {} end
    node = node[parts[i]]
  end
  node[parts[#parts]] = value
end

--- Effective value: highest layer that defines the key. Tables from several layers are merged.
function M.get(key, default)
  local result
  for _, name in ipairs(ORDER) do
    local v = getIn(layers[name], key)
    if v ~= nil then
      if type(v) == "table" and type(result) == "table" then
        result = util.merge(util.deepcopy(result), v)
      else
        result = util.deepcopy(v)
      end
    end
  end
  if result == nil then return default end
  return result
end

local function notify(key, value)
  for _, w in ipairs(watchers) do
    if key:sub(1, #w.prefix) == w.prefix then pcall(w.fn, key, value) end
  end
end

--- Set `key` in `layer` (default "system"). Use value=nil to unset. Persist with M.save().
function M.set(key, value, layer)
  layer = layer or "system"
  assert(layers[layer], "unknown config layer: " .. tostring(layer))
  setIn(layers[layer], key, util.deepcopy(value))
  notify(key, M.get(key))
end

function M.setDefaults(tbl)
  util.merge(layers.defaults, tbl)
end

--- Load a persisted layer from disk (silently keeps the current contents if the file is missing/corrupt).
function M.load(layer)
  local p = paths[layer]
  if not p then return false end
  local t = vfs.readTable(p)
  if type(t) == "table" then
    layers[layer] = t
    return true
  end
  return false
end

function M.loadAll()
  M.load("profile")
  M.load("system")
end

function M.save(layer)
  layer = layer or "system"
  local p = paths[layer]
  if not p then return false, "layer is not persisted" end
  return vfs.writeTable(p, layers[layer])
end

--- Call fn(key, newValue) whenever a key starting with `prefix` is set. Returns an unwatch function.
function M.watch(prefix, fn)
  local w = { prefix = prefix, fn = fn }
  watchers[#watchers + 1] = w
  return function()
    for i, x in ipairs(watchers) do
      if x == w then table.remove(watchers, i) return end
    end
  end
end

--- For tests / recovery: forget everything in memory.
function M.reset()
  for _, n in ipairs(ORDER) do layers[n] = {} end
  watchers = {}
end

--- Whole effective config as one table (defaults merged with all layers).
function M.dump()
  local out = {}
  for _, name in ipairs(ORDER) do util.merge(out, layers[name]) end
  return out
end

return M
