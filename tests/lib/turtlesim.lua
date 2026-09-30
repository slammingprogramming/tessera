-- SPDX-License-Identifier: AGPL-3.0-or-later
-- A small deterministic turtle world for tests: a block grid, inventory, fuel, chests, crops and mobs behind the real
-- `turtle` API. Coordinates match tsr.turtle's frame: x east, y up, z south; dir 0 = north (-z).
--   local sim = Sim.new({ fuel = 1000 })
--   sim:fill(0, 0, -5, 0, 0, -1, "minecraft:stone")        -- blocks
--   sim:give("minecraft:torch", 16)
--   sim:install()   -- sets the global `turtle`;   sim:uninstall() restores it
local Sim = {}
Sim.__index = Sim

local DX = { [0] = 0, 1, 0, -1 }
local DZ = { [0] = -1, 0, 1, 0 }

local FUEL = { ["minecraft:coal"] = 80, ["minecraft:charcoal"] = 80, ["minecraft:lava_bucket"] = 1000, ["minecraft:stick"] = 5 }
local DROPS = { ["minecraft:stone"] = "minecraft:cobblestone", ["minecraft:grass_block"] = "minecraft:dirt",
                ["minecraft:leaves"] = false, ["minecraft:wheat"] = "minecraft:wheat" }
local UNBREAKABLE = { ["minecraft:bedrock"] = true }
local STACK = 64

local function key(x, y, z) return x .. "," .. y .. "," .. z end

function Sim.new(opts)
  opts = opts or {}
  local s = setmetatable({}, Sim)
  s.blocks = {}          -- key -> { name = , state = {} }
  s.chests = {}          -- key -> array of slots { name, count }
  s.mobs = {}            -- key -> count
  s.x, s.y, s.z, s.dir = opts.x or 0, opts.y or 0, opts.z or 0, opts.dir or 0
  s.fuel = opts.fuel or 1000
  s.fuelLimit = opts.fuelLimit or 20000
  s.unlimited = opts.unlimited or false
  s.inv = {}
  for i = 1, 16 do s.inv[i] = nil end
  s.selected = 1
  s.lost = {}            -- items dropped into the void (full inventory / no chest)
  s.moves = 0
  s.log = {}             -- optional action log for assertions
  s.turtle = s:makeApi()
  return s
end

---------------------------------------------------------------------------------------------------------------------
-- World editing helpers
---------------------------------------------------------------------------------------------------------------------

function Sim:set(x, y, z, name, state)
  if name == nil then self.blocks[key(x, y, z)] = nil else self.blocks[key(x, y, z)] = { name = name, state = state or {} } end
  if name == "minecraft:chest" then self.chests[key(x, y, z)] = self.chests[key(x, y, z)] or {} end
end

function Sim:get(x, y, z)
  local b = self.blocks[key(x, y, z)]
  return b and b.name
end

function Sim:block(x, y, z) return self.blocks[key(x, y, z)] end

function Sim:fill(x1, y1, z1, x2, y2, z2, name, state)
  for x = math.min(x1, x2), math.max(x1, x2) do
    for y = math.min(y1, y2), math.max(y1, y2) do
      for z = math.min(z1, z2), math.max(z1, z2) do self:set(x, y, z, name, state and { age = state.age }) end
    end
  end
end

--- Count blocks of `name` (or all non-air blocks when nil) inside a box.
function Sim:countBlocks(name, x1, y1, z1, x2, y2, z2)
  local n = 0
  for x = math.min(x1, x2), math.max(x1, x2) do
    for y = math.min(y1, y2), math.max(y1, y2) do
      for z = math.min(z1, z2), math.max(z1, z2) do
        local b = self.blocks[key(x, y, z)]
        if b and (name == nil or b.name == name) then n = n + 1 end
      end
    end
  end
  return n
end

function Sim:give(name, count, slot)
  slot = slot or self:firstSlotFor(name)
  if not slot then return false end
  local cur = self.inv[slot]
  if cur then cur.count = cur.count + count else self.inv[slot] = { name = name, count = count } end
  return true
end

function Sim:firstSlotFor(name)
  for i = 1, 16 do
    if self.inv[i] and self.inv[i].name == name and self.inv[i].count < STACK then return i end
  end
  for i = 1, 16 do if not self.inv[i] then return i end end
end

function Sim:itemCount(name)
  local n = 0
  for i = 1, 16 do if self.inv[i] and (name == nil or self.inv[i].name == name) then n = n + self.inv[i].count end end
  return n
end

function Sim:chestCount(x, y, z, name)
  local n = 0
  for _, it in ipairs(self.chests[key(x, y, z)] or {}) do if name == nil or it.name == name then n = n + it.count end end
  return n
end

--- A block that instantly regrows after being dug (cobblestone generator).
function Sim:regenerate(x, y, z, name)
  self.regen = self.regen or {}
  self.regen[key(x, y, z)] = name
  self:set(x, y, z, name)
end

function Sim:addMob(x, y, z, n) self.mobs[key(x, y, z)] = (self.mobs[key(x, y, z)] or 0) + (n or 1) end

function Sim:record(what) self.log[#self.log + 1] = what end

---------------------------------------------------------------------------------------------------------------------
-- Geometry
---------------------------------------------------------------------------------------------------------------------

function Sim:target(side)
  if side == "u" then return self.x, self.y + 1, self.z end
  if side == "d" then return self.x, self.y - 1, self.z end
  return self.x + DX[self.dir], self.y, self.z + DZ[self.dir]
end

function Sim:pickUp(name, count)
  local left = count
  while left > 0 do
    local slot = self:firstSlotFor(name)
    if not slot then self.lost[name] = (self.lost[name] or 0) + left return end
    local cur = self.inv[slot]
    local room = STACK - (cur and cur.count or 0)
    local put = math.min(room, left)
    if cur then cur.count = cur.count + put else self.inv[slot] = { name = name, count = put } end
    left = left - put
  end
end

---------------------------------------------------------------------------------------------------------------------
-- The turtle API
---------------------------------------------------------------------------------------------------------------------

function Sim:makeApi()
  local sim = self
  local T = {}

  local function move(dx, dy, dz)
    if not sim.unlimited and sim.fuel <= 0 then return false, "Out of fuel" end
    local nx, ny, nz = sim.x + dx, sim.y + dy, sim.z + dz
    if sim.blocks[key(nx, ny, nz)] then return false, "Movement obstructed" end
    if sim.mobs[key(nx, ny, nz)] then return false, "Movement obstructed" end
    sim.x, sim.y, sim.z = nx, ny, nz
    if not sim.unlimited then sim.fuel = sim.fuel - 1 end
    sim.moves = sim.moves + 1
    return true
  end

  function T.forward() return move(DX[sim.dir], 0, DZ[sim.dir]) end
  function T.back() return move(-DX[sim.dir], 0, -DZ[sim.dir]) end
  function T.up() return move(0, 1, 0) end
  function T.down() return move(0, -1, 0) end
  function T.turnLeft() sim.dir = (sim.dir + 3) % 4 return true end
  function T.turnRight() sim.dir = (sim.dir + 1) % 4 return true end

  local function detect(side) local x, y, z = sim:target(side) return sim.blocks[key(x, y, z)] ~= nil end
  function T.detect() return detect("f") end
  function T.detectUp() return detect("u") end
  function T.detectDown() return detect("d") end

  local function inspect(side)
    local x, y, z = sim:target(side)
    local b = sim.blocks[key(x, y, z)]
    if not b then return false, "No block to inspect" end
    return true, { name = b.name, state = b.state }
  end
  function T.inspect() return inspect("f") end
  function T.inspectUp() return inspect("u") end
  function T.inspectDown() return inspect("d") end

  local function dig(side)
    local x, y, z = sim:target(side)
    local b = sim.blocks[key(x, y, z)]
    if not b then return false, "Nothing to dig here" end
    if UNBREAKABLE[b.name] then return false, "Unbreakable block detected" end
    sim.blocks[key(x, y, z)] = nil
    sim:record("dig " .. b.name)
    local regen = sim.regen and sim.regen[key(x, y, z)]
    if regen then sim.blocks[key(x, y, z)] = { name = regen, state = {} } end
    local drop = DROPS[b.name]
    if drop == nil then drop = b.name end
    if drop then sim:pickUp(drop, 1) end
    if b.name == "minecraft:wheat" and (b.state.age or 0) >= 7 then sim:pickUp("minecraft:wheat_seeds", 1) end
    if b.name == "minecraft:chest" then sim.chests[key(x, y, z)] = nil end
    return true
  end
  function T.dig() return dig("f") end
  function T.digUp() return dig("u") end
  function T.digDown() return dig("d") end

  local function place(side)
    local slot = sim.inv[sim.selected]
    if not slot then return false, "No items to place" end
    local x, y, z = sim:target(side)
    if sim.blocks[key(x, y, z)] then return false, "Cannot place block here" end
    if sim.mobs[key(x, y, z)] then return false, "Cannot place block here" end
    local name = slot.name
    local placed = name
    local state
    if name == "minecraft:wheat_seeds" then
      if sim:get(x, y - 1, z) ~= "minecraft:farmland" then return false, "Cannot place item here" end
      placed, state = "minecraft:wheat", { age = 0 }
    elseif name:find("sapling$") then
      local below = sim:get(x, y - 1, z)
      if below ~= "minecraft:dirt" and below ~= "minecraft:grass_block" then return false, "Cannot place item here" end
    end
    sim:set(x, y, z, placed, state)
    slot.count = slot.count - 1
    if slot.count <= 0 then sim.inv[sim.selected] = nil end
    sim:record("place " .. placed)
    return true
  end
  function T.place() return place("f") end
  function T.placeUp() return place("u") end
  function T.placeDown() return place("d") end

  local function attack(side)
    local x, y, z = sim:target(side)
    local k = key(x, y, z)
    if (sim.mobs[k] or 0) > 0 then
      sim.mobs[k] = sim.mobs[k] - 1
      if sim.mobs[k] == 0 then sim.mobs[k] = nil end
      sim.kills = (sim.kills or 0) + 1
      return true
    end
    return false, "Nothing to attack here"
  end
  function T.attack() return attack("f") end
  function T.attackUp() return attack("u") end
  function T.attackDown() return attack("d") end

  local function compare(side)
    local slot = sim.inv[sim.selected]
    local x, y, z = sim:target(side)
    local b = sim.blocks[key(x, y, z)]
    if not slot or not b then return false end
    return slot.name == b.name
  end
  function T.compare() return compare("f") end
  function T.compareUp() return compare("u") end
  function T.compareDown() return compare("d") end

  function T.select(n)
    if type(n) ~= "number" or n < 1 or n > 16 then error("Slot number " .. tostring(n) .. " out of range", 2) end
    sim.selected = n
    return true
  end
  function T.getSelectedSlot() return sim.selected end
  function T.getItemCount(n) n = n or sim.selected return sim.inv[n] and sim.inv[n].count or 0 end
  function T.getItemSpace(n) n = n or sim.selected return STACK - (sim.inv[n] and sim.inv[n].count or 0) end
  function T.getItemDetail(n)
    n = n or sim.selected
    local it = sim.inv[n]
    if not it then return nil end
    return { name = it.name, count = it.count }
  end
  function T.transferTo(dest, count)
    local from, to = sim.inv[sim.selected], sim.inv[dest]
    if not from then return false end
    count = math.min(count or from.count, from.count)
    if to and to.name ~= from.name then return false end
    local room = STACK - (to and to.count or 0)
    count = math.min(count, room)
    if count <= 0 then return false end
    if to then to.count = to.count + count else sim.inv[dest] = { name = from.name, count = count } end
    from.count = from.count - count
    if from.count <= 0 then sim.inv[sim.selected] = nil end
    return true
  end

  local function chestAt(side)
    local x, y, z = sim:target(side)
    return sim.chests[key(x, y, z)]
  end

  local function drop(side, count)
    local slot = sim.inv[sim.selected]
    if not slot then return false, "No items to drop" end
    count = math.min(count or slot.count, slot.count)
    local chest = chestAt(side)
    if chest then
      local moved = false
      for _, it in ipairs(chest) do
        if it.name == slot.name and it.count < STACK and count > 0 then
          local put = math.min(STACK - it.count, count)
          it.count, count, slot.count, moved = it.count + put, count - put, slot.count - put, true
        end
      end
      while count > 0 and #chest < 27 do
        local put = math.min(STACK, count)
        chest[#chest + 1] = { name = slot.name, count = put }
        count, slot.count, moved = count - put, slot.count - put, true
      end
      if slot.count <= 0 then sim.inv[sim.selected] = nil end
      return moved
    end
    sim.lost[slot.name] = (sim.lost[slot.name] or 0) + count
    slot.count = slot.count - count
    if slot.count <= 0 then sim.inv[sim.selected] = nil end
    return true
  end
  function T.drop(n) return drop("f", n) end
  function T.dropUp(n) return drop("u", n) end
  function T.dropDown(n) return drop("d", n) end

  local function suck(side, count)
    local chest = chestAt(side)
    if not chest or #chest == 0 then return false, "No items to take" end
    local it = chest[1]
    local take = math.min(count or it.count, it.count)
    it.count = it.count - take
    if it.count <= 0 then table.remove(chest, 1) end
    sim:pickUp(it.name, take)
    return true
  end
  function T.suck(n) return suck("f", n) end
  function T.suckUp(n) return suck("u", n) end
  function T.suckDown(n) return suck("d", n) end

  function T.getFuelLevel() return sim.unlimited and "unlimited" or sim.fuel end
  function T.getFuelLimit() return sim.unlimited and "unlimited" or sim.fuelLimit end
  function T.refuel(count)
    local slot = sim.inv[sim.selected]
    if not slot then return false, "No items to combust" end
    local per = FUEL[slot.name]
    if not per then return false, "Items not combustible" end
    if count == 0 then return true end
    count = math.min(count or slot.count, slot.count)
    sim.fuel = math.min(sim.fuelLimit, sim.fuel + per * count)
    slot.count = slot.count - count
    if slot.count <= 0 then sim.inv[sim.selected] = nil end
    return true
  end
  function T.getEquippedLeft() return { name = "minecraft:diamond_pickaxe" } end
  function T.getEquippedRight() return nil end
  return T
end

function Sim:install()
  self._saved = rawget(_G, "turtle")
  _G.turtle = self.turtle
  return self
end

function Sim:uninstall()
  _G.turtle = self._saved
end

--- Where the sim believes the turtle is, in tsr.turtle's frame relative to (0,0,0) start.
function Sim:where() return self.x, self.y, self.z, self.dir end

return Sim
