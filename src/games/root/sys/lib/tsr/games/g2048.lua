-- SPDX-License-Identifier: AGPL-3.0-or-later
-- 2048. Slide with the arrow keys (or WASD); equal tiles merge. R restarts, Q quits.
local scores = require("tsr.games.scores")

local M = {}

local SIZE = 4

function M.emptyBoard()
  local b = {}
  for y = 1, SIZE do b[y] = {} for x = 1, SIZE do b[y][x] = 0 end end
  return b
end

--- Slide one line towards its start, merging equal neighbours once. Returns the new line and the points gained.
local function slideLine(line)
  local tiles = {}
  for _, v in ipairs(line) do if v ~= 0 then tiles[#tiles + 1] = v end end
  local out, gained, i = {}, 0, 1
  while i <= #tiles do
    if tiles[i + 1] == tiles[i] then
      out[#out + 1] = tiles[i] * 2
      gained = gained + tiles[i] * 2
      i = i + 2
    else
      out[#out + 1] = tiles[i]
      i = i + 1
    end
  end
  while #out < SIZE do out[#out + 1] = 0 end
  return out, gained
end

--- Move the board in `dir` ("left", "right", "up", "down"). Returns newBoard, pointsGained, moved (without touching the old board).
function M.move(board, dir)
  local nb = M.emptyBoard()
  local gained, moved = 0, false
  for i = 1, SIZE do
    local line = {}
    for j = 1, SIZE do
      if dir == "left" then line[j] = board[i][j]
      elseif dir == "right" then line[j] = board[i][SIZE - j + 1]
      elseif dir == "up" then line[j] = board[j][i]
      else line[j] = board[SIZE - j + 1][i] end
    end
    local out, g = slideLine(line)
    gained = gained + g
    for j = 1, SIZE do
      if dir == "left" then nb[i][j] = out[j]
      elseif dir == "right" then nb[i][SIZE - j + 1] = out[j]
      elseif dir == "up" then nb[j][i] = out[j]
      else nb[SIZE - j + 1][i] = out[j] end
    end
  end
  for y = 1, SIZE do for x = 1, SIZE do if nb[y][x] ~= board[y][x] then moved = true end end end
  return nb, gained, moved
end

--- Add a 2 (90%) or 4 (10%) on a random empty cell. rng(n) returns 1..n. Returns true when a tile was added.
function M.spawn(board, rng)
  rng = rng or function(n) return math.random(1, n) end
  local free = {}
  for y = 1, SIZE do for x = 1, SIZE do if board[y][x] == 0 then free[#free + 1] = { x, y } end end end
  if #free == 0 then return false end
  local cell = free[rng(#free)]
  board[cell[2]][cell[1]] = rng(10) == 1 and 4 or 2
  return true
end

function M.canMove(board)
  for _, dir in ipairs({ "left", "right", "up", "down" }) do
    local _, _, moved = M.move(board, dir)
    if moved then return true end
  end
  return false
end

function M.maxTile(board)
  local m = 0
  for y = 1, SIZE do for x = 1, SIZE do m = math.max(m, board[y][x]) end end
  return m
end

function M.new(rng)
  local g = { board = M.emptyBoard(), score = 0, rng = rng, over = false, won = false }
  M.spawn(g.board, rng)
  M.spawn(g.board, rng)
  return g
end

--- Play a move on a game. Returns true when the board changed.
function M.play(g, dir)
  if g.over then return false end
  local nb, gained, moved = M.move(g.board, dir)
  if not moved then return false end
  g.board = nb
  g.score = g.score + gained
  M.spawn(g.board, g.rng)
  if M.maxTile(g.board) >= 2048 then g.won = true end
  if not M.canMove(g.board) then g.over = true end
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- Screen
---------------------------------------------------------------------------------------------------------------------

local TILE_COLORS = { [0] = colors.gray, [2] = colors.lightGray, [4] = colors.yellow, [8] = colors.orange, [16] = colors.red,
                      [32] = colors.pink, [64] = colors.magenta, [128] = colors.lime, [256] = colors.green, [512] = colors.cyan,
                      [1024] = colors.lightBlue, [2048] = colors.white }

local KEYMAP = { [keys.up] = "up", [keys.w] = "up", [keys.down] = "down", [keys.s] = "down", [keys.left] = "left", [keys.a] = "left",
                 [keys.right] = "right", [keys.d] = "right" }

function M.draw(g, t)
  local w = t.getSize()
  t.setBackgroundColor(colors.black)
  t.clear()
  t.setTextColor(colors.yellow)
  t.setCursorPos(1, 1)
  t.write(("2048  score %d  best %d"):format(g.score, scores.best("2048")):sub(1, w))
  local colour = t.isColor()
  for y = 1, SIZE do
    for x = 1, SIZE do
      local v = g.board[y][x]
      t.setCursorPos((x - 1) * 7 + 1, (y - 1) * 2 + 3)
      t.setBackgroundColor(colour and (TILE_COLORS[v] or colors.white) or (v == 0 and colors.black or colors.gray))
      t.setTextColor(colors.black)
      if not colour then t.setTextColor(colors.white) end
      local label = v == 0 and "." or tostring(v)
      local pad = 6 - #label
      t.write(string.rep(" ", math.floor(pad / 2)) .. label .. string.rep(" ", pad - math.floor(pad / 2)))
    end
  end
  t.setBackgroundColor(colors.black)
  t.setTextColor(colors.white)
  t.setCursorPos(1, 12)
  if g.over then t.write("No moves left. R = again, Q = quit")
  elseif g.won then t.write("2048! Keep going or R / Q")
  else t.write("Arrows move  R restart  Q quit") end
end

function M.run(env)
  env = env or {}
  local t = env.term or term.current()
  local g = M.new(env.rng)
  local pull = env.pull or function() return os.pullEvent() end
  local count = 0
  M.draw(g, t)
  while true do
    local ev, a = pull()
    local quit = false
    if ev == "key" then
      if KEYMAP[a] then
        if M.play(g, KEYMAP[a]) then scores.submit("2048", g.score) end
      elseif a == keys.q then quit = true
      elseif a == keys.r then g = M.new(env.rng) end
    elseif ev == "char" then
      if a == "q" then quit = true elseif a == "r" then g = M.new(env.rng) end
    end
    M.draw(g, t)
    count = count + 1
    if quit or (env.maxEvents and count >= env.maxEvents) then break end
  end
  return g.score
end

function M.main() M.run() term.setCursorPos(1, 1) term.clear() return true end

return M
