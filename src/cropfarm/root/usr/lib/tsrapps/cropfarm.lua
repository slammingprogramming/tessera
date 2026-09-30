-- SPDX-License-Identifier: AGPL-3.0-or-later
-- cropfarm: harvest and replant a rectangular crop field, only touching ripe plants.
--   cropfarm <length> <width> [--crop wheat|carrots|potatoes|beetroots|nether_wart] [--chest down|back|up|none]
--            [--keep N] [--interval S] [--once]
-- Setup: stand ABOVE the field's near-left corner (crops are one block below the turtle's flight level), facing along
-- the field's length. Seeds go anywhere in the inventory. A chest below the start (default), behind it or above it
-- receives the harvest. --crop lets it fill empty patches; without it only ripe plants are replaced.
local T = require("tsr.turtle")
local cli = require("tsrapps.cli")
local E = require("tsrapps.excavate")

local M = {}

M.SPEC = { crop = "string", chest = "string", keep = "number", interval = "number", once = "bool", rounds = "number" }

--- crop block -> { seed item, ripe age }
M.CROPS = {
  ["minecraft:wheat"] = { seed = "minecraft:wheat_seeds", age = 7 },
  ["minecraft:carrots"] = { seed = "minecraft:carrot", age = 7 },
  ["minecraft:potatoes"] = { seed = "minecraft:potato", age = 7 },
  ["minecraft:beetroots"] = { seed = "minecraft:beetroot_seeds", age = 3 },
  ["minecraft:nether_wart"] = { seed = "minecraft:nether_wart", age = 3 },
}

local function seedSet()
  local set = {}
  for _, c in pairs(M.CROPS) do set[c.seed] = true end
  return set
end

--- Harvest a ripe crop below and replant it. Returns "harvested", "growing", "empty" or "other".
function M.tend(cropName)
  local has, info = turtle.inspectDown()
  if not has then
    if cropName then
      local c = M.CROPS["minecraft:" .. cropName]
      if c and T.selectItem(c.seed) and turtle.placeDown() then return "planted" end
    end
    return "empty"
  end
  local crop = M.CROPS[info.name]
  if not crop then return "other" end
  if (info.state and info.state.age or 0) < crop.age then return "growing" end
  turtle.digDown()
  if T.selectItem(crop.seed) then turtle.placeDown() end
  return "harvested"
end

--- Empty the inventory into a chest, keeping up to `keepSeeds` seeds for replanting.
function M.dump(side, keepSeeds)
  if side == "none" then return 0 end
  local seeds = seedSet()
  local kept = 0
  local n = 0
  local prev = turtle.getSelectedSlot()
  local s = ({ down = "d", up = "u", back = "f" })[side or "down"]
  if side == "back" then T.turnAround() end
  for slot = 1, 16 do
    local count = turtle.getItemCount(slot)
    if count > 0 then
      local d = turtle.getItemDetail(slot)
      local drop = count
      if seeds[d.name] then
        local room = math.max(0, keepSeeds - kept)
        drop = count - math.min(count, room)
        kept = kept + math.min(count, room)
      end
      if drop > 0 then
        turtle.select(slot)
        if T.call(s, "drop", drop) then n = n + 1 end
      end
    end
  end
  if side == "back" then T.turnAround() end
  turtle.select(prev)
  return n
end

--- One full pass over the field. Returns a table of counts.
function M.harvest(length, width, opts, io)
  local F = T.frame()
  local cells = E.snake(length, width, 1)
  local counts = { harvested = 0, growing = 0, empty = 0, planted = 0, other = 0 }
  for _, c in ipairs(cells) do
    local ok, err = F.step(c[1], c[2], 0)
    if not ok then io.warn("Stopped in the field: " .. tostring(err)) break end
    local r = M.tend(opts.crop)
    counts[r] = (counts[r] or 0) + 1
  end
  F.goto(0, 0, 0, { dig = true })
  F.face(0)
  counts.dumped = M.dump(opts.chest, opts.keep or 32)
  return counts
end

function M.main(args, io)
  io = io or cli.io()
  if not rawget(_G, "turtle") then io.err("cropfarm only runs on a turtle.") return false end
  local pos, opts = cli.parse(args, M.SPEC)
  if not pos then io.err(opts) return false end
  local length = cli.count(pos[1] or io.prompt("Field length", 9))
  local width = cli.count(pos[2] or io.prompt("Field width", 9))
  if not (length and width) then io.err("length and width must be whole numbers of at least 1") return false end
  if opts.crop and not M.CROPS["minecraft:" .. opts.crop] then io.err("unknown crop " .. opts.crop) return false end
  if opts.chest and not ({ down = 1, up = 1, back = 1, none = 1 })[opts.chest] then
    io.err("--chest must be down, back, up or none") return false
  end
  local needed = length * width * 2 + 20
  local rounds = 0
  while true do
    if not T.ensureFuel(needed) then
      io.warn(("Need about %d fuel; waiting for some."):format(needed))
      io.waitInventory(10)
    else
      local r = M.harvest(length, width, opts, io)
      io.say(("Harvested %d, %d still growing."):format(r.harvested, r.growing))
      rounds = rounds + 1
      if opts.once or (opts.rounds and rounds >= opts.rounds) then break end
      T.sleep(opts.interval or 300)
    end
  end
  return true
end

return M
