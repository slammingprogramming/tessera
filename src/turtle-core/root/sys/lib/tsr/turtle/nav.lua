-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Turtle navigation with A* pathfinding and obstacle memory.
--
--   local nav = require("tsr.turtle.nav")
--   nav.goto(10, 0, -4)                 -- walk there around anything in the way, learning obstacles as it bumps into them
--   nav.goto(x, y, z, { dig = true })   -- when no way around exists, dig through
--
-- The turtle plans over its map: cells it knows to be blocked are avoided, unknown cells are assumed free (the plan is
-- optimistic and gets corrected as the turtle meets real blocks). Blocked cells it only *failed to enter* (a mob, falling
-- gravel) are forgotten after FORGET_SECONDS; cells it saw with `detect` are kept until they are seen open again.
-- Coordinates are tsr.turtle's: x east, y up, z south.
local T = require("tsr.turtle")
local vfs = require("tsr.vfs")

local N = {}

N.FORGET_SECONDS = 300
N.MAX_NODES = 30000
N.MAX_REPLANS = 40
N.MAX_CELLS = 5000          -- obstacle memory limit (oldest entries are dropped)

local blocked = {}          -- "x,y,z" -> { solid = bool, t = seconds, seq = n }
local seq = 0
local loadedPath = nil
local dirty = 0

local function now() return (os.epoch and os.epoch("utc") or os.clock() * 1000) / 1000 end
N.now = now

local function key(x, y, z) return x .. "," .. y .. "," .. z end

local function mapPath() return T.dir .. "/map.json" end

function N.load()
  if loadedPath == mapPath() then return end
  loadedPath = mapPath()
  blocked = {}
  local data = vfs.readJSON(mapPath())
  if type(data) == "table" then
    for _, c in ipairs(data.cells or {}) do
      seq = seq + 1
      blocked[key(c[1], c[2], c[3])] = { solid = c[4] == 1, t = c[5] or 0, seq = seq }
    end
  end
end

function N.save()
  local cells = {}
  for k, v in pairs(blocked) do
    local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
    cells[#cells + 1] = { tonumber(x), tonumber(y), tonumber(z), v.solid and 1 or 0, math.floor(v.t), v.seq }
  end
  table.sort(cells, function(a, b) return a[6] < b[6] end)
  for _, c in ipairs(cells) do c[6] = nil end
  vfs.writeJSON(mapPath(), { cells = cells })
  dirty = 0
end

--- Forget everything (tests, or after the world changed a lot).
function N.reset()
  blocked, seq, dirty = {}, 0, 0
  loadedPath = mapPath()
  if fs.exists(mapPath()) then fs.delete(mapPath()) end
end

function N.unloadForTest() blocked, loadedPath, seq, dirty = {}, nil, 0, 0 end

local function prune()
  local count = 0
  for _ in pairs(blocked) do count = count + 1 end
  if count <= N.MAX_CELLS then return end
  local list = {}
  for k, v in pairs(blocked) do list[#list + 1] = { k, v.seq } end
  table.sort(list, function(a, b) return a[2] < b[2] end)
  for i = 1, count - N.MAX_CELLS do blocked[list[i][1]] = nil end
end

--- Remember that a cell is blocked (solid = true: seen with detect; false: merely could not be entered).
function N.markBlocked(x, y, z, solid)
  N.load()
  seq = seq + 1
  blocked[key(x, y, z)] = { solid = solid and true or false, t = N.now(), seq = seq }
  dirty = dirty + 1
  prune()
end

function N.markFree(x, y, z)
  N.load()
  if blocked[key(x, y, z)] then
    blocked[key(x, y, z)] = nil
    dirty = dirty + 1
  end
end

function N.isBlocked(x, y, z)
  N.load()
  local b = blocked[key(x, y, z)]
  if not b then return false end
  if not b.solid and N.now() - b.t > N.FORGET_SECONDS then
    blocked[key(x, y, z)] = nil
    return false
  end
  return true
end

function N.blockedCount()
  N.load()
  local n = 0
  for _ in pairs(blocked) do n = n + 1 end
  return n
end

---------------------------------------------------------------------------------------------------------------------
-- A*
---------------------------------------------------------------------------------------------------------------------

local NEIGHBOURS = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 }, { 0, 1, 0 }, { 0, -1, 0 } }

-- binary min-heap of { f, node }
local Heap = {}
Heap.__index = Heap
local function newHeap() return setmetatable({ n = 0 }, Heap) end
function Heap:push(f, item)
  self.n = self.n + 1
  local i = self.n
  self[i] = { f, item }
  while i > 1 do
    local p = math.floor(i / 2)
    if self[p][1] <= self[i][1] then break end
    self[p], self[i] = self[i], self[p]
    i = p
  end
end
function Heap:pop()
  if self.n == 0 then return nil end
  local top = self[1]
  self[1] = self[self.n]
  self[self.n] = nil
  self.n = self.n - 1
  local i = 1
  while true do
    local l, r, s = i * 2, i * 2 + 1, i
    if l <= self.n and self[l][1] < self[s][1] then s = l end
    if r <= self.n and self[r][1] < self[s][1] then s = r end
    if s == i then break end
    self[s], self[i] = self[i], self[s]
    i = s
  end
  return top[2]
end

--- Shortest path from (x1,y1,z1) to (x2,y2,z2) over cells not known to be blocked. Returns an array of cells
--- ({x,y,z}, excluding the start, including the goal) or nil + reason. opts.margin: how far outside the box spanned by start
--- and goal the search may wander (default 12), opts.avoid(x,y,z) -> true to treat extra cells as blocked.
function N.plan(x1, y1, z1, x2, y2, z2, opts)
  opts = opts or {}
  N.load()
  if x1 == x2 and y1 == y2 and z1 == z2 then return {} end
  if N.isBlocked(x2, y2, z2) then return nil, "the destination is blocked" end
  local margin = opts.margin or 12
  local minx, maxx = math.min(x1, x2) - margin, math.max(x1, x2) + margin
  local miny, maxy = math.min(y1, y2) - margin, math.max(y1, y2) + margin
  local minz, maxz = math.min(z1, z2) - margin, math.max(z1, z2) + margin
  local avoid = opts.avoid

  local function h(x, y, z) return math.abs(x - x2) + math.abs(y - y2) + math.abs(z - z2) end
  local startKey = key(x1, y1, z1)
  local g = { [startKey] = 0 }
  local came, lastDir = {}, {}
  local heap = newHeap()
  heap:push(h(x1, y1, z1), { x1, y1, z1 })
  local closed = {}
  local expanded = 0
  while true do
    local cur = heap:pop()
    if not cur then return nil, "no path" end
    local cx, cy, cz = cur[1], cur[2], cur[3]
    local ck = key(cx, cy, cz)
    if not closed[ck] then
      closed[ck] = true
      if cx == x2 and cy == y2 and cz == z2 then
        local path = {}
        local k = ck
        while k ~= startKey do
          local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
          table.insert(path, 1, { tonumber(x), tonumber(y), tonumber(z) })
          k = came[k]
        end
        return path
      end
      expanded = expanded + 1
      if expanded > N.MAX_NODES then return nil, "search limit reached" end
      for di, d in ipairs(NEIGHBOURS) do
        local nx, ny, nz = cx + d[1], cy + d[2], cz + d[3]
        if nx >= minx and nx <= maxx and ny >= miny and ny <= maxy and nz >= minz and nz <= maxz
           and not N.isBlocked(nx, ny, nz) and not (avoid and avoid(nx, ny, nz)) then
          local nk = key(nx, ny, nz)
          if not closed[nk] then
            -- a small penalty for turning keeps paths straight (fewer turtle turns)
            local cost = g[ck] + 1 + ((lastDir[ck] and lastDir[ck] ~= di) and 0.01 or 0)
            if g[nk] == nil or cost < g[nk] then
              g[nk] = cost
              came[nk] = ck
              lastDir[nk] = di
              heap:push(cost + h(nx, ny, nz), { nx, ny, nz })
            end
          end
        end
      end
    end
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Walking
---------------------------------------------------------------------------------------------------------------------

--- Look ahead, up and down and remember solid blocks. Returns nothing.
function N.observe()
  N.load()
  local x, y, z, dir = T.pos()
  local fx, fz = x + T.DX[dir], z + T.DZ[dir]
  if turtle.detect() then N.markBlocked(fx, y, fz, true) else N.markFree(fx, y, fz) end
  if turtle.detectUp() then N.markBlocked(x, y + 1, z, true) else N.markFree(x, y + 1, z) end
  if turtle.detectDown() then N.markBlocked(x, y - 1, z, true) else N.markFree(x, y - 1, z) end
end

--- Face the neighbouring cell and check with detect whether it is solid. Remembers the answer. Returns true when it is open.
local function probe(cell)
  local x, y, z = T.pos()
  local solid
  if cell[2] > y then solid = turtle.detectUp()
  elseif cell[2] < y then solid = turtle.detectDown()
  else
    for d = 0, 3 do
      if x + T.DX[d] == cell[1] and z + T.DZ[d] == cell[3] then T.face(d) end
    end
    solid = turtle.detect()
  end
  if solid then N.markBlocked(cell[1], cell[2], cell[3], true) return false end
  N.markFree(cell[1], cell[2], cell[3])
  return true
end

--- Take one step to an adjacent cell. Returns true, or false + reason.
local function stepTo(nx, ny, nz, opts)
  local x, y, z = T.pos()
  if ny > y then return T.up() elseif ny < y then return T.down() end
  local dir
  for d = 0, 3 do
    if x + T.DX[d] == nx and z + T.DZ[d] == nz then dir = d end
  end
  if not dir then return false, "not adjacent" end
  T.face(dir)
  return T.forward()
end

--- Walk to (x, y, z). opts: dig (dig through when no way around is known), maxReplans, fuelMargin.
--- Returns true, or false + reason ("no path", "out of fuel", "too many obstacles", "blocked").
function N.goto(x, y, z, opts)
  opts = opts or {}
  N.load()
  local replans = 0
  local maxReplans = opts.maxReplans or N.MAX_REPLANS
  T.load()
  N.markFree(x, y, z)           -- if we are asked to go there, assume it can be entered
  while true do
    local cx, cy, cz = T.pos()
    if cx == x and cy == y and cz == z then
      if dirty > 0 then N.save() end
      return true
    end
    local path, why = N.plan(cx, cy, cz, x, y, z, opts)
    if not path then
      if opts.dig then
        local ok, err = T.goto(x, y, z, { dig = true })
        if dirty > 0 then N.save() end
        return ok, err
      end
      if dirty > 0 then N.save() end
      return false, why or "no path"
    end
    local failed = false
    for _, cell in ipairs(path) do
      if not probe(cell) then failed = true break end      -- a solid block: replan around it
      local ok, err = stepTo(cell[1], cell[2], cell[3], opts)
      if not ok then
        if err and err:lower():find("fuel") then
          if dirty > 0 then N.save() end
          return false, "out of fuel"
        end
        -- something is in the way that detect did not report as solid (a mob, falling gravel): try once more, then remember it
        for _ = 1, 2 do
          local px, py, pz, pd = T.pos()
          if cell[2] == py then turtle.attack() elseif cell[2] > py then turtle.attackUp() else turtle.attackDown() end
          T.sleep(0.3)
          ok = stepTo(cell[1], cell[2], cell[3], opts)
          if ok then break end
        end
        if not ok then
          N.markBlocked(cell[1], cell[2], cell[3], false)
          failed = true
          break
        end
      end
      N.markFree(cell[1], cell[2], cell[3])
    end
    if not failed then
      -- the loop ended at the goal (or the path was empty)
    else
      replans = replans + 1
      if replans > maxReplans then
        if opts.dig then
          -- exploring is taking too long: stop looking for a way round and dig
          local dug, derr = T.goto(x, y, z, { dig = true })
          if dirty > 0 then N.save() end
          return dug, derr
        end
        if dirty > 0 then N.save() end
        return false, "too many obstacles"
      end
    end
  end
end

return N
