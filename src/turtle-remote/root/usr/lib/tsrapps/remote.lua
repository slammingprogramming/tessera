-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Wireless turtle remote control (successor of the old "Turtles/wireless" idea).
--
--   on the turtle:               tlisten [--pair]        wait for commands (--pair sets the shared passphrase)
--   on a computer / pocket:      tcontrol [--pair] [id]  drive it with the keyboard
--                                tcontrol <id> <command> [argument]      one command, printed result
--
-- Security: every request carries HMAC-SHA256(passphrase, counter|command|argument) and the turtle only accepts a
-- counter higher than the last one it saw from that computer, so captured messages cannot be replayed. Only a fixed set
-- of turtle commands is understood — the remote can never run arbitrary code on the turtle. Replies are signed too.
local secure = require("tsrapps.secure")
local cli = require("tsrapps.cli")

local R = {}

R.PROTOCOL = "tsr.turtle"
R.KEY_FILE = "/etc/tsr/remote.key"
R.STATE_FILE = "/var/lib/tsr/turtle/remote.json"

---------------------------------------------------------------------------------------------------------------------
-- Signing
---------------------------------------------------------------------------------------------------------------------

R.sign = secure.sign
R.request = secure.request
R.verifyReply = secure.verifyReply

---------------------------------------------------------------------------------------------------------------------
-- The turtle side: whitelisted commands
---------------------------------------------------------------------------------------------------------------------

local function T() return require("tsr.turtle") end

local function status()
  local x, y, z, dir = T().pos()
  local slots = {}
  for slot = 1, 16 do
    local d = turtle.getItemDetail(slot)
    if d then slots[#slots + 1] = { slot = slot, name = d.name, count = d.count } end
  end
  local job = T().job.get()
  return { x = x, y = y, z = z, dir = dir, facing = T().NAMES[dir], fuel = turtle.getFuelLevel(),
           limit = turtle.getFuelLimit(), slots = slots, job = job and job.name or nil, id = os.getComputerID() }
end

local function simple(fn) return function() local ok, err = fn() return ok, ok and nil or err end end
local function side(name, what) return simple(function() return turtle[name]() end) end

--- command name -> function(arg) returning ok, data|error
R.COMMANDS = {
  forward = function() return T().forward() end,
  back = function() return T().back() end,
  up = function() return T().up() end,
  down = function() return T().down() end,
  left = function() return T().turnLeft() end,
  right = function() return T().turnRight() end,
  dig = side("dig"), digUp = side("digUp"), digDown = side("digDown"),
  place = side("place"), placeUp = side("placeUp"), placeDown = side("placeDown"),
  attack = side("attack"), attackUp = side("attackUp"), attackDown = side("attackDown"),
  suck = side("suck"), suckUp = side("suckUp"), suckDown = side("suckDown"),
  drop = side("drop"), dropUp = side("dropUp"), dropDown = side("dropDown"),
  select = function(arg)
    local n = tonumber(arg)
    if not n or n < 1 or n > 16 then return false, "slot must be 1-16" end
    return turtle.select(n)
  end,
  refuel = function(arg) return turtle.refuel(tonumber(arg)) end,
  status = function() return true, status() end,
  goto = function(arg)
    local x, y, z = tostring(arg):match("^(-?%d+),(-?%d+),(-?%d+)$")
    if not x then return false, "goto needs x,y,z" end
    return T().goto(tonumber(x), tonumber(y), tonumber(z), { dig = true })
  end,
  inspect = function()
    local ok, info = turtle.inspect()
    return true, ok and info.name or "nothing"
  end,
  stop = function() return true, "stopping" end,
}

--- Handle one request from `sender`. state = { last = { [sender] = counter } } (mutated). Returns reply table, stop?
function R.handle(secret, state, sender, msg)
  msg = secure.gate(secret, state, sender, msg)
  if not msg then return nil end
  local fn = R.COMMANDS[msg.cmd]
  local ok, data
  if not fn then
    ok, data = false, "unknown command"
  else
    local good, a, b = pcall(fn, msg.arg)
    if not good then ok, data = false, tostring(a)
    else ok, data = a and true or false, b end
  end
  return secure.reply(secret, msg, ok, data), msg.cmd == "stop"
end

local function loadState() return secure.loadState(R.STATE_FILE) end

--- The default network: rednet on the first modem found.
function R.rednetNet() return secure.rednetNet(R.PROTOCOL) end

--- Serve commands until a valid `stop` arrives (or net.receive raises). opts.rounds limits messages (tests).
function R.serve(secret, net, io, opts)
  opts = opts or {}
  local state = loadState()
  local handled = 0
  while true do
    local sender, msg = net.receive(opts.timeout or 5)
    if sender then
      local reply, stop = R.handle(secret, state, sender, msg)
      if reply then
        secure.saveState(R.STATE_FILE, state)
        net.send(sender, reply)
        handled = handled + 1
        if io and io.say and msg.cmd ~= "status" then io.say(("#%d: %s %s -> %s"):format(sender, msg.cmd, tostring(msg.arg or ""), tostring(reply.ok))) end
        if stop then return "stopped" end
      end
    end
    if opts.rounds and handled >= opts.rounds then return "rounds" end
    if opts.idle and not sender and opts.idle() then return "idle" end
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Pairing (shared passphrase)
---------------------------------------------------------------------------------------------------------------------

function R.loadKey() return secure.loadKey(R.KEY_FILE) end
function R.saveKey(secret) return secure.saveKey(R.KEY_FILE, secret) end

--- The passphrase: saved, or asked for (and saved) when missing or --pair is given.
function R.secret(io, force) return secure.secret(io, R.KEY_FILE, force) end

---------------------------------------------------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------------------------------------------------

R.SPEC = { pair = "bool" }

--- tlisten
function R.listen(args, io, net)
  io = io or cli.io()
  if not rawget(_G, "turtle") then io.err("tlisten only runs on a turtle.") return false end
  local pos, opts = cli.parse(args, R.SPEC)
  if not pos then io.err(opts) return false end
  local secret, err = R.secret(io, opts.pair)
  if not secret then io.err(err) return false end
  if not net then
    local why
    net, why = R.rednetNet()
    if not net then io.err(why) return false end
  end
  if net.host then net.host(os.getComputerLabel() or ("turtle-" .. os.getComputerID())) end
  io.say("Listening for the remote (computer " .. os.getComputerID() .. "). Send `stop` or press Ctrl+T to quit.")
  R.serve(secret, net, io)
  return true
end

--- One request/response round trip. Returns reply.data (or nil, error).
R.call = secure.call

R.KEYS = {
  w = "forward", s = "back", a = "left", d = "right", r = "up", f = "down",
  e = "dig", z = "digUp", x = "digDown", q = "place", c = "placeUp", v = "placeDown",
  g = "attack", t = "suck", y = "drop",
}

local function drawStatus(st, target)
  term.clear()
  term.setCursorPos(1, 1)
  print(("Turtle %s  %s"):format(tostring(target), st and st.job and ("job: " .. st.job) or ""))
  if st then
    print(("pos %d,%d,%d facing %s"):format(st.x, st.y, st.z, st.facing))
    print(("fuel %s/%s"):format(tostring(st.fuel), tostring(st.limit)))
    for _, s in ipairs(st.slots) do print((" %2d %3d %s"):format(s.slot, s.count, s.name:gsub("^minecraft:", ""))) end
  end
  local _, h = term.getSize()
  term.setCursorPos(1, h)
  term.write("wasd move/turn  r/f up/down  e/z/x dig  q/c/v place  g attack  h help  Q quit")
end

--- tcontrol
function R.control(args, io, net)
  io = io or cli.io()
  local pos, opts = cli.parse(args, R.SPEC)
  if not pos then io.err(opts) return false end
  local secret, err = R.secret(io, opts.pair)
  if not secret then io.err(err) return false end
  if not net then
    local why
    net, why = R.rednetNet()
    if not net then io.err(why) return false end
  end
  local target = tonumber(pos[1])
  if not target and net.lookup then target = net.lookup() end
  if not target then io.err("Which turtle? Give its computer id: tcontrol <id>") return false end
  local cmd = pos[2]
  if cmd then                                  -- one-shot mode
    local data, e = R.call(secret, net, target, cmd, pos[3])
    if data == nil then io.err(e) return false end
    io.say(type(data) == "table" and textutils.serialize(data) or tostring(data))
    return true
  end
  local st = R.call(secret, net, target, "status")
  while true do
    drawStatus(st, target)
    local ev, key = os.pullEvent("char")
    if key == "Q" then break end
    local cmdName = R.KEYS[key]
    if key == "h" then
      term.clear() term.setCursorPos(1, 1)
      print("w/s forward/back  a/d turn  r/f up/down\ne/z/x dig ahead/up/down  q/c/v place  g attack\nt suck  y drop  Q quit\nPress a key.")
      os.pullEvent("char")
    elseif cmdName then
      R.call(secret, net, target, cmdName)
      st = R.call(secret, net, target, "status") or st
    end
  end
  term.clear() term.setCursorPos(1, 1)
  return true
end

return R
