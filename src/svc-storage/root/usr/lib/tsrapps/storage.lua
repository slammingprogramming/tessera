-- SPDX-License-Identifier: AGPL-3.0-or-later
-- storage: manage a network of chests (or any inventory: barrels, drawers, modded storage) connected by wired modems.
--   storage scan                      what is stored where (totals per item)
--   storage find <pattern>            where an item is
--   storage get <pattern> <count> <inventory>    move items into an inventory (e.g. a chest next to you)
--   storage sort [--once] [--interval S]         empty the input inventory into the right chests by the rules
--   storage input <inventory> | overflow <inventory>            set the input chest / where unmatched items go
--   storage rule add <pattern> <inventory> | list | remove <n>   sorting rules, first match wins
-- Patterns: exact item name ("minecraft:coal"), "minecraft:*_ore", "*log", or a Lua pattern with the prefix re:
-- Uses only the generic `inventory` peripheral methods (list, size, pushItems), so it works with any mod's storage.
local cli = require("tsrapps.cli")
local vfs = require("tsr.vfs")

local M = {}

M.CONFIG = "/etc/tsr/storage.cfg"
M.SPEC = { once = "bool", interval = "number" }

local function per(env) return (env and env.peripheral) or peripheral end

function M.load() return vfs.readTable(M.CONFIG) or { rules = {} } end
function M.save(cfg) return vfs.writeTable(M.CONFIG, cfg) end

--- Does `name` match `pattern`? ("re:" prefix = Lua pattern, "*" wildcards otherwise)
function M.matches(pattern, name)
  if pattern:sub(1, 3) == "re:" then return name:find(pattern:sub(4)) ~= nil end
  local lua = "^" .. pattern:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0"):gsub("%*", ".*") .. "$"
  if not pattern:find(":", 1, true) then lua = "^[^:]*:?" .. lua:sub(2) end   -- "*log" also matches "minecraft:oak_log"
  return name:find(lua) ~= nil
end

--- Names of inventory peripherals on the network.
function M.inventories(env)
  local p = per(env)
  local out = {}
  for _, name in ipairs(p.getNames()) do
    local isInv
    if p.hasType then isInv = p.hasType(name, "inventory") else isInv = p.getType(name) == "inventory" end
    if isInv then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

--- Index of everything stored: { items = { name = { total, at = { {inv, slot, count} } } }, free = { inv = slots }, slots }
function M.scan(env, exclude)
  local p = per(env)
  local index = { items = {}, free = {}, invs = {} }
  for _, inv in ipairs(M.inventories(env)) do
    if not (exclude and exclude[inv]) then
      local dev = p.wrap(inv)
      local used = 0
      for slot, it in pairs(dev.list()) do
        used = used + 1
        local e = index.items[it.name] or { total = 0, at = {} }
        e.total = e.total + it.count
        e.at[#e.at + 1] = { inv = inv, slot = slot, count = it.count }
        index.items[it.name] = e
      end
      index.free[inv] = dev.size() - used
      index.invs[#index.invs + 1] = inv
    end
  end
  return index
end

--- Find item names matching a pattern. Returns sorted array of { name, total }.
function M.find(index, pattern)
  local out = {}
  for name, e in pairs(index.items) do
    if M.matches(pattern, name) then out[#out + 1] = { name = name, total = e.total, at = e.at } end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

--- Move up to `count` of items matching `pattern` into `dest`. Returns the number moved.
function M.get(env, pattern, count, dest)
  local p = per(env)
  local index = M.scan(env, { [dest] = true })
  local moved = 0
  for _, item in ipairs(M.find(index, pattern)) do
    for _, loc in ipairs(item.at) do
      if moved >= count then return moved end
      local n = p.wrap(loc.inv).pushItems(dest, loc.slot, count - moved)
      moved = moved + (n or 0)
    end
  end
  return moved
end

--- The destination inventory for an item under the rules (or overflow), or nil.
function M.destination(cfg, itemName)
  for _, rule in ipairs(cfg.rules or {}) do
    if M.matches(rule.match, itemName) then return rule.to end
  end
  return cfg.overflow
end

--- One sorting pass over the input inventory. Returns { moved = n, stuck = n, by = { [inventory] = n } }.
function M.sortOnce(cfg, env)
  local p = per(env)
  local input = p.wrap(cfg.input)
  local result = { moved = 0, stuck = 0, by = {} }
  if not input then return nil, "input inventory " .. tostring(cfg.input) .. " is not on the network" end
  for slot, it in pairs(input.list()) do
    local to = M.destination(cfg, it.name)
    if to and to ~= cfg.input then
      local n = input.pushItems(to, slot) or 0
      if n < it.count and cfg.overflow and cfg.overflow ~= to and cfg.overflow ~= cfg.input then
        n = n + (input.pushItems(cfg.overflow, slot) or 0)
      end
      result.moved = result.moved + n
      result.by[to] = (result.by[to] or 0) + n
      if n < it.count then result.stuck = result.stuck + (it.count - n) end
    else
      result.stuck = result.stuck + it.count
    end
  end
  return result
end

function M.main(args, io, env)
  io = io or cli.io()
  local pos, opts = cli.parse(args, M.SPEC)
  if not pos then io.err(opts) return false end
  local cmd = pos[1]
  local cfg = M.load()
  cfg.rules = cfg.rules or {}
  if cmd == "scan" then
    local index = M.scan(env)
    local names = {}
    for n in pairs(index.items) do names[#names + 1] = n end
    table.sort(names)
    io.say(("%d inventories, %d kinds of item."):format(#index.invs, #names))
    for _, n in ipairs(names) do io.say(("%6d  %s"):format(index.items[n].total, n)) end
    return true
  elseif cmd == "find" then
    if not pos[2] then io.err("usage: storage find <pattern>") return false end
    local hits = M.find(M.scan(env), pos[2])
    if #hits == 0 then io.say("Not found.") return true end
    for _, h in ipairs(hits) do
      local where = {}
      for _, a in ipairs(h.at) do where[#where + 1] = ("%s[%d]x%d"):format(a.inv, a.slot, a.count) end
      io.say(("%s: %d (%s)"):format(h.name, h.total, table.concat(where, ", ")))
    end
    return true
  elseif cmd == "get" then
    local count, dest = tonumber(pos[3] or ""), pos[4]
    if not (pos[2] and count and dest) then io.err("usage: storage get <pattern> <count> <inventory>") return false end
    if not per(env).wrap(dest) then io.err(dest .. " is not on the network") return false end
    io.say(("Moved %d item(s)."):format(M.get(env, pos[2], count, dest)))
    return true
  elseif cmd == "input" or cmd == "overflow" then
    if not (pos[2] and per(env).wrap(pos[2])) then io.err("usage: storage " .. cmd .. " <inventory on the network>") return false end
    cfg[cmd] = pos[2]
    M.save(cfg)
    io.say(cmd .. " is now " .. pos[2])
    return true
  elseif cmd == "rule" then
    local sub = pos[2]
    if sub == "add" then
      if not (pos[3] and pos[4] and per(env).wrap(pos[4])) then io.err("usage: storage rule add <pattern> <inventory on the network>") return false end
      cfg.rules[#cfg.rules + 1] = { match = pos[3], to = pos[4] }
      M.save(cfg)
      io.say(("Rule %d: %s -> %s"):format(#cfg.rules, pos[3], pos[4]))
      return true
    elseif sub == "list" then
      for i, r in ipairs(cfg.rules) do io.say(("%d. %s -> %s"):format(i, r.match, r.to)) end
      if #cfg.rules == 0 then io.say("No rules yet.") end
      io.say("input: " .. tostring(cfg.input) .. "   overflow: " .. tostring(cfg.overflow))
      return true
    elseif sub == "remove" then
      local n = tonumber(pos[3] or "")
      if not (n and cfg.rules[n]) then io.err("no such rule") return false end
      table.remove(cfg.rules, n)
      M.save(cfg)
      io.say("Removed.")
      return true
    end
  elseif cmd == "sort" then
    if not cfg.input then io.err("Set the input chest first: storage input <inventory>") return false end
    local rounds = 0
    while true do
      local r, err = M.sortOnce(cfg, env)
      if not r then io.err(err) return false end
      if r.moved > 0 or r.stuck > 0 then
        io.say(("Sorted %d item(s)%s."):format(r.moved, r.stuck > 0 and (", " .. r.stuck .. " could not be placed") or ""))
      end
      rounds = rounds + 1
      if opts.once or (env and env.maxRounds and rounds >= env.maxRounds) then return true end
      sleep(opts.interval or 10)
    end
  end
  io.say("usage: storage scan | find | get | sort | input | overflow | rule add|list|remove")
  return false
end

return M
