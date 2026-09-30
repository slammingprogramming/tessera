-- SPDX-License-Identifier: AGPL-3.0-or-later
-- rsio: one way to talk to redstone, whatever provides it. A "port" names a signal:
--     top                  a side of this computer, analog 0-15 (on/off are 15/0)
--     back:red             one colour of a bundled cable on that side
--     relay_0/left         a side of a redstone relay peripheral ("redstone_relay_0" also accepted)
--     relay_0/left:blue    bundled colour on a relay side
-- Ports work the same for the app that uses them (rs, redseq, cannon, door controllers, chunk loaders ...), which is
-- Tessera's "redstone as the universal fallback" for machines that have no CC integration.
local R = {}

R.SIDES = { "top", "bottom", "left", "right", "front", "back" }

local function isSide(s)
  for _, v in ipairs(R.SIDES) do if v == s then return true end end
  return false
end

--- Parse a port spec into { side, color, relay }. Returns nil + reason for nonsense.
function R.parse(spec, env)
  env = env or {}
  local colorsApi = env.colors or colors
  local relay, rest = spec:match("^([%w_]+)/(.+)$")
  local side, colorName = (rest or spec):match("^(%a+):?(%a*)$")
  if not side or not isSide(side) then return nil, "unknown side '" .. tostring(side or spec) .. "' (use " .. table.concat(R.SIDES, ", ") .. ")" end
  local color
  if colorName and colorName ~= "" then
    color = colorsApi[colorName]
    if type(color) ~= "number" then return nil, "unknown colour '" .. colorName .. "'" end
  end
  if relay and not relay:find("^redstone_relay") then relay = "redstone_relay_" .. relay:gsub("^relay_?", "") end
  return { side = side, color = color, relay = relay, text = spec }
end

--- Open a port. env (all optional, for tests): redstone, peripheral, sleep.
function R.open(spec, env)
  env = env or {}
  local p, err = R.parse(spec, env)
  if not p then return nil, err end
  local rs = env.redstone or redstone
  local per = env.peripheral or peripheral
  local sleepFn = env.sleep or sleep
  if p.relay then
    rs = per.wrap(p.relay)
    if not rs then return nil, "no redstone relay named " .. p.relay end
  end
  local port = { spec = p }

  local function bundledOn() return rs.getBundledOutput(p.side) end

  --- Current output level (0-15 or true/false for bundled colours).
  function port.getOutput()
    if p.color then return bit32.band(bundledOn(), p.color) ~= 0 end
    return rs.getAnalogOutput(p.side)
  end

  --- Current input level.
  function port.getInput()
    if p.color then return rs.testBundledInput(p.side, p.color) end
    return rs.getAnalogInput(p.side)
  end

  --- level: true/false, or 0-15 for analog outputs.
  function port.set(level)
    if p.color then
      local on = level == true or (type(level) == "number" and level > 0)
      local cur = bundledOn()
      rs.setBundledOutput(p.side, on and bit32.bor(cur, p.color) or bit32.band(cur, bit32.bnot(p.color)))
    else
      if level == true then level = 15 elseif level == false then level = 0 end
      if type(level) ~= "number" or level < 0 or level > 15 then error("level must be on, off or 0-15", 2) end
      rs.setAnalogOutput(p.side, math.floor(level))
    end
  end

  function port.toggle()
    local cur = port.getOutput()
    local on = (cur == true) or (type(cur) == "number" and cur > 0)
    port.set(not on)
    return not on
  end

  --- Turn on for `seconds`, then off again (even if interrupted by an error).
  function port.pulse(seconds)
    port.set(true)
    local ok, err = pcall(sleepFn, seconds or 0.5)
    port.set(false)
    if not ok then error(err, 0) end
  end

  return port
end

--- "on"/"off"/"true"/"false"/0-15 text to a value for set(). Returns nil for nonsense.
function R.level(text)
  text = tostring(text):lower()
  if text == "on" or text == "true" or text == "high" then return true end
  if text == "off" or text == "false" or text == "low" then return false end
  local n = tonumber(text)
  if n and n >= 0 and n <= 15 and n == math.floor(n) then return n end
  return nil
end

return R
