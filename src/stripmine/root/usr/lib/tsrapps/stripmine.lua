-- SPDX-License-Identifier: AGPL-3.0-or-later
-- stripmine: a main shaft with side branches — the classic way to find ore.
--   stripmine [length] [--spacing N] [--branch N] [--dump back|down|up] [--junk] [--stay] [--yes]
-- Tunnels are 1 wide and 2 high. Every `spacing` blocks (default 3, so two blocks of rock stay between branches) a branch
-- of `branch` blocks (default 8) is dug to both sides. Put a chest behind the start and use --dump back to keep going.
local cli = require("tsrapps.cli")
local E = require("tsrapps.excavate")

local M = {}

M.SPEC = { spacing = "number", branch = "number", stay = "bool", dump = "string", junk = "bool", yes = "bool",
           _alias = { y = "yes" } }

--- The cell sequence for a strip mine. Every step moves to a neighbouring cell, so the turtle only ever walks through
--- tunnels it has already dug.
function M.plan(length, spacing, branch)
  local cells = {}
  local function add(f, r, u) cells[#cells + 1] = { f = f, r = r, u = u } end
  local u = 0
  for f = 1, length do
    add(f, 0, u)
    if f % spacing == 0 and branch > 0 then
      local other = 1 - u
      for j = 1, branch do add(f, j, u) end
      add(f, branch, other)
      for j = branch - 1, 0, -1 do add(f, j, other) end
      for j = 1, branch do add(f, -j, other) end
      add(f, -branch, u)
      for j = branch - 1, 0, -1 do add(f, -j, u) end
    else
      u = 1 - u
      add(f, 0, u)
    end
  end
  return cells
end

function M.build(args, io)
  local pos, opts = cli.parse(args, M.SPEC)
  if not pos then return nil, opts end
  local length = cli.count(pos[1] or io.prompt("Main shaft length", 30))
  local spacing = cli.count(opts.spacing, 3)
  local branch = opts.branch == 0 and 0 or cli.count(opts.branch, 8)
  if not (length and spacing and branch) then return nil, "length, spacing and branch must be whole numbers" end
  if opts.dump and not ({ back = 1, down = 1, up = 1 })[opts.dump] then return nil, "--dump must be back, down or up" end
  local cells = M.plan(length, spacing, branch)
  return {
    name = "stripmine",
    params = { length = length, spacing = spacing, branch = branch },
    cmd = { "stripmine", table.unpack(args) },
    cells = cells, io = io, dump = opts.dump, junk = opts.junk, stay = opts.stay, yes = opts.yes,
    summary = ("strip mine: %d-block shaft, branches of %d every %d blocks (%d steps)"):format(length, branch, spacing, #cells),
  }
end

function M.main(args, io)
  io = io or cli.io()
  if not rawget(_G, "turtle") then io.err("stripmine only runs on a turtle.") return false end
  local T = require("tsr.turtle")
  local ctx, err = M.build(args, io)
  if not ctx then io.err(err) return false end
  io.say(("%s, about %d fuel."):format(ctx.summary, E.fuelEstimate(ctx.cells)))
  if not ctx.yes and not T.job.resumable(ctx.name, ctx.params) and not io.ask("Start mining?", true) then return false end
  local ok, why = E.run(ctx)
  if ok == true then io.say("Strip mine finished.") return true end
  io.err("Stopped: " .. tostring(why))
  return false
end

return M
