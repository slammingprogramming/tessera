-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Excavation engine shared by bore (tunnels), carve (rooms), stripmine and quarry.
--
-- A job is a list of cells in *local* coordinates (f forward, r right, u up, relative to where the turtle started),
-- ordered so that consecutive cells are neighbours (a "snake" walk, so the turtle never backtracks over solid rock).
-- The runner walks the list, digging into each cell; it refuels, empties its inventory into a chest (or waits for the
-- player), places torches, saves its progress every few cells and — because the frame origin is saved too — carries on
-- from where it stopped if the turtle is rebooted or unloaded.
local T = require("tsr.turtle")

local E = {}

E.JUNK = {
  "minecraft:cobblestone", "minecraft:dirt", "minecraft:gravel", "minecraft:stone", "minecraft:diorite",
  "minecraft:andesite", "minecraft:granite", "minecraft:netherrack", "minecraft:cobbled_deepslate",
  "minecraft:deepslate", "minecraft:tuff", "minecraft:sand", "minecraft:sandstone",
}

---------------------------------------------------------------------------------------------------------------------
-- Planning
---------------------------------------------------------------------------------------------------------------------

--- Snake (boustrophedon) order over an A x B x C grid: yields {a, b, c} zero-based, every step changing one index by 1.
function E.snake(A, B, C)
  local out = {}
  for i = 0, A - 1 do
    for jj = 0, B - 1 do
      local j = (i % 2 == 0) and jj or (B - 1 - jj)
      local forward = ((i * B + jj) % 2 == 0)
      for kk = 0, C - 1 do
        out[#out + 1] = { i, j, forward and kk or (C - 1 - kk) }
      end
    end
  end
  return out
end

--- Cells of a box. spec: f0,f1,r0,r1,u0,u1 (inclusive local ranges), order "slices" (walk forward slice by slice; good
--- for tunnels) or "layers" (level by level; good for rooms and pits), udown (visit layers top to bottom).
--- Returns array of { f, r, u, s = slice index, last = true on a slice's final cell }.
function E.plan(spec)
  local Fn, Rn, Un = spec.f1 - spec.f0 + 1, spec.r1 - spec.r0 + 1, spec.u1 - spec.u0 + 1
  local cells = {}
  if (spec.order or "slices") == "slices" then
    for _, c in ipairs(E.snake(Fn, Rn, Un)) do
      cells[#cells + 1] = { f = spec.f0 + c[1], r = spec.r0 + c[2], u = spec.udown and (spec.u1 - c[3]) or (spec.u0 + c[3]), s = c[1] + 1 }
    end
    for i, cell in ipairs(cells) do
      local nxt = cells[i + 1]
      if not nxt or nxt.s ~= cell.s then cell.last = true end
    end
  else
    for _, c in ipairs(E.snake(Un, Rn, Fn)) do
      local u = spec.udown and (spec.u1 - c[1]) or (spec.u0 + c[1])
      cells[#cells + 1] = { f = spec.f0 + c[3], r = spec.r0 + c[2], u = u, s = c[1] + 1 }
    end
  end
  return cells
end

--- Every consecutive pair of cells must be neighbours; returns true or false + index of the first gap (for tests).
function E.contiguous(cells)
  for i = 2, #cells do
    local a, b = cells[i - 1], cells[i]
    if math.abs(a.f - b.f) + math.abs(a.r - b.r) + math.abs(a.u - b.u) ~= 1 then return false, i end
  end
  return true
end

--- Rough fuel needed: one move per cell, some slack for detours and the way home.
function E.fuelEstimate(cells)
  local far = 0
  for _, c in ipairs(cells) do far = math.max(far, math.abs(c.f) + math.abs(c.r) + math.abs(c.u)) end
  return math.ceil(#cells * 1.15) + far * 2 + 20
end

---------------------------------------------------------------------------------------------------------------------
-- Running
---------------------------------------------------------------------------------------------------------------------

local function keepSet(ctx)
  local keep = {}
  local torchSlot = ctx.torch and T.slotOf(ctx.torch.item)
  if torchSlot then keep[torchSlot] = true end
  return keep
end

local function waitFor(ctx, why, cond)
  local said
  while not cond() do
    if not said then ctx.io.warn(why) said = true end
    ctx.io.waitInventory(5)
    if ctx.giveUp and ctx.giveUp() then return false end
  end
  return true
end

local function ensureFuel(ctx, need)
  local ok = T.ensureFuel(need)
  if ok then return true end
  return waitFor(ctx, ("Out of fuel (need %d). Put fuel in the turtle's inventory."):format(need), function()
    return T.ensureFuel(need)
  end)
end

--- Empty the inventory: junk first (if asked), then into a chest (if configured), else wait for the player.
local function handleFull(ctx, F, resumeCell)
  if T.emptySlots() > 0 then return true end
  if ctx.junk then
    local prev = turtle.getSelectedSlot()
    F.face(2)                       -- throw the rubbish into the open tunnel behind us
    for slot = 1, 16 do
      if turtle.getItemCount(slot) > 0 and T.matcher(E.JUNK)(turtle.getItemDetail(slot)) then
        turtle.select(slot)
        turtle.drop()
      end
    end
    turtle.select(prev)
    if T.emptySlots() > 0 then return true end
  end
  if ctx.dump then
    F.goto(0, 0, 0, { dig = true })
    local keep = keepSet(ctx)
    if ctx.dump == "back" then F.face(2) T.dump("f", keep, ctx.keepItems)
    elseif ctx.dump == "down" then T.dump("d", keep, ctx.keepItems)
    elseif ctx.dump == "up" then T.dump("u", keep, ctx.keepItems) end
    F.face(0)
    if T.emptySlots() > 0 then
      if resumeCell then F.goto(resumeCell.f, resumeCell.r, resumeCell.u, { dig = true }) end
      return true
    end
  end
  F.goto(0, 0, 0, { dig = true })
  F.face(0)
  local ok = waitFor(ctx, "Inventory full: empty me (or connect a chest) and I will carry on.", function() return T.emptySlots() > 0 end)
  if ok and resumeCell then F.goto(resumeCell.f, resumeCell.r, resumeCell.u, { dig = true }) end
  return ok
end

--- Torches go into a small alcove dug into the left wall, so they never block the way back (a torch is a solid
--- obstacle to a turtle) and always have a wall or floor to stand on.
local function placeTorch(ctx, F, cell)
  if not (ctx.torch and ctx.torch.every and cell.last and cell.s % ctx.torch.every == 0) then return end
  local slot = T.slotOf(ctx.torch.item)
  if not slot then
    if not ctx.torchWarned then ctx.io.warn("No torches left; carrying on in the dark.") ctx.torchWarned = true end
    return
  end
  F.goto(cell.f, 0, ctx.torch.u or 0, { dig = true })
  F.face(3)          -- face the left wall of the tunnel
  turtle.dig()       -- make the alcove
  turtle.select(slot)
  turtle.place()
  F.face(0)
end

--- Run (or resume) a job.
--- ctx: name, params (JSON-able, identifies the job for resume), cmd ({program, args...} to restart it),
---      cells, io, torch = {every, item}, dump ("back"|"down"|"up"), junk, stay, keepItems (item spec kept when dumping),
---      stopAfter (test hook: pause after that many cells), save (cells between progress saves, default 8)
--- Returns true when finished, "paused" (test hook), or false + reason.
function E.run(ctx)
  T.load()
  ctx.io = ctx.io or require("tsrapps.cli").io()
  local cells = ctx.cells
  local F, done
  local saved = T.job.resumable(ctx.name, ctx.params)
  if saved and saved.progress.origin then
    F, done = T.frame(saved.progress.origin), saved.progress.idx or 0
    ctx.io.say(("Resuming %s at step %d/%d"):format(ctx.name, done, #cells))
  else
    F, done = T.frame(), 0
    T.job.begin(ctx.name, ctx.params, ctx.cmd)
    T.job.update({ origin = F.origin, idx = 0 })
  end

  local needFuel = E.fuelEstimate(cells) - done
  if not ensureFuel(ctx, needFuel) then return false, "no fuel" end

  local every = ctx.save or 8
  local processed = 0
  for i = done + 1, #cells do
    local cell = cells[i]
    if not handleFull(ctx, F, cell) then return false, "stopped" end
    local ok, err = F.step(cell.f, cell.r, cell.u)
    if not ok then
      if err == "Out of fuel" then
        if not ensureFuel(ctx, E.fuelEstimate(cells) - i) then return false, "no fuel" end
        ok, err = F.step(cell.f, cell.r, cell.u)
      end
      if not ok then
        T.job.update({ idx = i - 1 })
        return false, ("blocked at step %d: %s"):format(i, tostring(err))
      end
    end
    placeTorch(ctx, F, cell)
    processed = processed + 1
    if i % every == 0 or i == #cells then T.job.update({ idx = i }) end
    if ctx.stopAfter and processed >= ctx.stopAfter and i < #cells then
      T.job.update({ idx = i })
      return "paused"
    end
  end

  if not ctx.stay then
    F.goto(0, 0, 0, { dig = true })
    F.face(0)
  end
  T.job.finish()
  return true
end

return E
