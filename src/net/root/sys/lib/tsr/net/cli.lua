-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The `net` command and the netd daemon entry point.
--   net status | peers | lookup [service] | ping <name|id> | time <name|id>
--   net pair listen            wait for another computer (shows a one-time code)
--   net pair <id> <code>       pair with a computer that is listening
--   net unpair <name|id> | net name <hostname>
local net = require("tsr.net")

local M = {}

local function defaultIO()
  local io = {}
  local function color(c) if term.isColor() then term.setTextColor(c) end end
  function io.say(t) print(t) end
  function io.err(t) color(colors.red) print(t) color(colors.white) end
  function io.ok(t) color(colors.lime) print(t) color(colors.white) end
  return io
end

local function modems()
  local out = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      local wireless = false
      pcall(function() wireless = peripheral.call(name, "isWireless") end)
      out[#out + 1] = name .. (wireless and " (wireless)" or " (wired)")
    end
  end
  return out
end

--- Run a subcommand. `node` defaults to the shared node; tests pass their own.
function M.run(args, io, node)
  io = io or defaultIO()
  node = node or net.default()
  local cmd = args[1] or "status"

  if cmd == "status" then
    io.say("hostname: " .. node.hostname .. "   id: " .. node.id)
    local m = modems()
    io.say("modems:   " .. (#m > 0 and table.concat(m, ", ") or "none attached"))
    io.say("peers:    " .. #node:peers())
    local names = node:serviceNames()
    io.say("services: " .. (#names > 0 and table.concat(names, ", ") or "none"))
    return true

  elseif cmd == "peers" then
    local list = node:peers()
    if #list == 0 then io.say("Not paired with any computer. Use `net pair`.") return true end
    for _, p in ipairs(list) do io.say(("%-5d %s"):format(p.id, p.name)) end
    return true

  elseif cmd == "lookup" then
    local found = node:lookup(args[2], 1)
    if #found == 0 then io.say("Nobody answered.") return true end
    for _, f in ipairs(found) do
      io.say(("%-5d %-16s %s"):format(f.id, f.host, table.concat(f.services, ",")))
    end
    return true

  elseif cmd == "ping" or cmd == "time" then
    if not args[2] then io.err("usage: net " .. cmd .. " <name|id>") return false end
    local target = tonumber(args[2]) or args[2]
    if cmd == "ping" then
      local rtt, host = node:ping(target, 2)
      if not rtt then io.err(tostring(host)) return false end
      io.say(("%s: %.0f ms"):format(host or tostring(target), rtt * 1000))
    else
      local t, err = node:time(target, 2)
      if not t then io.err(tostring(err)) return false end
      io.say(("clock offset to %s: %+.0f ms (round trip %.0f ms)"):format(tostring(target), t.offset, t.rtt * 1000))
    end
    return true

  elseif cmd == "pair" then
    if args[2] == "listen" then
      local peer, err = node:pairListen({
        onCode = function(code)
          io.say("On the other computer run:  net pair " .. node.id .. " " .. code)
          io.say("Waiting (2 minutes)...")
        end,
      })
      if not peer then io.err("pairing failed: " .. tostring(err)) return false end
      io.ok("Paired with " .. tostring(peer.name) .. " (id " .. peer.id .. ").")
      return true
    end
    local id, code = tonumber(args[2]), args[3]
    if not id or not code then io.err("usage: net pair listen   |   net pair <id> <code>") return false end
    local peer, err = node:pairConnect(id, code, 8)
    if not peer then io.err("pairing failed: " .. tostring(err)) return false end
    io.ok("Paired with " .. tostring(peer.name) .. " (id " .. peer.id .. ").")
    return true

  elseif cmd == "unpair" then
    if not args[2] then io.err("usage: net unpair <name|id>") return false end
    local ok, err = node:removePeer(tonumber(args[2]) or args[2])
    if not ok then io.err(tostring(err)) return false end
    io.say("Removed. (The other computer still lists this one until you unpair there too.)")
    return true

  elseif cmd == "name" then
    local name = args[2]
    if not name or not name:match("^[%w_%-%.]+$") then io.err("usage: net name <hostname>  (letters, digits, - _ .)") return false end
    require("tsr.config").set("net.hostname", name, "system")
    node.hostname = name
    io.say("Hostname is now " .. name .. ".")
    return true
  end

  io.err("usage: net status | peers | lookup [service] | ping <x> | time <x> | pair listen | pair <id> <code> | unpair <x> | name <h>")
  return false
end

function M.main(args) return M.run(args) end

--- The netd service: wait for a modem, then answer the network until stopped.
function M.daemon()
  local node = net.default()
  local transport = node.transport
  if transport.available then
    while not transport.available() do os.pullEvent("peripheral") end
  end
  node:run()
end

return M
