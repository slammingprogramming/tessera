-- SPDX-License-Identifier: AGPL-3.0-or-later
-- build: the building assistant. Places blocks from the turtle's inventory in shapes or from a blueprint file.
--   build floor <length> <width> [block]        a flat rectangle
--   build wall  <length> <height> [block]       a wall running to the right
--   build box   <length> <width> <height> [block]   a hollow box (floor, walls and roof)
--   build file  <blueprint> [--replace]         layers of characters, see below
--   options: --yes (no question)  --nowait (stop instead of waiting for missing materials)
-- Coordinates: the structure starts one block IN FRONT of the turtle (f = 1..), extends to the right (r = 0.., including
-- the turtle's own column) and upward from the turtle's level (u = 0..). The turtle flies over the layer it is building
-- and places each block downward, bottom layer first, so it never gets walled in.
--
-- Blueprint files:
--   # comments and blank lines are ignored
--   legend                      (before the first layer)
--   # = minecraft:stone_bricks       one "char = item" line per symbol; "." and space mean "nothing here"
--   g = glass
--   layer                       starts the next layer up (the first one is at the turtle's level)
--   ###                         rows go away from the turtle (first row nearest), characters go to the right
--   #g#
local T = require("tsr.turtle")
local cli = require("tsrapps.cli")

local M = {}

M.SPEC = { yes = "bool", nowait = "bool", replace = "bool", _alias = { y = "yes" } }

--- "stone" -> "minecraft:stone"; names that already contain a namespace are kept.
function M.normalize(name)
  if not name:find(":", 1, true) then return "minecraft:" .. name end
  return name
end

---------------------------------------------------------------------------------------------------------------------
-- Shapes -> cells { f, r, u, block }
---------------------------------------------------------------------------------------------------------------------

function M.floor(length, width, block)
  local cells = {}
  for f = 1, length do for r = 0, width - 1 do cells[#cells + 1] = { f = f, r = r, u = 0, block = block } end end
  return cells
end

function M.wall(length, height, block)
  local cells = {}
  for u = 0, height - 1 do for r = 0, length - 1 do cells[#cells + 1] = { f = 1, r = r, u = u, block = block } end end
  return cells
end

function M.box(length, width, height, block)
  local cells = {}
  for u = 0, height - 1 do
    for f = 1, length do
      for r = 0, width - 1 do
        local shell = u == 0 or u == height - 1 or f == 1 or f == length or r == 0 or r == width - 1
        if shell then cells[#cells + 1] = { f = f, r = r, u = u, block = block } end
      end
    end
  end
  return cells
end

--- Parse blueprint text. Returns cells, or nil + error message (with the line number).
--- Comments (# ...) and the word "legend" are only allowed before the first layer, because "#" is a normal symbol
--- inside layers.
function M.parseBlueprint(text)
  local legend, cells = {}, {}
  local layer, row = nil, 0
  local n = 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    line = line:gsub("\r$", "")
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed == "layer" then
      layer = (layer or -1) + 1
      row = 0
    elseif layer == nil then
      if trimmed ~= "" and trimmed ~= "legend" then
        local sym, item = trimmed:match("^(%S)%s*=%s*(%S+)$")
        if sym then
          legend[sym] = (item == "air") and false or M.normalize(item)
        elseif trimmed:sub(1, 1) ~= "#" then
          return nil, ("line %d: expected 'symbol = item' in the legend"):format(n)
        end
      end
    elseif line ~= "" then
      row = row + 1
      for col = 1, #line do
        local ch = line:sub(col, col)
        if ch ~= " " and ch ~= "." then
          local block = legend[ch]
          if block == nil then return nil, ("line %d: symbol '%s' is not in the legend"):format(n, ch) end
          if block then cells[#cells + 1] = { f = row, r = col - 1, u = layer, block = block } end
        end
      end
    end
  end
  if #cells == 0 then return nil, "the blueprint contains no blocks" end
  return cells
end

--- Order cells layer by layer, each layer as a snake over rows (so the turtle wastes few moves).
function M.order(cells)
  table.sort(cells, function(a, b)
    if a.u ~= b.u then return a.u < b.u end
    if a.f ~= b.f then return a.f < b.f end
    return a.r < b.r
  end)
  -- reverse every other row within a layer
  local out, i = {}, 1
  while i <= #cells do
    local j = i
    while j < #cells and cells[j + 1].u == cells[i].u and cells[j + 1].f == cells[i].f do j = j + 1 end
    local row = {}
    for k = i, j do row[#row + 1] = cells[k] end
    if cells[i].f % 2 == 0 then
      for k = #row, 1, -1 do out[#out + 1] = row[k] end
    else
      for k = 1, #row do out[#out + 1] = row[k] end
    end
    i = j + 1
  end
  return out
end

--- Blocks needed: { [name] = count }.
function M.materials(cells)
  local need = {}
  for _, c in ipairs(cells) do need[c.block] = (need[c.block] or 0) + 1 end
  return need
end

---------------------------------------------------------------------------------------------------------------------
-- Building
---------------------------------------------------------------------------------------------------------------------

local function shortages(need)
  local missing = {}
  for name, count in pairs(need) do
    local have = T.countItems(name)
    if have < count then missing[#missing + 1] = { name = name, short = count - have } end
  end
  table.sort(missing, function(a, b) return a.name < b.name end)
  return missing
end

--- Build the ordered cell list. ctx: name, params, cmd, cells, io, replace, nowait, stopAfter (test hook).
--- Returns true, "paused", or false + reason.
function M.run(ctx)
  T.load()
  local io = ctx.io
  local cells = M.order(ctx.cells)
  local F, done
  local saved = T.job.resumable(ctx.name, ctx.params)
  if saved and saved.progress.origin then
    F, done = T.frame(saved.progress.origin), saved.progress.idx or 0
    io.say(("Resuming build at block %d/%d"):format(done, #cells))
  else
    F, done = T.frame(), 0
    T.job.begin(ctx.name, ctx.params, ctx.cmd)
    T.job.update({ origin = F.origin, idx = 0 })
  end

  local need = {}
  for i = done + 1, #cells do need[cells[i].block] = (need[cells[i].block] or 0) + 1 end
  while true do
    local missing = shortages(need)
    if #missing == 0 then break end
    local parts = {}
    for _, m in ipairs(missing) do parts[#parts + 1] = ("%d x %s"):format(m.short, m.name) end
    if ctx.nowait then return false, "missing materials: " .. table.concat(parts, ", ") end
    io.warn("Missing materials: " .. table.concat(parts, ", ") .. ". Add them and I will carry on.")
    io.waitInventory(5)
  end

  local fuelNeeded = #cells * 3 + 30
  if not T.ensureFuel(fuelNeeded) then
    io.warn(("Need about %d fuel; waiting for some."):format(fuelNeeded))
    while not T.ensureFuel(fuelNeeded) do io.waitInventory(5) end
  end

  local placed = 0
  for i = done + 1, #cells do
    local c = cells[i]
    local ok, err = F.goto(c.f, c.r, c.u + 1, { dig = true })
    if not ok then
      T.job.update({ idx = i - 1 })
      return false, ("cannot reach block %d: %s"):format(i, tostring(err))
    end
    local has, info = turtle.inspectDown()
    if has and info.name == c.block then
      -- already there
    else
      if has then
        if ctx.replace then turtle.digDown() else has = "occupied" end
      end
      if has ~= "occupied" then
        if not T.selectItem(c.block) then
          T.job.update({ idx = i - 1 })
          return false, "ran out of " .. c.block
        end
        if not turtle.placeDown() then
          T.job.update({ idx = i - 1 })
          return false, ("could not place %s at step %d"):format(c.block, i)
        end
        placed = placed + 1
      end
    end
    if i % 8 == 0 or i == #cells then T.job.update({ idx = i }) end
    if ctx.stopAfter and placed >= ctx.stopAfter and i < #cells then
      T.job.update({ idx = i })
      return "paused"
    end
  end
  -- go home sideways first, at flying height: descending first would dig into the blocks just placed below us
  F.goto(0, 0, 0, { dig = true, order = "xzy" })
  F.face(0)
  T.job.finish()
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- Command line
---------------------------------------------------------------------------------------------------------------------

local USAGE = "usage: build floor <length> <width> [block] | wall <length> <height> [block] | box <length> <width> <height> [block] | file <blueprint>"

--- Turn arguments into a run context. Returns ctx or nil, error.
function M.build(args, io, readFile)
  local pos, opts = cli.parse(args, M.SPEC)
  if not pos then return nil, opts end
  local shape = table.remove(pos, 1)
  local cells, params
  if shape == "floor" or shape == "wall" then
    local a, b = cli.count(pos[1]), cli.count(pos[2])
    if not (a and b) then return nil, USAGE end
    local block = M.normalize(pos[3] or "cobblestone")
    cells = (shape == "floor" and M.floor or M.wall)(a, b, block)
    params = { shape = shape, a = a, b = b, block = block }
  elseif shape == "box" then
    local a, b, c = cli.count(pos[1]), cli.count(pos[2]), cli.count(pos[3])
    if not (a and b and c) then return nil, USAGE end
    local block = M.normalize(pos[4] or "cobblestone")
    cells = M.box(a, b, c, block)
    params = { shape = "box", a = a, b = b, c = c, block = block }
  elseif shape == "file" then
    if not pos[1] then return nil, USAGE end
    local text = (readFile or function(p)
      local h = fs.open(p, "r")
      if not h then return nil end
      local t = h.readAll()
      h.close()
      return t
    end)(pos[1])
    if not text then return nil, "cannot read " .. pos[1] end
    local err
    cells, err = M.parseBlueprint(text)
    if not cells then return nil, err end
    params = { shape = "file", file = pos[1], blocks = #cells }
  else
    return nil, USAGE
  end
  return {
    name = "build", params = params, cmd = { "build", table.unpack(args) }, cells = cells, io = io,
    replace = opts.replace, nowait = opts.nowait, yes = opts.yes,
  }
end

function M.main(args, io)
  io = io or cli.io()
  if not rawget(_G, "turtle") then io.err("build only runs on a turtle.") return false end
  local ctx, err = M.build(args, io)
  if not ctx then io.err(err) return false end
  local need = M.materials(ctx.cells)
  local lines = {}
  for name, count in pairs(need) do lines[#lines + 1] = ("%d x %s"):format(count, name) end
  table.sort(lines)
  io.say(("Building %d blocks: %s"):format(#ctx.cells, table.concat(lines, ", ")))
  if not ctx.yes and not T.job.resumable(ctx.name, ctx.params) and not io.ask("Start building?", true) then return false end
  local ok, why = M.run(ctx)
  if ok == true then io.say("Build finished.") return true end
  io.err("Stopped: " .. tostring(why))
  return false
end

return M
