-- SPDX-License-Identifier: AGPL-3.0-or-later
-- quarry: dig a rectangular pit, top layer first (the old "dig" idea done properly).
--   quarry [length] [width] [depth] [--dump back|down|up] [--junk] [--stay] [--yes]
-- The pit starts directly below the turtle and extends `length` forward and `width` to the right (including the
-- turtle's own column), `depth` layers down. With a chest behind the start, --dump back empties the turtle when full.
local cli = require("tsrapps.cli")
local E = require("tsrapps.excavate")

local M = {}

M.SPEC = { stay = "bool", dump = "string", junk = "bool", yes = "bool", _alias = { y = "yes" } }

function M.build(args, io)
  local pos, opts = cli.parse(args, M.SPEC)
  if not pos then return nil, opts end
  local length = cli.count(pos[1] or io.prompt("Pit length", 8))
  local width = cli.count(pos[2] or io.prompt("Pit width", 8))
  local depth = cli.count(pos[3] or io.prompt("Pit depth", 8))
  if not (length and width and depth) then return nil, "length, width and depth must be whole numbers of at least 1" end
  if opts.dump and not ({ back = 1, down = 1, up = 1 })[opts.dump] then return nil, "--dump must be back, down or up" end
  return {
    name = "quarry",
    params = { length = length, width = width, depth = depth },
    cmd = { "quarry", table.unpack(args) },
    cells = E.plan({ f0 = 0, f1 = length - 1, r0 = 0, r1 = width - 1, u0 = -depth, u1 = -1, order = "layers", udown = true }),
    io = io, dump = opts.dump, junk = opts.junk, stay = opts.stay, yes = opts.yes,
    summary = ("%dx%d pit, %d deep: %d blocks"):format(length, width, depth, length * width * depth),
  }
end

function M.main(args, io)
  io = io or cli.io()
  if not rawget(_G, "turtle") then io.err("quarry only runs on a turtle.") return false end
  local T = require("tsr.turtle")
  local ctx, err = M.build(args, io)
  if not ctx then io.err(err) return false end
  io.say(("%s, about %d fuel."):format(ctx.summary, E.fuelEstimate(ctx.cells)))
  if not ctx.yes and not T.job.resumable(ctx.name, ctx.params) and not io.ask("Start digging?", true) then return false end
  local ok, why = E.run(ctx)
  if ok == true then io.say("Quarry finished.") return true end
  io.err("Stopped: " .. tostring(why))
  return false
end

return M
