-- SPDX-License-Identifier: AGPL-3.0-or-later
-- guard: a turtle with a sword that attacks whatever comes near.
--   guard [--sides f,u,d] [--turn] [--pickup] [--rest S] [--rounds N]
-- Each round it attacks every chosen side (f = front, u = up, d = down). --turn rotates a quarter turn after each round
-- so all four directions get covered; --pickup collects the drops with suck. Runs until Ctrl+T (or N rounds).
local T = require("tsr.turtle")
local cli = require("tsrapps.cli")

local M = {}

M.SPEC = { sides = "string", turn = "bool", pickup = "bool", rest = "number", rounds = "number" }

--- Parse "f,u,d" into an ordered list of side letters, or nil + error.
function M.parseSides(text)
  local out = {}
  for s in (text or "f"):gmatch("[^,]+") do
    if not T.SIDES[s] then return nil, "unknown side '" .. s .. "' (use f, u or d)" end
    out[#out + 1] = s
  end
  return out
end

--- One round of attacks. Returns the number of hits.
function M.round(sides, pickup)
  local hits = 0
  for _, s in ipairs(sides) do
    while T.call(s, "attack") do hits = hits + 1 end
    if pickup then while T.call(s, "suck") do end end
  end
  return hits
end

function M.main(args, io)
  io = io or cli.io()
  if not rawget(_G, "turtle") then io.err("guard only runs on a turtle.") return false end
  local pos, opts = cli.parse(args, M.SPEC)
  if not pos then io.err(opts) return false end
  local sides, err = M.parseSides(opts.sides)
  if not sides then io.err(err) return false end
  io.say("Standing guard. Ctrl+T to stop.")
  local rounds, hits = 0, 0
  while true do
    hits = hits + M.round(sides, opts.pickup)
    rounds = rounds + 1
    if opts.turn then T.turnRight() end
    if opts.rounds and rounds >= opts.rounds then break end
    T.sleep(opts.rest or 0.5)
  end
  io.say(("Guard finished: %d hits in %d rounds."):format(hits, rounds))
  return true
end

return M
