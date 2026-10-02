-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Snake. Arrow keys or WASD steer, Q quits. Eat food to grow; walls and your own tail end the game.
local scores = require("tsr.games.scores")

local M = {}

local DIRS = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
local OPPOSITE = { up = "down", down = "up", left = "right", right = "left" }

--- A new game on a w x h board. rng(n) returns an integer from 1 to n (default math.random).
function M.new(w, h, rng)
  rng = rng or function(n) return math.random(1, n) end
  local g = { w = w, h = h, rng = rng, dir = "right", queued = nil, score = 0, alive = true, won = false }
  local cx, cy = math.floor(w / 2), math.floor(h / 2)
  g.body = { { cx, cy }, { cx - 1, cy }, { cx - 2, cy } }
  M.placeFood(g)
  return g
end

local function occupied(g, x, y)
  for _, seg in ipairs(g.body) do if seg[1] == x and seg[2] == y then return true end end
  return false
end

--- Put the food on a random free cell. Returns false when the board is full.
function M.placeFood(g)
  local free = {}
  for y = 1, g.h do for x = 1, g.w do if not occupied(g, x, y) then free[#free + 1] = { x, y } end end end
  if #free == 0 then g.food = nil return false end
  g.food = free[g.rng(#free)]
  return true
end

--- Change direction (a 180-degree turn is ignored). The change takes effect at the next step.
function M.turn(g, dir)
  if not DIRS[dir] then return end
  local current = g.queued or g.dir
  if dir ~= OPPOSITE[current] then g.queued = dir end
end

--- Advance one step. Returns "ate", "moved", "dead" or "won".
function M.step(g)
  if not g.alive then return "dead" end
  if g.queued then g.dir, g.queued = g.queued, nil end
  local d = DIRS[g.dir]
  local head = g.body[1]
  local nx, ny = head[1] + d[1], head[2] + d[2]
  if nx < 1 or ny < 1 or nx > g.w or ny > g.h then g.alive = false return "dead" end
  local eating = g.food and g.food[1] == nx and g.food[2] == ny
  -- the tail cell is free this step unless we are growing
  local tail = g.body[#g.body]
  for i, seg in ipairs(g.body) do
    if seg[1] == nx and seg[2] == ny and not (seg == tail and not eating) then g.alive = false return "dead" end
  end
  table.insert(g.body, 1, { nx, ny })
  if eating then
    g.score = g.score + 1
    if not M.placeFood(g) then g.won, g.alive = true, false return "won" end
    return "ate"
  end
  table.remove(g.body)
  return "moved"
end

--- Seconds between steps: faster as the score grows.
function M.delay(g) return math.max(0.06, 0.2 - g.score * 0.004) end

---------------------------------------------------------------------------------------------------------------------
-- Screen
---------------------------------------------------------------------------------------------------------------------

local KEYMAP = { [keys.up] = "up", [keys.w] = "up", [keys.down] = "down", [keys.s] = "down", [keys.left] = "left", [keys.a] = "left",
                 [keys.right] = "right", [keys.d] = "right" }

function M.draw(g, t)
  local w, h = t.getSize()
  t.setBackgroundColor(colors.black)
  t.clear()
  t.setTextColor(colors.yellow)
  t.setCursorPos(1, 1)
  t.write(("SNAKE  score %d  best %d"):format(g.score, scores.best("snake")):sub(1, w))
  local ox, oy = 1, 2
  t.setTextColor(colors.gray)
  for y = 0, g.h + 1 do
    t.setCursorPos(ox, oy + y)
    if y == 0 or y == g.h + 1 then t.write(string.rep("-", g.w + 2)) else t.write("|" .. string.rep(" ", g.w) .. "|") end
  end
  if g.food then
    t.setTextColor(colors.red)
    t.setCursorPos(ox + g.food[1], oy + g.food[2])
    t.write("*")
  end
  for i, seg in ipairs(g.body) do
    t.setTextColor(i == 1 and colors.lime or colors.green)
    t.setCursorPos(ox + seg[1], oy + seg[2])
    t.write(i == 1 and "O" or "o")
  end
  t.setTextColor(colors.white)
end

--- Play. env: term, rng, maxSteps (tests), events (function returning the next event, tests).
function M.run(env)
  env = env or {}
  local t = env.term or term.current()
  local w, h = t.getSize()
  local g = M.new(math.min(30, w - 2), math.min(16, h - 3), env.rng)
  local steps = 0
  M.draw(g, t)
  local timer = os.startTimer(M.delay(g))
  local pull = env.pull or function() return os.pullEvent() end
  while g.alive do
    local ev, a = pull()
    if ev == "key" then
      if KEYMAP[a] then M.turn(g, KEYMAP[a]) elseif a == keys.q then break end
    elseif ev == "char" and a == "q" then
      break
    elseif ev == "timer" and a == timer then
      M.step(g)
      steps = steps + 1
      M.draw(g, t)
      if env.maxSteps and steps >= env.maxSteps then break end
      timer = os.startTimer(M.delay(g))
    end
  end
  if not g.alive then
    local newBest = scores.submit("snake", g.score)
    t.setCursorPos(2, math.floor(h / 2))
    t.setTextColor(colors.white)
    t.setBackgroundColor(colors.red)
    t.write(g.won and " YOU WIN! " or (" GAME OVER - " .. g.score .. (newBest and " (new best!)" or "") .. " "))
    t.setBackgroundColor(colors.black)
    if not env.pull then sleep(1) end
  end
  return g.score
end

function M.main() M.run() term.setCursorPos(1, 1) term.clear() return true end

return M
