-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The crafting turtle: give it a recipe database and ingredients and it crafts items, including everything the item is made of.
--
-- How a turtle crafts (ComputerCraft): with a crafting table equipped, `turtle.craft(n)` reads the turtle's inventory as a 3x3 grid
-- (slots 1 2 3 / 5 6 7 / 9 10 11), requires every OTHER slot to be empty, crafts up to n times and stores the result starting at the
-- selected slot. So this module works with a STASH chest (default: below the turtle) as the place where everything that is not part of
-- the current craft waits:  park all -> pull exactly the ingredients into their grid cells -> craft -> park the result.
-- Optionally a SOURCE chest (e.g. above) is emptied into the stash first, so you can throw materials into one chest and ask for items.
--
-- Recipes: files in /usr/share/recipes (shipped) and /etc/tsr/recipes.d (yours, e.g. made with `autocraft learn` for modded items):
--   return { tags = { planks = { "_planks$" } },
--            recipes = { { out = "minecraft:stick", count = 4, shape = { "P", "P" }, key = { P = "#planks" } },
--                        { out = "minecraft:torch", count = 4, shapeless = { "minecraft:coal", "minecraft:stick" } } } }
-- An ingredient is an exact item name, "#tag" (any item whose name matches one of the tag's Lua patterns or lists), or { any = { ... } }.
local M = {}

M.GRID = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }          -- turtle slots of the 3x3 grid, row by row
local IS_GRID = {}
for _, s in ipairs(M.GRID) do IS_GRID[s] = true end

M.DIRS = { "/usr/share/recipes", "/etc/tsr/recipes.d" }
M.MAX_DEPTH = 8

---------------------------------------------------------------------------------------------------------------------
-- Recipe database
---------------------------------------------------------------------------------------------------------------------

--- Normalise one recipe: cells[1..9] = ingredient spec | nil (shaped recipes are placed at the top left), or a shapeless list.
function M.normalize(r)
  local out = { out = r.out, count = r.count or 1, learned = r.learned }
  if r.shapeless then
    out.shapeless = {}
    for i, spec in ipairs(r.shapeless) do out.shapeless[i] = spec end
    if #out.shapeless > 9 or #out.shapeless == 0 then return nil, "a shapeless recipe has 1 to 9 ingredients" end
    return out
  end
  out.cells = {}
  local rows = r.shape or {}
  if #rows < 1 or #rows > 3 then return nil, "a shaped recipe has 1 to 3 rows" end
  for y, row in ipairs(rows) do
    if #row < 1 or #row > 3 then return nil, "a recipe row has 1 to 3 columns" end
    for x = 1, #row do
      local ch = row:sub(x, x)
      if ch ~= " " and ch ~= "." then
        local spec = r.key and r.key[ch]
        if not spec then return nil, "no ingredient for '" .. ch .. "'" end
        out.cells[(y - 1) * 3 + x] = spec
      end
    end
  end
  return out
end

--- Load recipes from `dirs` (default M.DIRS). Returns db = { recipes = { [item] = { recipe, ... } }, tags = { name = { patterns } } }.
function M.load(dirs)
  local db = { recipes = {}, tags = {}, problems = {} }
  for _, dir in ipairs(dirs or M.DIRS) do
    if fs.isDir(dir) then
      local names = fs.list(dir)
      table.sort(names)
      for _, name in ipairs(names) do
        if name:match("%.lua$") then
          local chunk, err = loadfile(dir .. "/" .. name, "t", { ipairs = ipairs, pairs = pairs, string = string, table = table, math = math, tostring = tostring })
          local ok, doc = false, nil
          if chunk then ok, doc = pcall(chunk) else doc = err end
          if ok and type(doc) == "table" then M.add(db, doc, name) else db.problems[#db.problems + 1] = name .. ": " .. tostring(doc) end
        end
      end
    end
  end
  return db
end

--- Merge a recipe document ({ tags, recipes }) into a database.
function M.add(db, doc, source)
  for tag, list in pairs(doc.tags or {}) do db.tags[tag] = list end
  for _, r in ipairs(doc.recipes or {}) do
    local n, err = M.normalize(r)
    if n then
      db.recipes[n.out] = db.recipes[n.out] or {}
      table.insert(db.recipes[n.out], 1, n)                -- later files (yours) take precedence over shipped ones
    else
      db.problems[#db.problems + 1] = tostring(source) .. ": " .. tostring(r.out) .. ": " .. tostring(err)
    end
  end
end

--- Does an ingredient spec accept the item called `name`?
function M.matches(db, spec, name)
  if type(spec) == "string" then
    if spec:sub(1, 1) ~= "#" then return spec == name end
    local tag = db.tags[spec:sub(2)]
    if not tag then return false end
    for _, p in ipairs(tag) do
      if p == name or (p:find("[%^%$%%]") and name:find(p)) then return true end
    end
    return false
  elseif type(spec) == "table" and spec.any then
    for _, s in ipairs(spec.any) do if M.matches(db, s, name) then return true end end
  end
  return false
end

local function specText(spec)
  if type(spec) == "table" then return "any of " .. table.concat(spec.any or {}, ", ") end
  return tostring(spec)
end
M.specText = specText

---------------------------------------------------------------------------------------------------------------------
-- Planning
---------------------------------------------------------------------------------------------------------------------

local function copy(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end

--- Ingredients of a recipe as a list of { spec, count } (identical specs merged).
local function needs(r)
  local list, index = {}, {}
  local function add(spec)
    local k = specText(spec)
    if index[k] then list[index[k]].count = list[index[k]].count + 1 else list[#list + 1] = { spec = spec, count = 1 } index[k] = #list end
  end
  if r.shapeless then for _, spec in ipairs(r.shapeless) do add(spec) end
  else for i = 1, 9 do if r.cells[i] then add(r.cells[i]) end end end
  return list
end

--- Plan how to make `count` of `item` from the stock `have` ({ [item] = n }). Returns steps, missing where
--- steps = list of { out, recipe, times, picks = { [specText] = concrete item name } } in the order to execute, and
--- missing = { [spec text] = n } of raw materials that are not available. `have` is not modified.
function M.plan(db, item, count, have)
  have = copy(have or {})
  local steps, missing = {}, {}
  local inProgress = {}                    -- items being crafted right now (a recipe cannot need its own product)

  local function snapshot() return { have = copy(have), steps = #steps, missing = copy(missing) } end
  local function restore(s)
    have, missing = s.have, s.missing
    for i = #steps, s.steps + 1, -1 do steps[i] = nil end
  end

  local function concrete(spec)       -- an item we hold that fits the spec (most plentiful first)
    local best, bestN
    for name, n in pairs(have) do
      if n > 0 and M.matches(db, spec, name) and (not best or n > bestN or (n == bestN and name < best)) then best, bestN = name, n end
    end
    return best
  end

  local need

  --- Get `n` of whatever fits `spec`. Returns ok, the concrete item chosen.
  local function obtain(spec, n, depth)
    if type(spec) == "string" and spec:sub(1, 1) ~= "#" then return need(spec, n, depth), spec end
    local name = concrete(spec)
    if name then return need(name, n, depth), name end
    -- nothing in stock fits: craft something that does (candidates in alphabetical order, the first one that works)
    local candidates = {}
    for out in pairs(db.recipes) do if M.matches(db, spec, out) then candidates[#candidates + 1] = out end end
    table.sort(candidates)
    for _, out in ipairs(candidates) do
      local snap = snapshot()
      if need(out, n, depth) then return true, out end
      restore(snap)
    end
    missing[specText(spec)] = (missing[specText(spec)] or 0) + n
    return false
  end

  function need(name, n, depth)
    if depth > M.MAX_DEPTH or inProgress[name] then missing[name] = (missing[name] or 0) + n return false end
    local got = math.min(have[name] or 0, n)
    have[name] = (have[name] or 0) - got
    local deficit = n - got
    if deficit <= 0 then return true end
    local list = db.recipes[name]
    if not list then missing[name] = (missing[name] or 0) + deficit return false end
    inProgress[name] = true
    local firstFailure                           -- what the first (main) recipe was missing, reported if none works
    for _, r in ipairs(list) do                  -- the first recipe whose ingredients can be found
      local snap = snapshot()
      local times = math.ceil(deficit / r.count)
      local ok, picks = true, {}
      for _, ing in ipairs(needs(r)) do
        local good, chosen = obtain(ing.spec, ing.count * times, depth + 1)
        if good then picks[specText(ing.spec)] = chosen else ok = false end
      end
      if ok then
        steps[#steps + 1] = { out = name, recipe = r, times = times, picks = picks }
        have[name] = (have[name] or 0) + times * r.count - deficit            -- surplus stays in stock
        inProgress[name] = nil
        return true
      end
      firstFailure = firstFailure or copy(missing)
      restore(snap)
    end
    inProgress[name] = nil
    if firstFailure then missing = firstFailure end
    return false
  end

  need(item, count, 1)
  if next(missing) then return steps, missing end
  return steps, nil
end

---------------------------------------------------------------------------------------------------------------------
-- The turtle
---------------------------------------------------------------------------------------------------------------------

local function api(env) return env.turtle or turtle end

--- Direction helpers: the drop / suck functions for "front", "up" or "down".
local function movers(t, dir)
  if dir == "up" then return t.dropUp, t.suckUp end
  if dir == "down" then return t.dropDown, t.suckDown end
  return t.drop, t.suck
end

--- Items in the turtle: { [name] = count }, plus the list of occupied slots.
function M.scan(env)
  local t = api(env)
  local have = {}
  for slot = 1, 16 do
    local d = t.getItemDetail(slot)
    if d then have[d.name] = (have[d.name] or 0) + d.count end
  end
  return have
end

--- Move every item out of the turtle into the stash chest. Returns true or nil + reason.
function M.park(env, only)
  local t = api(env)
  local drop = movers(t, env.stash or "down")
  for slot = 1, 16 do
    if t.getItemCount(slot) > 0 and (not only or only(slot)) then
      t.select(slot)
      if not drop() and t.getItemCount(slot) > 0 then return nil, "the stash chest is full or missing" end
    end
  end
  return true
end

--- Take everything from the source chest into the stash chest (so ingredients can be found there). Returns the number of stacks moved.
function M.stock(env)
  if not env.source then return 0 end
  local t = api(env)
  local _, sourceSuck = movers(t, env.source)
  local drop = movers(t, env.stash or "down")
  local moved = 0
  M.park(env)
  while true do
    t.select(1)
    if not sourceSuck() then break end
    drop()
    if t.getItemCount(1) > 0 then t.select(1) t.drop() break end        -- stash full: leave the rest
    moved = moved + 1
    if moved > 200 then break end
  end
  return moved
end

--- Pull `n` of the item called `name` out of the stash into the (empty) grid slot `slot`. Stacks of other items that come out first are moved
--- aside to free slots outside the grid cells (env._known lists slots that are already settled: finished cells and set-aside junk); the caller
--- puts them back into the stash before crafting. Returns true or nil + reason.
local function pullInto(env, name, n, slot)
  local t = api(env)
  local _, suck = movers(t, env.stash or "down")
  local known = env._known
  local function freeSlot()
    for s = 16, 1, -1 do
      if not env._reserved[s] and not known[s] and t.getItemCount(s) == 0 then return s end
    end
  end
  for _ = 1, 80 do
    local d = t.getItemDetail(slot)
    if d and d.name == name and d.count >= n then known[slot] = true return true end
    t.select(slot)
    if not suck(d and (n - d.count) or n) then return nil, "the stash has no (more) " .. name end
    -- whatever arrived, wherever it landed, is sorted out now
    for s = 1, 16 do
      local item = t.getItemDetail(s)
      if item and not known[s] then
        if s == slot and item.name == name then
          -- the right item in the right place
        elseif item.name == name and s ~= slot then
          t.select(s)
          t.transferTo(slot)
          if t.getItemCount(s) > 0 then
            local f = freeSlot()
            if not f then return nil, "no room to sort through the stash" end
            t.select(s) t.transferTo(f) known[f] = true
          end
        else
          local f = freeSlot()
          if not f then return nil, "no room to sort through the stash (too many other kinds of items in it)" end
          t.select(s)
          t.transferTo(f)
          known[f] = true
        end
      end
    end
  end
  return nil, "could not collect " .. n .. " x " .. name .. " from the stash"
end

--- Assign concrete item names to a recipe's ingredient specs using the picks of the plan, or the stock when none were given.
local function resolve(db, recipe, picks, have)
  local function pick(spec)
    if type(spec) == "string" and spec:sub(1, 1) ~= "#" then return spec end
    local chosen = picks and picks[specText(spec)]
    if chosen then return chosen end
    local best, bestN
    for name, n in pairs(have) do
      if n > 0 and M.matches(db, spec, name) and (not best or n > bestN) then best, bestN = name, n end
    end
    return best
  end
  if recipe.shapeless then
    local list = {}
    for i, spec in ipairs(recipe.shapeless) do list[i] = pick(spec) end
    return list
  end
  local cells = {}
  for i = 1, 9 do if recipe.cells[i] then cells[i] = pick(recipe.cells[i]) end end
  return cells
end

--- Run one crafting step: `times` crafts of recipe `r` (an entry of a plan). Returns true or nil + reason.
function M.craftStep(db, env, step)
  local t = api(env)
  if not t.craft then return nil, "this turtle has no crafting table: equip one (a crafty turtle)" end
  local r = step.recipe
  local left = step.times
  local perBatch = math.max(1, math.floor(64 / r.count))
  while left > 0 do
    local n = math.min(left, perBatch, 64)
    local ok, err = M.park(env)
    if not ok then return nil, err end
    -- which concrete items go where
    local placed = resolve(db, r, step.picks, env.stockBefore or {})
    local cellItems = {}                              -- turtle slot -> item name
    if r.shapeless then
      for i, name in ipairs(placed) do cellItems[M.GRID[i]] = name end
    else
      for i = 1, 9 do if placed[i] then cellItems[M.GRID[i]] = placed[i] end end
    end
    env._reserved, env._known = {}, {}
    for slot in pairs(cellItems) do env._reserved[slot] = true end
    local slots = {}
    for slot in pairs(cellItems) do slots[#slots + 1] = slot end
    table.sort(slots)
    for _, slot in ipairs(slots) do
      local pulled, perr = pullInto(env, cellItems[slot], n, slot)
      if not pulled then
        M.park(env)
        return nil, perr
      end
    end
    -- everything that is not part of the craft goes back before crafting
    M.park(env, function(slot) return not cellItems[slot] end)
    t.select(4)                                       -- the result is stored from the selected slot on: slot 4 is outside the grid
    local crafted, cerr = t.craft(n)
    if not crafted then
      M.park(env)
      return nil, "the turtle could not craft " .. r.out .. " here: " .. tostring(cerr or "no matching recipe")
    end
    M.park(env)
    left = left - n
  end
  return true
end

--- Make `count` of `item`. env: turtle (default the global), stash ("down" default), source (chest to take materials from), db, log(text).
--- Everything the turtle carries and everything in the stash counts as stock; the finished items end up in the stash.
--- Returns true, or nil + reason (with the missing raw materials in the text).
function M.make(item, count, env)
  env = env or {}
  env.stash = env.stash or "down"
  env.db = env.db or M.load()
  local db = env.db
  local log = env.log or function() end
  M.stock(env)
  local t = api(env)
  -- stock = what we carry plus what the stash holds: look into the stash by pulling everything into view, one stack at a time
  M.park(env)
  local have = env.stockOverride or M.inspectStash(env)
  local steps, missing = M.plan(db, item, count, have)
  if missing then
    local parts = {}
    for name, n in pairs(missing) do parts[#parts + 1] = n .. " x " .. name end
    table.sort(parts)
    return nil, "missing: " .. table.concat(parts, ", ")
  end
  env.stockBefore = copy(have)
  for _, step in ipairs(steps) do
    log(("crafting %d x %s (%d time(s))"):format(step.times * step.recipe.count, step.out, step.times))
    local ok, err = M.craftStep(db, env, step)
    if not ok then return nil, err end
    -- the craft changed the stock: keep our picture of it current for the following steps
    local sb = env.stockBefore
    for _, ing in ipairs(needs(step.recipe)) do
      local name = step.picks[specText(ing.spec)] or (type(ing.spec) == "string" and ing.spec)
      if name then sb[name] = (sb[name] or 0) - ing.count * step.times end
    end
    sb[step.out] = (sb[step.out] or 0) + step.times * step.recipe.count
  end
  return true
end

--- What is in the stash, as { [name] = count }: take the stacks out one by one, count them and put them back.
function M.inspectStash(env)
  local t = api(env)
  local drop, suck = movers(t, env.stash or "down")
  local have, held = {}, {}
  M.park(env)
  t.select(1)
  for slot = 1, 16 do
    t.select(slot)
    if not suck() then break end
    held[#held + 1] = slot
    local d = t.getItemDetail(slot)
    if d then have[d.name] = (have[d.name] or 0) + d.count end
    if t.getItemCount(slot) == 0 then break end
  end
  for _, slot in ipairs(held) do
    t.select(slot)
    drop()
  end
  M.park(env)
  return have
end

---------------------------------------------------------------------------------------------------------------------
-- Learning recipes
---------------------------------------------------------------------------------------------------------------------

--- Record the recipe that is currently laid out in the grid by crafting it once. opts: shapeless (bool). Returns the recipe document
--- ({ tags = {}, recipes = { r } }) or nil + reason. The crafted items stay in the turtle.
function M.learn(env, opts)
  opts = opts or {}
  local t = api(env)
  if not t.craft then return nil, "this turtle has no crafting table" end
  local cells, any = {}, false
  for i, slot in ipairs(M.GRID) do
    local d = t.getItemDetail(slot)
    if d then cells[i] = d.name any = true end
  end
  if not any then return nil, "put the ingredients in the 3x3 grid (slots 1-3, 5-7, 9-11) first" end
  local before = M.scan(env)
  t.select(4)
  local ok, err = t.craft(1)
  if not ok then return nil, "that layout does not craft anything: " .. tostring(err) end
  local after = M.scan(env)
  local out, made
  for name, n in pairs(after) do
    local gained = n - (before[name] or 0)
    if gained > 0 and (not made or gained > made) then out, made = name, gained end
  end
  if not out then return nil, "could not tell what was crafted" end
  local recipe = { out = out, count = made, learned = true }
  if opts.shapeless then
    recipe.shapeless = {}
    for i = 1, 9 do if cells[i] then recipe.shapeless[#recipe.shapeless + 1] = cells[i] end end
  else
    local key, letters, rows = {}, {}, { "", "", "" }
    local next_ = 0
    local rowUsed = { false, false, false }
    for i = 1, 9 do
      local y, x = math.floor((i - 1) / 3) + 1, (i - 1) % 3 + 1
      local ch = " "
      if cells[i] then
        if not letters[cells[i]] then next_ = next_ + 1 letters[cells[i]] = string.char(64 + next_) key[string.char(64 + next_)] = cells[i] end
        ch = letters[cells[i]]
        rowUsed[y] = true
      end
      rows[y] = rows[y] .. ch
    end
    -- trim empty rows and columns
    local shape = {}
    for y = 1, 3 do if rowUsed[y] then shape[#shape + 1] = rows[y] end end
    local first, last = 3, 1
    for _, row in ipairs(shape) do
      for x = 1, 3 do if row:sub(x, x) ~= " " then first, last = math.min(first, x), math.max(last, x) end end
    end
    for i, row in ipairs(shape) do shape[i] = row:sub(first, last) end
    recipe.shape, recipe.key = shape, key
  end
  return { tags = {}, recipes = { recipe } }
end

--- Serialise a learned recipe document into a Lua file's text.
function M.serialize(doc)
  return "-- learned by `autocraft learn`\nreturn " .. textutils.serialize(doc) .. "\n"
end

return M
