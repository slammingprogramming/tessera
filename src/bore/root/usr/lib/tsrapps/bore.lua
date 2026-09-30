-- SPDX-License-Identifier: AGPL-3.0-or-later
-- bore: dig a tunnel. Successor of the old maketunnel script (which also had configuration, torches, cleaning and
-- save/resume) — now built on the shared excavation engine, so it survives reboots and chunk unloads properly.
--   bore [length] [width] [height] [--torch N | --no-torch] [--dump back|down|up] [--junk] [--stay] [--yes]
-- The tunnel starts in front of the turtle; it is `width` wide to the right (starting with the turtle's own column)
-- and `height` tall from the turtle's level up. Put torches in the inventory for automatic lighting.
local cli = require("tsrapps.cli")
local E = require("tsrapps.excavate")

local M = {}

M.SPEC = { torch = "number", ["no-torch"] = "bool", stay = "bool", dump = "string", junk = "bool", yes = "bool",
           _alias = { y = "yes" } }

--- Turn command-line arguments (plus prompts for missing sizes) into an engine context. Returns ctx or nil, error.
function M.build(args, io, hasTorches)
  local pos, opts = cli.parse(args, M.SPEC)
  if not pos then return nil, opts end
  local length = cli.count(pos[1] or io.prompt("Tunnel length", 10))
  local width = cli.count(pos[2] or io.prompt("Tunnel width", 3))
  local height = cli.count(pos[3] or io.prompt("Tunnel height", 3))
  if not (length and width and height) then return nil, "length, width and height must be whole numbers of at least 1" end
  if opts.dump and not ({ back = 1, down = 1, up = 1 })[opts.dump] then return nil, "--dump must be back, down or up" end
  local torchEvery = opts.torch or 5
  local ctx = {
    name = "bore",
    params = { length = length, width = width, height = height },
    cmd = { "bore", table.unpack(args) },
    cells = E.plan({ f0 = 1, f1 = length, r0 = 0, r1 = width - 1, u0 = 0, u1 = height - 1, order = "slices" }),
    io = io, dump = opts.dump, junk = opts.junk, stay = opts.stay, yes = opts.yes,
    torch = (not opts["no-torch"] and hasTorches) and { every = torchEvery, item = "minecraft:torch", u = math.min(1, height - 1) } or nil,
    summary = ("%dx%dx%d tunnel: %d blocks"):format(length, width, height, length * width * height),
  }
  return ctx
end

function M.main(args, io)
  io = io or cli.io()
  if not rawget(_G, "turtle") then io.err("bore only runs on a turtle.") return false end
  local T = require("tsr.turtle")
  local ctx, err = M.build(args, io, T.slotOf("minecraft:torch") ~= nil)
  if not ctx then io.err(err) return false end
  io.say(("%s, about %d fuel%s."):format(ctx.summary, E.fuelEstimate(ctx.cells), ctx.torch and (", torch every " .. ctx.torch.every) or ""))
  if not ctx.yes and not T.job.resumable(ctx.name, ctx.params) and not io.ask("Start digging?", true) then return false end
  local ok, why = E.run(ctx)
  if ok == true then io.say("Tunnel finished.") return true end
  io.err("Stopped: " .. tostring(why))
  return false
end

return M
