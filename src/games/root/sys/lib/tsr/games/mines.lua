-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Minesweeper. Left click (or Space) opens a square, right click (or F) plants a flag, arrows move the cursor, Q quits.
-- The first square you open is always safe.
local scores = require("tsr.games.scores")

local M = {}

--- A new game. rng(n) returns 1..n.
function M.new(w, h, mines, rng)
  rng = rng or function(n) return math.random(1, n) end
  local g = { w = w, h = h, mines = math.min(mines, w * h - 9), rng = rng, state = "playing", started = false, opened = 0, flags = 0, cells = {} }
  for y = 1, h do
    g.cells[y] = {}
    for x = 1, w do g.cells[y][x] = { mine = false, open = false, flag = false, n = 0 } end
  end
  return g
end

local function neighbours(g, x, y)
  local out = {}
  for dy = -1, 1 do
    for dx = -1, 1 do
      if (dx ~= 0 or dy ~= 0) and x + dx >= 1 and x + dx <= g.w and y + dy >= 1 and y + dy <= g.h then out[#out + 1] = { x + dx, y + dy } end
    end
  end
  return out
end

--- Lay the mines, keeping the first opened square and its neighbours clear.
local function lay(g, fx, fy)
  local free = {}
  for y = 1, g.h do
    for x = 1, g.w do
      if math.abs(x - fx) > 1 or math.abs(y - fy) > 1 then free[#free + 1] = { x, y } end
    end
  end
  for _ = 1, g.mines do
    local i = g.rng(#free)
    local c = table.remove(free, i)
    g.cells[c[2]][c[1]].mine = true
  end
  for y = 1, g.h do
    for x = 1, g.w do
      local n = 0
      for _, nb in ipairs(neighbours(g, x, y)) do if g.cells[nb[2]][nb[1]].mine then n = n + 1 end end
      g.cells[y][x].n = n
    end
  end
  g.started = true
end

--- Open a square (flood-filling empty areas). Returns "ok", "boom", "won" or "ignored".
function M.open(g, x, y)
  if g.state ~= "playing" then return "ignored" end
  local c = g.cells[y] and g.cells[y][x]
  if not c or c.open or c.flag then return "ignored" end
  if not g.started then lay(g, x, y) end
  if c.mine then
    c.open = true
    g.state = "lost"
    return "boom"
  end
  local stack = { { x, y } }
  while #stack > 0 do
    local cur = table.remove(stack)
    local cell = g.cells[cur[2]][cur[1]]
    if not cell.open and not cell.flag then
      cell.open = true
      g.opened = g.opened + 1
      if cell.n == 0 then
        for _, nb in ipairs(neighbours(g, cur[1], cur[2])) do stack[#stack + 1] = nb end
      end
    end
  end
  if g.opened == g.w * g.h - g.mines then g.state = "won" return "won" end
  return "ok"
end

function M.toggleFlag(g, x, y)
  if g.state ~= "playing" then return false end
  local c = g.cells[y] and g.cells[y][x]
  if not c or c.open then return false end
  c.flag = not c.flag
  g.flags = g.flags + (c.flag and 1 or -1)
  return true
end

--- Open all neighbours of a satisfied number ("chording"). Returns the list of results.
function M.chord(g, x, y)
  local c = g.cells[y] and g.cells[y][x]
  if not c or not c.open or c.n == 0 then return {} end
  local flagged = 0
  for _, nb in ipairs(neighbours(g, x, y)) do if g.cells[nb[2]][nb[1]].flag then flagged = flagged + 1 end end
  local results = {}
  if flagged == c.n then
    for _, nb in ipairs(neighbours(g, x, y)) do results[#results + 1] = M.open(g, nb[1], nb[2]) end
  end
  return results
end

---------------------------------------------------------------------------------------------------------------------
-- Screen
---------------------------------------------------------------------------------------------------------------------

local NUM_COLORS = { colors.lightBlue, colors.lime, colors.red, colors.blue, colors.brown, colors.cyan, colors.black, colors.gray }

function M.draw(g, t, cursor)
  t.setBackgroundColor(colors.black)
  t.clear()
  t.setTextColor(colors.yellow)
  t.setCursorPos(1, 1)
  t.write(("MINES %d left  %s"):format(g.mines - g.flags, g.state == "won" and "YOU WIN" or (g.state == "lost" and "BOOM" or "")))
  for y = 1, g.h do
    for x = 1, g.w do
      local c = g.cells[y][x]
      t.setCursorPos(x, y + 1)
      local ch, fg, bg = " ", colors.white, colors.gray
      if c.open then
        bg = colors.lightGray
        if c.mine then ch, fg, bg = "*", colors.black, colors.red
        elseif c.n > 0 then ch, fg = tostring(c.n), NUM_COLORS[c.n] or colors.black
        else ch = " " end
      elseif c.flag then ch, fg = "F", colors.red
      elseif g.state == "lost" and c.mine then ch, fg, bg = "*", colors.black, colors.orange end
      if not t.isColor() then bg, fg = (c.open and colors.black or colors.gray), colors.white end
      if cursor and cursor.x == x and cursor.y == y then bg = colors.blue end
      t.setBackgroundColor(bg)
      t.setTextColor(fg)
      t.write(ch)
    end
  end
  t.setBackgroundColor(colors.black)
  t.setTextColor(colors.white)
end

function M.run(env)
  env = env or {}
  local t = env.term or term.current()
  local w, h = t.getSize()
  local g = M.new(math.min(30, w), math.min(16, h - 2), env.mines or 40, env.rng)
  if g.mines >= g.w * g.h - 9 then g.mines = math.max(1, math.floor(g.w * g.h / 6)) end
  local cursor = { x = 1, y = 1 }
  local pull = env.pull or function() return os.pullEvent() end
  local count, start = 0, os.clock()
  M.draw(g, t, cursor)
  while true do
    local ev, a, b, c = pull()
    if ev == "mouse_click" then
      local x, y = b, c - 1
      cursor.x, cursor.y = x, y
      if a == 1 then
        if g.cells[y] and g.cells[y][x] and g.cells[y][x].open then M.chord(g, x, y) else M.open(g, x, y) end
      elseif a == 2 then M.toggleFlag(g, x, y) end
    elseif ev == "key" then
      if a == keys.left then cursor.x = math.max(1, cursor.x - 1)
      elseif a == keys.right then cursor.x = math.min(g.w, cursor.x + 1)
      elseif a == keys.up then cursor.y = math.max(1, cursor.y - 1)
      elseif a == keys.down then cursor.y = math.min(g.h, cursor.y + 1)
      elseif a == keys.space then M.open(g, cursor.x, cursor.y)
      elseif a == keys.f then M.toggleFlag(g, cursor.x, cursor.y)
      elseif a == keys.q then break end
    elseif ev == "char" and a == "q" then
      break
    end
    M.draw(g, t, cursor)
    if g.state == "won" then scores.submit("mines", math.max(1, 1000 - math.floor(os.clock() - start))) end
    count = count + 1
    if (g.state ~= "playing" and env.stopWhenDone) or (env.maxEvents and count >= env.maxEvents) then break end
  end
  return g.state
end

function M.main() M.run() term.setCursorPos(1, 1) term.clear() return true end

return M
