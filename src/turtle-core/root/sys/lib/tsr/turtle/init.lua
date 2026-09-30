-- SPDX-License-Identifier: AGPL-3.0-or-later
-- tsr.turtle: the foundation every Tessera turtle program builds on.
--
--  * Position and heading are tracked in a coordinate frame that starts at (0,0,0) facing "north" (dir 0), unless
--    GPS calibration gives absolute coordinates. x grows east, y up, z south. dir: 0 north (-z), 1 east, 2 south, 3 west.
--  * The state is persisted with a write-ahead journal (two alternating slot files), so a turtle that is unloaded
--    mid-move still knows where it is after it restarts: an unfinished move is resolved by comparing the fuel level.
--  * dig-and-move handles gravel, entities and unbreakable blocks; goto() walks to coordinates.
--  * Frames give jobs coordinates relative to where they started (forward / right / up).
--  * Fuel and inventory helpers, and a small job store so long jobs can be resumed after a reboot.
local vfs = require("tsr.vfs")

local M = {}

M.dir = "/var/lib/tsr/turtle"
M.sleep = sleep          -- replaced in tests
M.DX = { [0] = 0, 1, 0, -1 }
M.DZ = { [0] = -1, 0, 1, 0 }
M.NAMES = { [0] = "north", "east", "south", "west" }

local state = { x = 0, y = 0, z = 0, dir = 0, seq = 0 }
local loaded = false

---------------------------------------------------------------------------------------------------------------------
-- Persistence (two alternating slot files; the newest valid one wins)
---------------------------------------------------------------------------------------------------------------------

local function slotPath(n) return M.dir .. "/pos." .. n end

local function save()
  state.seq = state.seq + 1
  if not fs.isDir(M.dir) then vfs.mkdirp(M.dir) end
  local h = fs.open(slotPath(state.seq % 2), "w")
  if h then
    h.write(textutils.serialize(state))
    h.close()
  end
end

local function readSlot(n)
  local h = fs.open(slotPath(n), "r")
  if not h then return nil end
  local raw = h.readAll()
  h.close()
  local t = raw and textutils.unserialize(raw)
  if type(t) == "table" and type(t.x) == "number" and type(t.dir) == "number" then return t end
end

local function fuelNow()
  local f = turtle.getFuelLevel()
  return type(f) == "number" and f or math.huge
end

local function applyMove(op)
  local d = state.dir
  if op == "f" then state.x, state.z = state.x + M.DX[d], state.z + M.DZ[d]
  elseif op == "b" then state.x, state.z = state.x - M.DX[d], state.z - M.DZ[d]
  elseif op == "u" then state.y = state.y + 1
  elseif op == "d" then state.y = state.y - 1
  elseif op == "r" then state.dir = (state.dir + 1) % 4
  elseif op == "l" then state.dir = (state.dir + 3) % 4 end
end

--- Load the saved state (once). An interrupted move is settled by the fuel level: fuel drops by one per move.
--- Turns cannot be checked, so an interrupted turn is assumed to have happened (see M.calibrate to re-sync).
function M.load()
  if loaded then return state end
  local a, b = readSlot(0), readSlot(1)
  local best = a
  if b and (not a or b.seq > a.seq) then best = b end
  if best then state = best end
  loaded = true
  local p = state.pending
  if p then
    local moved
    if p.op == "r" or p.op == "l" then moved = true
    elseif fuelNow() == math.huge or p.fuel == nil or p.fuel == math.huge then moved = false
    else moved = fuelNow() < p.fuel end
    if moved then applyMove(p.op) end
    state.pending = nil
    state.recovered = (state.recovered or 0) + 1
    save()
  end
  return state
end

--- Forget everything and start a new frame here: (x, y, z) facing dir (default 0,0,0 facing north).
function M.reset(x, y, z, dir)
  state = { x = x or 0, y = y or 0, z = z or 0, dir = dir or 0, seq = state.seq or 0 }
  loaded = true
  save()
end

--- Test hook: drop the in-memory copy so the next call reloads from disk.
function M.unloadForTest()
  loaded = false
  state = { x = 0, y = 0, z = 0, dir = 0, seq = 0 }
end

function M.pos()
  M.load()
  return state.x, state.y, state.z, state.dir
end

function M.state()
  M.load()
  return state
end

---------------------------------------------------------------------------------------------------------------------
-- Journaled movement
---------------------------------------------------------------------------------------------------------------------

local function journaled(op, fn)
  M.load()
  local fuel = fuelNow()
  state.pending = { op = op, fuel = fuel ~= math.huge and fuel or nil }
  save()
  local ok, err = fn()
  state.pending = nil
  if ok then applyMove(op) end
  save()
  return ok, err
end

function M.forward() return journaled("f", turtle.forward) end
function M.back() return journaled("b", turtle.back) end
function M.up() return journaled("u", turtle.up) end
function M.down() return journaled("d", turtle.down) end
function M.turnRight() return journaled("r", turtle.turnRight) end
function M.turnLeft() return journaled("l", turtle.turnLeft) end

--- Turn to face `dir` (0..3) by the shortest route.
function M.face(dir)
  M.load()
  dir = dir % 4
  local diff = (dir - state.dir) % 4
  if diff == 0 then return true end
  if diff == 1 then return M.turnRight() end
  if diff == 3 then return M.turnLeft() end
  local ok, err = M.turnRight()
  if not ok then return ok, err end
  return M.turnRight()
end

function M.turnAround()
  M.load()
  return M.face(state.dir + 2)
end

local SIDES = {
  f = { detect = "detect", dig = "dig", attack = "attack", move = "forward", inspect = "inspect", place = "place", drop = "drop", suck = "suck", compare = "compare" },
  u = { detect = "detectUp", dig = "digUp", attack = "attackUp", move = "up", inspect = "inspectUp", place = "placeUp", drop = "dropUp", suck = "suckUp", compare = "compareUp" },
  d = { detect = "detectDown", dig = "digDown", attack = "attackDown", move = "down", inspect = "inspectDown", place = "placeDown", drop = "dropDown", suck = "suckDown", compare = "compareDown" },
}
M.SIDES = SIDES

--- Call the turtle API function for a side: M.call("u", "dig") == turtle.digUp().
function M.call(side, what, ...)
  return turtle[SIDES[side][what]](...)
end

--- Clear the way on `side` ("f", "u" or "d") — digging (gravel keeps falling) and fighting whatever blocks — and move.
--- opts.tries (default 40). Returns true, or false + reason ("Out of fuel", "blocked by an unbreakable block", ...).
function M.digMove(side, opts)
  opts = opts or {}
  local S = SIDES[side]
  local move = ({ f = M.forward, u = M.up, d = M.down })[side]
  local lastErr
  for _ = 1, opts.tries or 40 do
    local digFailed
    if turtle[S.detect]() then
      if not turtle[S.dig]() then digFailed = "blocked by an unbreakable block" M.sleep(0.2) end
    end
    local ok, err = move()
    if ok then return true end
    lastErr = digFailed or err or lastErr
    if err and err:lower():find("fuel") then return false, "Out of fuel" end
    turtle[S.attack]()       -- an entity may be in the way
    M.sleep(0.2)
  end
  return false, lastErr or "blocked"
end

--- Move to (x, y, z) in the current frame. opts.dig (bool: dig through obstacles), opts.order (default "yxz").
--- Returns true, or false + reason.
function M.goto(x, y, z, opts)
  opts = opts or {}
  M.load()
  local function step(side)
    if opts.dig then return M.digMove(side, opts) end
    return ({ f = M.forward, u = M.up, d = M.down })[side]()
  end
  for axis in (opts.order or "yxz"):gmatch(".") do
    if axis == "y" then
      while state.y < y do local ok, err = step("u") if not ok then return false, err end end
      while state.y > y do local ok, err = step("d") if not ok then return false, err end end
    elseif axis == "x" then
      if state.x ~= x then
        M.face(x > state.x and 1 or 3)
        while state.x ~= x do local ok, err = step("f") if not ok then return false, err end end
      end
    elseif axis == "z" then
      if state.z ~= z then
        M.face(z > state.z and 2 or 0)
        while state.z ~= z do local ok, err = step("f") if not ok then return false, err end end
      end
    end
  end
  return true
end

--- Manhattan distance from the current position to a point (fuel estimate for goto).
function M.distanceTo(x, y, z)
  M.load()
  return math.abs(x - state.x) + math.abs(y - state.y) + math.abs(z - state.z)
end

---------------------------------------------------------------------------------------------------------------------
-- Frames: coordinates relative to where a job started
---------------------------------------------------------------------------------------------------------------------

--- A local coordinate system anchored at `origin` ({x,y,z,dir}, default: the turtle's current spot and heading):
--- f = blocks forward, r = blocks to the right, u = blocks up. Jobs plan in these terms, so they work whichever way
--- the turtle happens to face and can be resumed after a restart by saving `frame.origin`.
function M.frame(origin)
  M.load()
  local o = origin or { x = state.x, y = state.y, z = state.z, dir = state.dir }
  local F = { origin = o }
  local rd = (o.dir + 1) % 4
  local fx, fz, rx, rz = M.DX[o.dir], M.DZ[o.dir], M.DX[rd], M.DZ[rd]

  function F.toWorld(f, r, u) return o.x + f * fx + r * rx, o.y + u, o.z + f * fz + r * rz end

  function F.toLocal(x, y, z)
    local dx, dz = x - o.x, z - o.z
    return dx * fx + dz * fz, dx * rx + dz * rz, y - o.y
  end

  function F.here() return F.toLocal(M.pos()) end

  --- Face a direction relative to the frame: 0 forward, 1 right, 2 back, 3 left.
  function F.face(rel) return M.face(o.dir + rel) end

  function F.goto(f, r, u, opts)
    local x, y, z = F.toWorld(f, r, u)
    return M.goto(x, y, z, opts)
  end

  --- Move into the local cell (f, r, u), digging whatever is there. Adjacent cells cost one move; farther cells
  --- are reached with goto (digging).
  function F.step(f, r, u, opts)
    opts = opts or {}
    local cf, cr, cu = F.here()
    local df, dr, du = f - cf, r - cr, u - cu
    if df == 0 and dr == 0 and du == 0 then return true end
    if math.abs(df) + math.abs(dr) + math.abs(du) ~= 1 then
      local o2 = {}
      for k, v in pairs(opts) do o2[k] = v end
      o2.dig = true
      return F.goto(f, r, u, o2)
    end
    if du == 1 then return M.digMove("u", opts) end
    if du == -1 then return M.digMove("d", opts) end
    local rel = (df == 1 and 0) or (dr == 1 and 1) or (df == -1 and 2) or 3
    M.face(o.dir + rel)
    return M.digMove("f", opts)
  end

  return F
end

---------------------------------------------------------------------------------------------------------------------
-- GPS calibration
---------------------------------------------------------------------------------------------------------------------

--- Adopt absolute GPS coordinates and work out the heading by stepping once. Needs a modem and a GPS constellation.
--- Returns true, or false + reason. The turtle ends where it started.
function M.calibrate(timeout)
  if not (rawget(_G, "gps") and gps.locate) then return false, "no gps API" end
  local x1, y1, z1 = gps.locate(timeout or 2)
  if not x1 then return false, "no GPS signal" end
  M.load()
  -- find a free side to step to and back
  local moved, back
  for _ = 1, 4 do
    if not turtle.detect() then moved, back = M.forward, M.back break end
    M.turnRight()
  end
  if not moved then return false, "no free space to step into" end
  local ok, err = moved()
  if not ok then return false, err end
  local x2, _, z2 = gps.locate(timeout or 2)
  back()
  if not x2 then return false, "lost GPS signal" end
  local dx, dz = x2 - x1, z2 - z1
  local dir
  if dz < 0 then dir = 0 elseif dx > 0 then dir = 1 elseif dz > 0 then dir = 2 elseif dx < 0 then dir = 3 else return false, "no movement measured" end
  state.x, state.y, state.z, state.dir = x1, y1, z1, dir
  save()
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- Fuel
---------------------------------------------------------------------------------------------------------------------

function M.fuel() return fuelNow() end

--- A matcher from a spec: exact item name, "prefix*", a table of names, or a function(detail).
function M.matcher(spec)
  if type(spec) == "function" then return spec end
  if type(spec) == "table" then
    local set = {}
    for _, n in ipairs(spec) do set[n] = true end
    return function(d) return d and set[d.name] end
  end
  if spec:sub(-1) == "*" then
    local prefix = spec:sub(1, -2)
    return function(d) return d and d.name:sub(1, #prefix) == prefix end
  end
  return function(d) return d and d.name == spec end
end

--- Make sure at least `needed` fuel is available, burning fuel items from the inventory if necessary.
--- opts.keep = { [slot] = true } protects slots. Returns true, or false + reason.
function M.ensureFuel(needed, opts)
  opts = opts or {}
  if fuelNow() >= needed then return true end
  local limit = turtle.getFuelLimit()
  if type(limit) == "number" and needed > limit then needed = limit end
  local prev = turtle.getSelectedSlot()
  for slot = 1, 16 do
    if fuelNow() >= needed then break end
    if not (opts.keep and opts.keep[slot]) and turtle.getItemCount(slot) > 0 then
      turtle.select(slot)
      if turtle.refuel(0) then          -- refuel(0) only asks "is this fuel?"
        while turtle.getItemCount(slot) > 0 and fuelNow() < needed do
          if not turtle.refuel(1) then break end
        end
      end
    end
  end
  turtle.select(prev)
  if fuelNow() >= needed then return true end
  return false, ("need %d fuel, have %s"):format(needed, tostring(fuelNow()))
end

---------------------------------------------------------------------------------------------------------------------
-- Inventory
---------------------------------------------------------------------------------------------------------------------

--- First slot holding an item that matches `spec`, or nil.
function M.slotOf(spec)
  local m = M.matcher(spec)
  for slot = 1, 16 do
    if turtle.getItemCount(slot) > 0 and m(turtle.getItemDetail(slot)) then return slot end
  end
end

--- Select a slot holding `spec`. Returns the slot or nil.
function M.selectItem(spec)
  local slot = M.slotOf(spec)
  if slot then turtle.select(slot) end
  return slot
end

function M.countItems(spec)
  local m = M.matcher(spec)
  local n = 0
  for slot = 1, 16 do
    if turtle.getItemCount(slot) > 0 and m(turtle.getItemDetail(slot)) then n = n + turtle.getItemCount(slot) end
  end
  return n
end

function M.emptySlots()
  local n = 0
  for slot = 1, 16 do if turtle.getItemCount(slot) == 0 then n = n + 1 end end
  return n
end

--- Drop everything except slots in keepSlots (set) and items matching `keepSpec` into the inventory on `side`.
--- Returns the number of item stacks dropped.
function M.dump(side, keepSlots, keepSpec)
  local keepMatch = keepSpec and M.matcher(keepSpec)
  local prev = turtle.getSelectedSlot()
  local n = 0
  for slot = 1, 16 do
    if turtle.getItemCount(slot) > 0 and not (keepSlots and keepSlots[slot]) then
      local d = turtle.getItemDetail(slot)
      if not (keepMatch and keepMatch(d)) then
        turtle.select(slot)
        if M.call(side, "drop") then n = n + 1 end
      end
    end
  end
  turtle.select(prev)
  return n
end

---------------------------------------------------------------------------------------------------------------------
-- Jobs (resume after a reboot)
---------------------------------------------------------------------------------------------------------------------

local job = {}
M.job = job

function job.path() return M.dir .. "/job.json" end

--- Start recording a job: name, params (any JSON-able table), cmd = { program, args... } used to resume it.
function job.begin(name, params, cmd)
  local j = { name = name, params = params, cmd = cmd, progress = {}, started = os.epoch and os.epoch("utc") or 0 }
  vfs.writeJSON(job.path(), j)
  return j
end

function job.get() return vfs.readJSON(job.path()) end

--- Merge `progress` into the saved job (atomic write).
function job.update(progress)
  local j = job.get()
  if not j then return nil end
  for k, v in pairs(progress) do j.progress[k] = v end
  vfs.writeJSON(job.path(), j)
  return j
end

function job.finish()
  if fs.exists(job.path()) then fs.delete(job.path()) end
end

--- Stable text form of a value (keys sorted), so tables that went through JSON compare equal.
local function canon(v)
  if type(v) ~= "table" then return type(v) == "string" and string.format("%q", v) or tostring(v) end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. "=" .. canon(v[k]) end
  return "{" .. table.concat(parts, ",") .. "}"
end
M.canon = canon

--- Convenience for apps: returns the saved job when it is `name` and was started with the same params, so a re-run of
--- the same command continues instead of starting over.
function job.resumable(name, params)
  local j = job.get()
  if j and j.name == name and canon(j.params) == canon(params) then return j end
  return nil
end

return M
