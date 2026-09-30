-- SPDX-License-Identifier: AGPL-3.0-or-later
-- rs: read and drive redstone from the shell.
--   rs list                          all sides: input and output levels
--   rs get <port>                    input level (and current output)
--   rs set <port> <on|off|0-15>
--   rs toggle <port>
--   rs pulse <port> [seconds]        on for a moment (default 0.5 s)
--   rs watch <port>                  print every change of the input until Ctrl+T
-- Ports: top, back:red (bundled colour), relay_0/left (redstone relay), see tsrapps.rsio.
local rsio = require("tsrapps.rsio")
local cli = require("tsrapps.cli")

local M = {}

local function describe(port)
  local out = port.getOutput()
  local inp = port.getInput()
  local function fmt(v) return type(v) == "boolean" and (v and "on" or "off") or tostring(v) end
  return ("in %s, out %s"):format(fmt(inp), fmt(out))
end

function M.main(args, io, env)
  io = io or cli.io()
  local cmd = args[1]
  if cmd == "list" then
    for _, side in ipairs(rsio.SIDES) do
      local p = rsio.open(side, env)
      io.say(("%-7s %s"):format(side, describe(p)))
    end
    return true
  end
  local spec = args[2]
  if not (cmd and spec) then
    io.say("usage: rs list | get <port> | set <port> <on|off|0-15> | toggle <port> | pulse <port> [seconds] | watch <port>")
    return false
  end
  local port, err = rsio.open(spec, env)
  if not port then io.err(err) return false end
  if cmd == "get" then
    io.say(describe(port))
  elseif cmd == "set" then
    local level = rsio.level(args[3] or "")
    if level == nil then io.err("set needs on, off or a level from 0 to 15") return false end
    port.set(level)
    io.say(spec .. " -> " .. tostring(args[3]))
  elseif cmd == "toggle" then
    io.say(spec .. " is now " .. (port.toggle() and "on" or "off"))
  elseif cmd == "pulse" then
    local secs = tonumber(args[3] or "0.5")
    if not secs or secs <= 0 then io.err("pulse needs a positive number of seconds") return false end
    port.pulse(secs)
    io.say(("pulsed %s for %s s"):format(spec, secs))
  elseif cmd == "watch" then
    local last
    io.say("Watching " .. spec .. " (Ctrl+T to stop)")
    local rounds = 0
    while true do
      local v = port.getInput()
      if v ~= last then
        io.say((os.date and os.date("%H:%M:%S") or "") .. "  " .. tostring(v))
        last = v
      end
      rounds = rounds + 1
      if env and env.maxRounds and rounds >= env.maxRounds then break end
      os.pullEvent("redstone")
    end
  else
    io.err("unknown command " .. cmd)
    return false
  end
  return true
end

return M
