-- SPDX-License-Identifier: AGPL-3.0-or-later
local F = dofile("/tests/lib/fakes.lua")
local hal = require("tsr.hal")
local cdisplay = require("tsr.hal.cdisplay")

--- A fake create_source: a small text grid.
local function source(w, h)
  local s = { _type = "create_source", rows = {}, cx = 1, cy = 1 }
  for y = 1, h do s.rows[y] = string.rep(" ", w) end
  function s.getSize() return w, h end
  function s.clear() for y = 1, h do s.rows[y] = string.rep(" ", w) end end
  function s.setCursorPos(x, y) s.cx, s.cy = x, y end
  function s.write(t)
    local row = s.rows[s.cy]
    if row then s.rows[s.cy] = (row:sub(1, s.cx - 1) .. t .. row:sub(s.cx + #t)):sub(1, w) end
  end
  function s.getLine(y) return s.rows[y] end
  return s
end

local function target(lines)
  local t = { _type = "create_target" }
  function t.getSize() return 20, #lines end
  function t.getLine(y) return lines[y] end
  return t
end

local function env(devices)
  hal.reset()
  return { peripheral = F.peripheralApi(devices), redstone = F.redstone(), devicesPath = "/tmp-create/none" }
end

test("sources are displays you can write to, targets can be read", function()
  local s = source(20, 3)
  local e = env({ board = s, sign = target({ "Hello", "World", "" }) })
  local b = hal.get("board", e)
  ok(b:has("display"))
  eq(b:get("display.size"), "20x3")
  ok(b:act("display.write", "Hi", 3, 2))
  eq(s.rows[2]:sub(3, 4), "Hi")
  ok(b:act("display.clear"))
  eq(s.rows[2], string.rep(" ", 20))
  local t = hal.get("sign", e)
  ok(t:has("display") and t:has("sensor"))
  eq(t:get("display.line", 2), "World")
  eq(t:get("display.text"), "Hello\nWorld\n")
  ok(t.actions["display.write"] == nil, "targets are read-only")
end)

test("the cdisplay command", function()
  local s = source(20, 4)
  local cell = { _type = "energy_storage", getEnergy = function() return 250 end, getEnergyCapacity = function() return 1000 end }
  local e = env({ board = s, sign = target({ "Line one", "Line two" }), cell = cell })
  local function run(...)
    local io = { said = {}, errs = {} }
    function io.say(t) io.said[#io.said + 1] = t end
    function io.err(t) io.errs[#io.errs + 1] = t end
    local r = cdisplay.run({ ... }, io, e)
    return r, table.concat(io.said, "\n"), table.concat(io.errs, "\n")
  end
  local r, text = run("list")
  ok(r and text:find("board", 1, true) and text:find("20x4", 1, true), text)
  ok(not text:find("cell", 1, true), "only Create displays are listed")
  ok(run("write", "board", "Welcome\\nto the base"))
  eq(s.rows[1]:gsub("%s+$", ""), "Welcome")
  eq(s.rows[2]:gsub("%s+$", ""), "to the base")
  r, text = run("show", "sign")
  eq(text, "Line one\nLine two")
  eq(run("write", "sign", "x"), false)
  eq(run("write", "ghost", "x"), false)
  ok(run("metric", "board", "cell", "energy.percent", "Power"))
  eq(s.rows[1]:gsub("%s+$", ""), "Power: 25.0 %")
  eq(run("metric", "board", "cell", "nothing"), false)
  eq(run("metric", "board"), false)
  eq(run("bogus"), false)
  -- nothing connected
  e = env({})
  local _, text2 = run("list")
  ok(text2:find("No Create displays", 1, true))
end)
