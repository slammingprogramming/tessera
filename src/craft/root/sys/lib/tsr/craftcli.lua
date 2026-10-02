-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The autocraft command (named so that it does not hide the stock `craft`; crafty turtle with a crafting table). Commands:
--   autocraft <item> [count] [--stash down|up|front] [--source up|down|front]     make items (and what they are made of)
--   autocraft plan <item> [count]                                                 show what would be crafted and what is missing
--   autocraft list [text]                                                         craftable items          autocraft learn [--shapeless]   teach a recipe
--   autocraft forget <item>                                                       remove a learned recipe
-- The stash is a chest next to the turtle (default: below) where ingredients wait and finished items land; the optional source chest is
-- emptied into the stash first. Put materials into the stash, run `autocraft furnace`, collect the furnace from the stash.
local craft = require("tsr.craft")
local vfs = require("tsr.vfs")

local M = {}

M.CONFIG = "/etc/tsr/craft.cfg"
M.LEARNED = "/etc/tsr/recipes.d"

local function defaultIO()
  local io = {}
  local function color(c) if term.isColor() then term.setTextColor(c) end end
  function io.say(t) print(t) end
  function io.err(t) color(colors.red) print(t) color(colors.white) end
  return io
end

local function flagsOf(args)
  local flags, words, i = {}, {}, 1
  while i <= #args do
    local a = args[i]
    if a == "--stash" or a == "--source" then flags[a:sub(3)] = args[i + 1] i = i + 1
    elseif a:sub(1, 2) == "--" then flags[a:sub(3)] = true
    else words[#words + 1] = a end
    i = i + 1
  end
  return flags, words
end

--- "furnace" -> "minecraft:furnace"; a unique partial name also works. Returns the full name or nil + reason.
function M.itemName(db, text)
  if db.recipes[text] then return text end
  if not text:find(":", 1, true) and db.recipes["minecraft:" .. text] then return "minecraft:" .. text end
  local found = {}
  for name in pairs(db.recipes) do if name:find(text, 1, true) then found[#found + 1] = name end end
  table.sort(found)
  if #found == 1 then return found[1] end
  if #found == 0 then return nil, "no recipe for '" .. text .. "' (autocraft list, or teach it with autocraft learn)" end
  return nil, "'" .. text .. "' could be: " .. table.concat(found, ", ", 1, math.min(#found, 8))
end

local function config(flags)
  local c = vfs.readTable(M.CONFIG) or {}
  return { stash = flags.stash or c.stash or "down", source = flags.source or c.source }
end

function M.run(args, io, env)
  io = io or defaultIO()
  env = env or {}
  local flags, words = flagsOf(args)
  local db = env.db or craft.load(env.dirs)
  local sub = words[1]

  if sub == "list" then
    local names = {}
    for name in pairs(db.recipes) do
      if not words[2] or name:find(words[2], 1, true) then names[#names + 1] = name end
    end
    table.sort(names)
    for _, n in ipairs(names) do io.say(n) end
    io.say(#names .. " recipe(s)")
    return true
  elseif sub == "learn" then
    local doc, err = craft.learn({ turtle = env.turtle }, { shapeless = flags.shapeless })
    if not doc then io.err(tostring(err)) return false end
    local r = doc.recipes[1]
    vfs.writeFile(M.LEARNED .. "/" .. r.out:gsub("[^%w_%-]", "_") .. ".lua", craft.serialize(doc))
    io.say(("Learned: %d x %s (%s)"):format(r.count, r.out, r.shapeless and "shapeless" or "shaped"))
    return true
  elseif sub == "forget" then
    local name = words[2] and M.itemName(db, words[2])
    if not name then io.err("usage: autocraft forget <item>") return false end
    local path = M.LEARNED .. "/" .. name:gsub("[^%w_%-]", "_") .. ".lua"
    if not fs.exists(path) then io.err("that recipe is not one you taught") return false end
    fs.delete(path)
    io.say("forgot " .. name)
    return true
  end

  local planOnly = sub == "plan"
  if planOnly then table.remove(words, 1) end
  local item, err = M.itemName(db, words[1] or "")
  if not words[1] then io.err("usage: autocraft <item> [count] | plan | list | learn | forget") return false end
  if not item then io.err(err) return false end
  local count = tonumber(words[2]) or 1
  local cfg = config(flags)
  local e = { turtle = env.turtle, stash = cfg.stash, source = cfg.source, db = db, log = function(t) io.say(t) end, stockOverride = env.stockOverride }
  if planOnly then
    craft.stock(e)
    local have = e.stockOverride or craft.inspectStash(e)
    local steps, missing = craft.plan(db, item, count, have)
    for _, s in ipairs(steps) do io.say(("craft %d x %s"):format(s.times * s.recipe.count, s.out)) end
    if missing then
      for name, n in pairs(missing) do io.say(("missing: %d x %s"):format(n, name)) end
      return false
    end
    return true
  end
  local ok, merr = craft.make(item, count, e)
  if not ok then io.err(tostring(merr)) return false end
  io.say(("Done: %d x %s are in the stash (%s)."):format(count, item, cfg.stash))
  return true
end

function M.main(args) return M.run(args) end

return M
