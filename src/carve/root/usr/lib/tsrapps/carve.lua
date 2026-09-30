-- SPDX-License-Identifier: AGPL-3.0-or-later
-- carve: dig out a room. Successor of the old makeroom ("carveroom") script: same idea — length, width, height,
-- from the corner or centred on the turtle, with an offset — but crash-safe and resumable.
--   carve [length] [width] [height] [--center] [--offset f,r,u] [--dump back|down|up] [--junk] [--stay] [--yes]
-- Without --center the room extends forward and to the right (including the turtle's own column) and upward from the
-- turtle's level. --center puts the turtle in the middle of the floor. --offset shifts the whole room (forward, right, up).
local cli = require("tsrapps.cli")
local E = require("tsrapps.excavate")

local M = {}

M.SPEC = { center = "bool", offset = "string", stay = "bool", dump = "string", junk = "bool", yes = "bool",
           _alias = { y = "yes", c = "center" } }

local function parseOffset(s)
  if not s then return 0, 0, 0 end
  local f, r, u = s:match("^(-?%d+),(-?%d+),(-?%d+)$")
  if not f then return nil end
  return tonumber(f), tonumber(r), tonumber(u)
end

--- Region bounds for a room: returns f0, f1, r0, r1, u0, u1.
function M.bounds(length, width, height, center, of, or_, ou)
  local f0, r0 = 0, 0
  if center then f0, r0 = -math.floor((length - 1) / 2), -math.floor((width - 1) / 2) end
  return f0 + of, f0 + of + length - 1, r0 + or_, r0 + or_ + width - 1, ou, ou + height - 1
end

function M.build(args, io)
  local pos, opts = cli.parse(args, M.SPEC)
  if not pos then return nil, opts end
  local length = cli.count(pos[1] or io.prompt("Room length", 9))
  local width = cli.count(pos[2] or io.prompt("Room width", 9))
  local height = cli.count(pos[3] or io.prompt("Room height", 5))
  if not (length and width and height) then return nil, "length, width and height must be whole numbers of at least 1" end
  local of, or_, ou = parseOffset(opts.offset)
  if not of then return nil, "--offset needs three whole numbers: forward,right,up" end
  if opts.dump and not ({ back = 1, down = 1, up = 1 })[opts.dump] then return nil, "--dump must be back, down or up" end
  local f0, f1, r0, r1, u0, u1 = M.bounds(length, width, height, opts.center, of, or_, ou)
  return {
    name = "carve",
    params = { length = length, width = width, height = height, center = opts.center or false, offset = { of, or_, ou } },
    cmd = { "carve", table.unpack(args) },
    cells = E.plan({ f0 = f0, f1 = f1, r0 = r0, r1 = r1, u0 = u0, u1 = u1, order = "layers" }),
    io = io, dump = opts.dump, junk = opts.junk, stay = opts.stay, yes = opts.yes,
    summary = ("%dx%dx%d room: %d blocks"):format(length, width, height, length * width * height),
  }
end

function M.main(args, io)
  io = io or cli.io()
  if not rawget(_G, "turtle") then io.err("carve only runs on a turtle.") return false end
  local T = require("tsr.turtle")
  local ctx, err = M.build(args, io)
  if not ctx then io.err(err) return false end
  io.say(("%s, about %d fuel."):format(ctx.summary, E.fuelEstimate(ctx.cells)))
  if not ctx.yes and not T.job.resumable(ctx.name, ctx.params) and not io.ask("Start digging?", true) then return false end
  local ok, why = E.run(ctx)
  if ok == true then io.say("Room finished.") return true end
  io.err("Stopped: " .. tostring(why))
  return false
end

return M
