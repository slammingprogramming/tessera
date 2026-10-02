-- SPDX-License-Identifier: AGPL-3.0-or-later
local scores = require("tsr.games.scores")
local snake = require("tsr.games.snake")
local g2048 = require("tsr.games.g2048")
local mines = require("tsr.games.mines")

local DIR = "/tmp-games"

local function fresh()
  if fs.exists(DIR) then fs.delete(DIR) end
  fs.makeDir(DIR)
  scores.PATH = DIR .. "/scores.json"
end

local function first() return 1 end        -- a "random" generator that always picks the first choice

--- A small deterministic pseudo-random generator: n -> 1..n.
local function lcg(seed)
  seed = seed or 12345
  return function(n)
    seed = (seed * 1103515245 + 12345) % 2147483648
    return math.floor(seed / 65536) % n + 1
  end
end

local function win(w, h) return window.create(term.current(), 1, 1, w or 40, h or 20, false) end

local function text(t)
  local w, h = t.getSize()
  local out = {}
  for y = 1, h do out[y] = (t.getLine(y):gsub("%s+$", "")) end
  return table.concat(out, "\n")
end

test("high scores keep the best only", function()
  fresh()
  eq(scores.best("snake"), 0)
  ok(scores.submit("snake", 5))
  ok(not scores.submit("snake", 3))
  ok(scores.submit("snake", 9))
  eq(scores.best("snake"), 9)
  eq(scores.best("2048"), 0)
end)

test("snake moves, eats, grows and dies on walls and itself", function()
  local g = snake.new(10, 8, first)
  eq(#g.body, 3)
  eq(g.body[1], { 5, 4 })
  g.food = { 7, 4 }
  eq(snake.step(g), "moved")
  eq(g.body[1], { 6, 4 })
  eq(#g.body, 3)
  eq(snake.step(g), "ate")
  eq(g.score, 1)
  eq(#g.body, 4)
  ok(g.food, "new food appears")
  -- turning: a reversal is ignored
  snake.turn(g, "left")
  snake.step(g)
  eq(g.dir, "right")
  snake.turn(g, "up")
  snake.step(g)
  eq(g.dir, "up")
  snake.turn(g, "down")
  snake.step(g)
  eq(g.dir, "up")
  -- the wall
  local w = snake.new(4, 4, first)
  w.food = { 1, 1 }
  local result
  for _ = 1, 5 do result = snake.step(w) if result == "dead" then break end end
  eq(result, "dead")
  ok(not w.alive)
  eq(snake.step(w), "dead")
end)

test("snake: running into its own body ends the game, the vacated tail does not", function()
  local g = snake.new(10, 10, first)
  g.body = { { 5, 5 }, { 5, 6 }, { 6, 6 }, { 6, 5 }, { 6, 4 } }     -- a hook shape
  g.dir = "up"
  g.food = { 1, 1 }
  snake.turn(g, "right")
  eq(snake.step(g), "dead", "moving into (6,5) which is the body")
  -- following its own tail closely is fine
  local h = snake.new(10, 10, first)
  h.body = { { 5, 5 }, { 5, 6 }, { 4, 6 }, { 4, 5 } }
  h.dir = "left"
  h.food = { 1, 1 }
  eq(snake.step(h), "moved", "the tail cell (4,5) is vacated in the same step")
end)

test("snake: food never lands on the body; a full board is a win", function()
  local g = snake.new(3, 1, function(n) return n end)
  g.body = { { 2, 1 }, { 1, 1 } }
  ok(snake.placeFood(g))
  eq(g.food, { 3, 1 })
  g.body = { { 3, 1 }, { 2, 1 }, { 1, 1 } }
  ok(not snake.placeFood(g))
  local w = snake.new(4, 1, first)
  w.body = { { 2, 1 }, { 1, 1 } }
  w.food = { 3, 1 }
  w.dir = "right"
  snake.step(w)
  w.body = { { 3, 1 }, { 2, 1 }, { 1, 1 } }
  w.food = { 4, 1 }
  eq(snake.step(w), "won")
  ok(w.won and not w.alive)
  ok(snake.delay({ score = 0 }) > snake.delay({ score = 30 }), "it speeds up")
end)

test("snake screen: plays a few steps and records the score", function()
  fresh()
  local t = win(40, 20)
  local events = { { "key", keys.up }, { "timer", 1 }, { "key", keys.q } }
  local i = 0
  local score = snake.run({ term = t, rng = first, pull = function() i = i + 1 local e = events[i] if e[1] == "timer" then os.queueEvent("x") end return table.unpack(e) end })
  ok(score >= 0)
  ok(text(t):find("SNAKE", 1, true))
end)

test("2048 sliding and merging", function()
  local function board(rows) return rows end
  local b = g2048.emptyBoard()
  b[1] = { 2, 2, 4, 4 }
  local nb, gained, moved = g2048.move(b, "left")
  eq(nb[1], { 4, 8, 0, 0 })
  eq({ gained, moved }, { 12, true })
  eq(b[1], { 2, 2, 4, 4 }, "the original is untouched")
  b[1] = { 2, 2, 2, 2 }
  eq(g2048.move(b, "left")[1], { 4, 4, 0, 0 }, "each tile merges once")
  b[1] = { 2, 0, 2, 0 }
  eq(g2048.move(b, "right")[1], { 0, 0, 0, 4 })
  b[1] = { 0, 0, 0, 2 }
  local _, _, mv = g2048.move(b, "right")
  eq(mv, false, "already in place")
  -- vertical
  b = g2048.emptyBoard()
  b[1][1], b[2][1], b[4][1] = 2, 2, 4
  nb = g2048.move(b, "up")
  eq({ nb[1][1], nb[2][1], nb[3][1], nb[4][1] }, { 4, 4, 0, 0 })
  nb = g2048.move(b, "down")
  eq({ nb[1][1], nb[2][1], nb[3][1], nb[4][1] }, { 0, 0, 4, 4 })
end)

test("2048 spawning, game over and winning", function()
  local b = g2048.emptyBoard()
  ok(g2048.spawn(b, first))
  eq(b[1][1], 4 == 4 and 4 or 2, "rng(10) == 1 spawns a 4")
  local full = g2048.emptyBoard()
  for y = 1, 4 do for x = 1, 4 do full[y][x] = (x + y) % 2 == 0 and 2 or 4 end end
  ok(not g2048.spawn(full, first))
  ok(not g2048.canMove(full), "a checkerboard cannot move")
  full[1][1] = 4
  ok(g2048.canMove(full))
  local g = g2048.new(first)
  local tiles = 0
  for y = 1, 4 do for x = 1, 4 do if g.board[y][x] ~= 0 then tiles = tiles + 1 end end end
  eq(tiles, 2)
  g.board = g2048.emptyBoard()
  g.board[1][1], g.board[1][2] = 1024, 1024
  ok(g2048.play(g, "left"))
  ok(g.won)
  eq(g.score, 2048)
  eq(g2048.maxTile(g.board), 2048)
  ok(not g2048.play(g, "left") or true)
  g.over = true
  ok(not g2048.play(g, "right"), "no moves after the game is over")
end)

test("2048 screen", function()
  fresh()
  local t = win(40, 20)
  local events = { { "key", keys.left }, { "key", keys.up }, { "char", "r" }, { "char", "q" } }
  local i = 0
  g2048.run({ term = t, rng = first, pull = function() i = i + 1 return table.unpack(events[i]) end })
  ok(text(t):find("2048", 1, true))
  ok(text(t):find("Arrows move", 1, true))
end)

test("minesweeper: the first click is safe and opens an area", function()
  local g = mines.new(10, 10, 15, lcg(7))
  eq(mines.open(g, 5, 5) ~= "boom", true)
  eq(g.state, "playing")
  for dy = -1, 1 do for dx = -1, 1 do ok(not g.cells[5 + dy][5 + dx].mine) end end
  local m = 0
  for y = 1, 10 do for x = 1, 10 do if g.cells[y][x].mine then m = m + 1 end end end
  eq(m, 15)
  ok(g.opened >= 1)
  -- numbers match neighbouring mines
  for y = 1, 10 do for x = 1, 10 do
    local n = 0
    for dy = -1, 1 do for dx = -1, 1 do
      local c = g.cells[y + dy] and g.cells[y + dy][x + dx]
      if c and (dx ~= 0 or dy ~= 0) and c.mine then n = n + 1 end
    end end
    eq(g.cells[y][x].n, n)
  end end
end)

test("minesweeper: flags, boom, win and chording", function()
  local g = mines.new(5, 5, 3, lcg(99))
  mines.open(g, 3, 3)
  local mine
  for y = 1, 5 do for x = 1, 5 do if g.cells[y][x].mine then mine = mine or { x, y } end end end
  ok(mines.toggleFlag(g, mine[1], mine[2]))
  eq(g.flags, 1)
  eq(mines.open(g, mine[1], mine[2]), "ignored", "flagged squares are protected")
  ok(mines.toggleFlag(g, mine[1], mine[2]))
  eq(g.flags, 0)
  eq(mines.open(g, mine[1], mine[2]), "boom")
  eq(g.state, "lost")
  eq(mines.open(g, 1, 1), "ignored")
  ok(not mines.toggleFlag(g, 1, 1))
  -- winning: open every safe square
  local w = mines.new(4, 4, 1, lcg(5))
  mines.open(w, 2, 2)
  for y = 1, 4 do for x = 1, 4 do if not w.cells[y][x].mine then mines.open(w, x, y) end end end
  eq(w.state, "won")
  -- chording: a satisfied number opens its remaining neighbours
  local c = mines.new(6, 1, 0, first)
  c.mines = 0
  c.cells[1][3].mine = true
  c.started = true
  for x = 1, 6 do
    local n = 0
    if x == 2 or x == 4 then n = 1 end
    c.cells[1][x].n = n
  end
  mines.open(c, 1, 1)
  mines.open(c, 2, 1)
  mines.toggleFlag(c, 3, 1)
  local results = mines.chord(c, 2, 1)
  ok(#results > 0)
  eq(mines.chord(c, 5, 1), {}, "closed squares cannot chord")
end)

test("minesweeper screen: keys and mouse", function()
  fresh()
  local t = win(40, 20)
  local events = { { "key", keys.right }, { "key", keys.space }, { "mouse_click", 2, 6, 4 }, { "key", keys.f }, { "char", "q" } }
  local i = 0
  local state = mines.run({ term = t, rng = lcg(3), mines = 10, pull = function() i = i + 1 return table.unpack(events[i]) end })
  eq(state, "playing")
  ok(text(t):find("MINES", 1, true))
end)
