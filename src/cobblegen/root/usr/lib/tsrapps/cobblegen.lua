-- SPDX-License-Identifier: AGPL-3.0-or-later
-- cobblegen: mine a regenerating block (a lava-and-water cobblestone generator) in front of the turtle.
--   cobblegen [count] [--chest down|back|up] [--wait S]
-- Digs until `count` blocks were mined (default: forever). When only two inventory slots are free it empties into the
-- chest named by --chest, or stops if none was given (it never throws items on the ground). Put the turtle right in front of the generator's output block.
local T = require("tsr.turtle")
local cli = require("tsrapps.cli")

local M = {}

M.SPEC = { chest = "string", wait = "number" }

--- Mine one block. Returns true when something was dug.
function M.mineOnce(wait)
  if not turtle.detect() then T.sleep(wait or 0.5) return false end
  return turtle.dig() and true or false
end

--- Empty everything into the chest on `side`; returns stacks dropped (0 when nothing could be dropped).
function M.emptyOut(side)
  local s = ({ down = "d", up = "u", back = "f" })[side]
  if not s then return 0 end
  if side == "back" then T.turnAround() end
  local n = T.dump(s)
  if side == "back" then T.turnAround() end
  return n
end

function M.main(args, io)
  io = io or cli.io()
  if not rawget(_G, "turtle") then io.err("cobblegen only runs on a turtle.") return false end
  local pos, opts = cli.parse(args, M.SPEC)
  if not pos then io.err(opts) return false end
  local target = pos[1] and cli.count(pos[1]) or math.huge
  if not target then io.err("count must be a whole number of at least 1") return false end
  if opts.chest and not ({ down = 1, up = 1, back = 1 })[opts.chest] then io.err("--chest must be down, back or up") return false end
  local mined = 0
  while mined < target do
    if M.mineOnce(opts.wait) then mined = mined + 1 end
    if T.emptySlots() <= 2 then
      local n = opts.chest and M.emptyOut(opts.chest) or 0
      if n == 0 or T.emptySlots() <= 2 then
        io.warn("Inventory full and nowhere to put it; stopping.")
        break
      end
    end
  end
  io.say(("Mined %d blocks."):format(mined))
  return true
end

return M
