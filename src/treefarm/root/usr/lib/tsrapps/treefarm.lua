-- SPDX-License-Identifier: AGPL-3.0-or-later
-- treefarm: a self-running tree farm. Rebuilt from the old treefarm script (same idea: wait for the tree in front,
-- chop it, replant, dump the wood, keep fuelled) with item-name matching instead of fixed slots, any wood type, and
-- fuel taken from the logs it chops.
--   treefarm [--chest down|back|up|none] [--fuel N] [--wait S] [--once]
-- Setup: put the turtle facing the spot where a sapling grows (dirt or grass underneath), saplings anywhere in its
-- inventory, and a chest below it (default), behind it (--chest back) or above it (--chest up).
local T = require("tsr.turtle")
local cli = require("tsrapps.cli")

local M = {}

M.SPEC = { chest = "string", fuel = "number", wait = "number", once = "bool", rounds = "number" }

local function isLog(d) return d and d.name:find("log$") ~= nil or d and d.name:find("stem$") ~= nil end
local function isSapling(d) return d and d.name:find("sapling$") ~= nil end
local function isFuelKeeper(d)
  return d and (isSapling(d) or d.name == "minecraft:coal" or d.name == "minecraft:charcoal")
end
M.isLog, M.isSapling = isLog, isSapling

--- Is a mature tree standing in front of the turtle?
function M.treeAhead()
  local ok, info = turtle.inspect()
  return ok and isLog(info)
end

--- Fell the tree in front (climbing the trunk), then come back down. Returns the number of logs cut.
function M.chop()
  local cut = 0
  local ok = T.digMove("f")
  if not ok then return 0 end
  cut = 1
  local height = 0
  while true do
    local has, info = turtle.inspectUp()
    if not (has and isLog(info)) then break end
    if not T.digMove("u") then break end
    height = height + 1
    cut = cut + 1
  end
  for _ = 1, height do T.down() end
  T.back()
  return cut
end

--- Plant a sapling in front. Returns true or false + reason.
function M.replant()
  local slot = T.selectItem(isSapling)
  if not slot then return false, "no sapling in the inventory" end
  if turtle.place() then return true end
  return false, "the sapling could not be placed (something is in the way, or the ground is wrong)"
end

--- Empty everything except saplings and fuel into the chest on `side`.
function M.dump(side)
  if side == "none" then return 0 end
  local s = ({ down = "d", up = "u", back = "b" })[side or "down"]
  if s == "b" then
    T.turnAround()
    local n = T.dump("f", nil, isFuelKeeper)
    T.turnAround()
    return n
  end
  return T.dump(s, nil, isFuelKeeper)
end

--- One pass: refuel if needed, fell a waiting tree, replant, dump. Returns "waiting" or a summary table.
function M.cycle(opts, io)
  local fuelMin = opts.fuel or 100
  local okFuel = T.ensureFuel(fuelMin)
  if not okFuel and T.fuel() < 5 then return "no fuel" end
  if not M.treeAhead() then return "waiting" end
  local logs = M.chop()
  T.ensureFuel(fuelMin) -- the logs just cut are fuel too
  local planted, why = M.replant()
  if not planted then io.warn("Replant failed: " .. tostring(why)) end
  local dumped = M.dump(opts.chest)
  return { logs = logs, replanted = planted, dumped = dumped }
end

function M.main(args, io)
  io = io or cli.io()
  if not rawget(_G, "turtle") then io.err("treefarm only runs on a turtle.") return false end
  local pos, opts = cli.parse(args, M.SPEC)
  if not pos then io.err(opts) return false end
  if opts.chest and not ({ down = 1, up = 1, back = 1, none = 1 })[opts.chest] then
    io.err("--chest must be down, back, up or none") return false
  end
  io.say("Tree farm running. Ctrl+T to stop.")
  local rounds = 0
  local total = 0
  while true do
    local r = M.cycle(opts, io)
    if r == "no fuel" then
      io.warn("Out of fuel; waiting for some.")
      io.waitInventory(10)
    elseif r ~= "waiting" then
      total = total + r.logs
      io.say(("Felled a tree: %d logs (%d total)."):format(r.logs, total))
    end
    rounds = rounds + 1
    if opts.once or (opts.rounds and rounds >= opts.rounds) then break end
    T.sleep(opts.wait or 5)
  end
  return true
end

return M
