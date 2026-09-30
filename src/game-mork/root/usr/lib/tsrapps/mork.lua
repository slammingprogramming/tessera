-- SPDX-License-Identifier: AGPL-3.0-or-later
-- MORK: a small text adventure in the tradition of the classic dungeon crawls. You wake in a cell under an old mine
-- and must find your way to the surface — ideally with the treasure. Type commands like "take torch", "go north",
-- "north", "open door", "read book", "attack zombie with sword", "inventory", "look", "score", "save", "load", "quit".
-- The engine is data-driven (see WORLD below); M.exec(state, line) is a pure function of the game state, which is how
-- the tests play the whole game.
local vfs = require("tsr.vfs")
local cli = require("tsrapps.cli")

local M = {}

M.SAVE = "/home/mork.sav"

---------------------------------------------------------------------------------------------------------------------
-- The world
---------------------------------------------------------------------------------------------------------------------

M.WORLD = {
  start = "cell",
  rooms = {
    cell = {
      name = "Stone Cell",
      text = "You are in a damp stone cell that smells of old cobblestone. A worn wooden bench stands against one wall. A rusty door leads north.",
      exits = { north = "corridor" },
    },
    corridor = {
      name = "Torchless Corridor",
      text = "A long corridor cuts through the rock. Cold draughts come from an opening to the west; a door stands open to the east; the corridor continues north to a great hall. The cell is south.",
      exits = { south = "cell", north = "hall", east = "armory", west = "cave" },
    },
    armory = {
      name = "Old Armory",
      text = "Empty weapon racks line the walls. A few scraps of equipment are left. The corridor is back west.",
      exits = { west = "corridor" },
    },
    cave = {
      name = "Echoing Cave",
      text = "A natural cave, its ceiling dripping with water. Something small glints on the floor. The corridor is back east.",
      exits = { east = "corridor" },
      dark = true,
    },
    hall = {
      name = "Great Hall",
      text = "A vast hall with a vaulted ceiling. Stairs climb north into daylight. An iron door is set in the east wall, and a library opens to the west. The corridor is south.",
      exits = { south = "corridor", west = "library", north = { to = "surface", when = "zombie_gone", blocked = "The zombie blocks the stairs, groaning hungrily." }, east = { to = "vault", when = "door_open", blocked = "The iron door is locked tight." } },
    },
    library = {
      name = "Dusty Library",
      text = "Shelves of rotting books surround a reading desk. The hall is back east.",
      exits = { east = "hall" },
    },
    vault = {
      name = "Vault",
      text = "A small round vault, its walls scored by pickaxes long ago. The hall is back west.",
      exits = { west = "hall" },
    },
    surface = {
      name = "The Surface",
      text = "Sunlight! You climb out of the mine into a green meadow.",
      exits = {},
      final = true,
    },
  },
  items = {
    bench = { name = "wooden bench", words = { "bench" }, room = "cell", scenery = true, text = "A plain bench. A bowl on it holds a loaf of bread." },
    bread = { name = "loaf of bread", words = { "bread", "loaf" }, room = "cell", text = "Stale, but it will do. Someone hungry might like it.", eat = "You eat the bread. It is dry but filling. (Something else might have wanted it.)" },
    torch = { name = "torch", words = { "torch" }, room = "armory", text = "A wall torch that still burns brightly.", light = true, points = 10 },
    sword = { name = "iron sword", words = { "sword" }, room = "armory", text = "A chipped but serviceable iron sword.", weapon = true },
    key = { name = "iron key", words = { "key" }, room = "cave", hidden = true, text = "A heavy iron key.", points = 15 },
    book = { name = "dusty book", words = { "book" }, room = "library", text = "The cover reads: 'Notes of a Miner'.", read = "'The zombie in the hall is always hungry: bread will calm it, steel will end it. The iron door opens to the key that lies where light is shy.'" },
    zombie = { name = "zombie", words = { "zombie" }, room = "hall", scenery = true, text = "A shambling zombie blocks the stairs, sniffing the air.", alive = true },
    door = { name = "iron door", words = { "door" }, room = "hall", scenery = true, text = "A heavy iron door with a big keyhole." },
    diamond = { name = "diamond", words = { "diamond", "gem" }, room = "vault", text = "A flawless diamond, cold and bright.", points = 25 },
  },
  maxScore = 100,
}

local DIRS = { n = "north", s = "south", e = "east", w = "west", u = "up", d = "down",
               north = "north", south = "south", east = "east", west = "west", up = "up", down = "down" }

---------------------------------------------------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------------------------------------------------

function M.new()
  local st = { room = M.WORLD.start, inv = {}, where = {}, flags = {}, moves = 0, score = 0, status = "playing", scored = {}, darkWarn = false }
  for id, it in pairs(M.WORLD.items) do st.where[id] = it.room end
  return st
end

local function hasLight(st)
  for id in pairs(st.inv) do if M.WORLD.items[id].light then return true end end
  return false
end

local function points(st, key, n)
  if n and n > 0 and not st.scored[key] then
    st.scored[key] = true
    st.score = st.score + n
  end
end

local function visibleItems(st)
  local out = {}
  local room = M.WORLD.rooms[st.room]
  for id, where in pairs(st.where) do
    local it = M.WORLD.items[id]
    if where == st.room and not (it.hidden and not (room.dark and hasLight(st)) and not st.flags["found_" .. id]) then
      out[#out + 1] = id
    end
  end
  table.sort(out)
  return out
end

local function findItem(st, word, includeInv)
  if not word or word == "" then return nil end
  local candidates = visibleItems(st)
  if includeInv then for id in pairs(st.inv) do candidates[#candidates + 1] = id end end
  for _, id in ipairs(candidates) do
    for _, w in ipairs(M.WORLD.items[id].words) do
      if w == word then return id end
    end
  end
  return nil
end

function M.describe(st, brief)
  local room = M.WORLD.rooms[st.room]
  local out = {}
  if room.dark and not hasLight(st) then
    return { "Pitch Black", "It is pitch black. You hear dripping water and something hissing nearby. A way out lies east." }
  end
  out[#out + 1] = room.name
  if not brief then out[#out + 1] = room.text end
  for _, id in ipairs(visibleItems(st)) do
    local it = M.WORLD.items[id]
    if id == "zombie" and st.flags.zombie_gone then
      -- gone
    elseif not it.scenery or id == "zombie" then
      out[#out + 1] = (id == "zombie") and "A zombie shambles here." or ("There is a " .. it.name .. " here.")
    end
  end
  return out
end

local function die(st, why)
  st.status = "dead"
  return { why, "*** You have died. ***", ("Your score: %d of %d in %d moves."):format(st.score, M.WORLD.maxScore, st.moves) }
end

local function win(st)
  st.status = "won"
  local extra = st.inv.diamond and "You escaped with the treasure!" or "You escaped, but the treasure is still below..."
  points(st, "escape", 10)
  return { M.WORLD.rooms.surface.text, extra, ("*** Game over. Score: %d of %d in %d moves. ***"):format(st.score, M.WORLD.maxScore, st.moves) }
end

---------------------------------------------------------------------------------------------------------------------
-- Verbs
---------------------------------------------------------------------------------------------------------------------

local ARTICLES = { the = true, a = true, an = true, to = true, at = true, ["at"] = true }

local function words(line)
  local out = {}
  for w in line:lower():gmatch("[%a']+") do
    if not ARTICLES[w] then out[#out + 1] = w end
  end
  return out
end

local function go(st, dir)
  local room = M.WORLD.rooms[st.room]
  local exit = room.exits[dir]
  if not exit then return { "You can't go that way." } end
  if type(exit) == "table" then
    if exit.when and not st.flags[exit.when] then return { exit.blocked or "Something blocks the way." } end
    exit = exit.to
  end
  st.room = exit
  local target = M.WORLD.rooms[exit]
  if target.final then return win(st) end
  if target.dark and not hasLight(st) then
    return { "You feel your way into the dark...", table.unpack(M.describe(st)) }
  end
  return M.describe(st)
end

local function take(st, word)
  if word == "all" then
    local got = {}
    for _, id in ipairs(visibleItems(st)) do
      if not M.WORLD.items[id].scenery then got[#got + 1] = id end
    end
    if #got == 0 then return { "There is nothing here to take." } end
    local out = {}
    for _, id in ipairs(got) do
      local r = take(st, M.WORLD.items[id].words[1])
      for _, l in ipairs(r) do out[#out + 1] = l end
    end
    return out
  end
  local id = findItem(st, word, false)
  if not id then return { "You see no such thing here." } end
  local it = M.WORLD.items[id]
  if it.scenery then return { "You can't take the " .. it.name .. "." } end
  st.where[id], st.inv[id] = nil, true
  points(st, "take_" .. id, it.points)
  return { "Taken: " .. it.name .. "." }
end

local function handle(st, w)
  local verb, a, b = w[1], w[2], w[3]
  local room = M.WORLD.rooms[st.room]
  local dark = room.dark and not hasLight(st)

  if DIRS[verb] and #w == 1 then return go(st, DIRS[verb]) end
  if (verb == "go" or verb == "walk" or verb == "run") and DIRS[a or ""] then return go(st, DIRS[a]) end
  if verb == "climb" and (a == "up" or a == "stairs") then return go(st, "north") end

  if verb == "look" or verb == "l" then
    if a then
      local id = findItem(st, a, true)
      if not id or dark then return { "You see nothing special." } end
      return { M.WORLD.items[id].text }
    end
    return M.describe(st)
  end
  if verb == "examine" or verb == "x" or verb == "inspect" then
    local id = findItem(st, a, true)
    if not id or dark then return { "You see nothing special." } end
    return { M.WORLD.items[id].text }
  end
  if verb == "inventory" or verb == "i" or verb == "inv" then
    local names = {}
    for id in pairs(st.inv) do names[#names + 1] = M.WORLD.items[id].name end
    table.sort(names)
    if #names == 0 then return { "You are carrying nothing." } end
    return { "You are carrying: " .. table.concat(names, ", ") .. "." }
  end
  if verb == "score" then
    return { ("Score: %d of %d in %d moves."):format(st.score, M.WORLD.maxScore, st.moves) }
  end
  if verb == "help" or verb == "?" then
    return { "Commands: look, go <direction> (or n/s/e/w), take/drop <thing>, inventory, examine <thing>, read <thing>, open door,",
             "attack <thing> with <thing>, give <thing> to <thing>, eat, score, save, load, quit." }
  end
  if verb == "quit" or verb == "q" then st.status = "quit" return { ("You give up. Score: %d of %d."):format(st.score, M.WORLD.maxScore) } end

  -- everything below needs light in a dark room
  if dark then
    if st.darkWarn then return die(st, "Blindly, you step on something that hisses. A creeper explodes!") end
    st.darkWarn = true
    return { "It is too dark to do that. Something hisses nearby; you had better leave (or find some light)." }
  end

  if verb == "take" or verb == "get" or verb == "grab" or verb == "pick" then
    if verb == "pick" and a == "up" then a = b end
    return take(st, a)
  end
  if verb == "drop" then
    local id = findItem(st, a, true)
    if not (id and st.inv[id]) then return { "You are not carrying that." } end
    st.inv[id], st.where[id] = nil, st.room
    return { "Dropped." }
  end
  if verb == "read" then
    local id = findItem(st, a, true)
    if not id then return { "You see nothing to read." } end
    local it = M.WORLD.items[id]
    return { it.read or "There is nothing to read on it." }
  end
  if verb == "eat" then
    local id = findItem(st, a, true)
    if id ~= "bread" or not st.inv.bread then return { "You can't eat that." } end
    st.inv.bread = nil
    return { M.WORLD.items.bread.eat }
  end
  if verb == "open" or verb == "unlock" then
    local id = findItem(st, a, true)
    if id ~= "door" then return { "You can't open that." } end
    if st.flags.door_open then return { "It is already open." } end
    if not st.inv.key then return { "The door is locked. You need a key." } end
    st.flags.door_open = true
    points(st, "door", 20)
    return { "The iron key turns with a heavy clunk and the door swings open, revealing a vault to the east." }
  end
  if verb == "give" or verb == "feed" then
    local id = findItem(st, a, true)
    local target = findItem(st, b, true)
    if id ~= "bread" or not st.inv.bread then return { "You have nothing suitable to give." } end
    if target ~= "zombie" or st.flags.zombie_gone then return { "There is nobody to give it to." } end
    st.inv.bread = nil
    st.flags.zombie_gone = true
    st.where.zombie = nil
    points(st, "zombie", 10)
    return { "The zombie snatches the bread, gnaws it happily, and shambles off into the shadows. The stairs are free." }
  end
  if verb == "attack" or verb == "kill" or verb == "hit" or verb == "fight" then
    local target = findItem(st, a, true)
    if target ~= "zombie" or st.flags.zombie_gone then return { "There is nothing to attack." } end
    if not st.inv.sword then return { "With your bare hands? The zombie shrugs off your blows and swipes at you. Better find a weapon." } end
    st.flags.zombie_gone = true
    st.where.zombie = nil
    points(st, "zombie", 20)
    return { "You strike with the iron sword. The zombie collapses in a heap. The stairs are free." }
  end
  return { "I don't understand that." }
end

--- Execute one command line. Returns array of output lines; st.status becomes "won", "dead" or "quit" when it ends.
function M.exec(st, line)
  local w = words(line)
  if #w == 0 then return { "Say something." } end
  st.moves = st.moves + 1
  local out = handle(st, w)
  if st.status == "playing" and M.WORLD.rooms[st.room].dark == nil then st.darkWarn = false end
  return out
end

---------------------------------------------------------------------------------------------------------------------
-- Saving and the game loop
---------------------------------------------------------------------------------------------------------------------

function M.save(st, path) return vfs.writeTable(path or M.SAVE, st) end

function M.load(path)
  local st = vfs.readTable(path or M.SAVE)
  if type(st) ~= "table" or not st.room or not M.WORLD.rooms[st.room] then return nil end
  return st
end

function M.main(args, io, env)
  io = io or cli.io()
  local st = M.new()
  io.say("MORK - a tiny dungeon adventure. Type 'help' for commands.")
  io.say("")
  for _, l in ipairs(M.describe(st)) do io.say(l) end
  local readLine = (env and env.readLine) or function() write("> ") return read() end
  while st.status == "playing" do
    local line = readLine()
    if line == nil then break end
    local cmd = line:lower():match("^%s*(%a+)")
    if cmd == "save" then
      M.save(st, env and env.savePath)
      io.say("Saved.")
    elseif cmd == "load" then
      local loaded = M.load(env and env.savePath)
      if loaded then st = loaded for _, l in ipairs(M.describe(st)) do io.say(l) end else io.say("No saved game.") end
    else
      for _, l in ipairs(M.exec(st, line)) do io.say(l) end
    end
  end
  return st.status == "won"
end

return M
