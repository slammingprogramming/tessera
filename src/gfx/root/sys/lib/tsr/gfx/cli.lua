-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Commands of the gfx package.
--   banner <text...> [--scale n] [--color name]     big letters on the terminal (or `--monitor <name>`)
--   imgview <file> [--monitor name]                  show an NFP or BIMG image; animated BIMG plays until a key is pressed
--   palette list | show | apply <name> | reset       change the colours of the screen
local gfx = require("tsr.gfx")
local image = require("tsr.gfx.image")
local palette = require("tsr.gfx.palette")

local M = {}

local function defaultIO()
  local io = {}
  function io.say(t) print(t) end
  function io.err(t) if term.isColor() then term.setTextColor(colors.red) end print(t) term.setTextColor(colors.white) end
  return io
end

local function target(opts, env)
  if opts.monitor then
    local per = (env and env.peripheral) or peripheral
    local mon = per.wrap(opts.monitor)
    if not mon then return nil, "no monitor named " .. opts.monitor end
    return mon
  end
  return (env and env.term) or term.current()
end

local function parseOpts(args)
  local words, opts = {}, {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--scale" or a == "--color" or a == "--monitor" then opts[a:sub(3)] = args[i + 1] i = i + 2
    else words[#words + 1] = a i = i + 1 end
  end
  return words, opts
end

function M.banner(args, io, env)
  io = io or defaultIO()
  local words, opts = parseOpts(args)
  if #words == 0 then io.err("usage: banner <text...> [--scale n] [--color name] [--monitor name]") return false end
  local t, err = target(opts, env)
  if not t then io.err(err) return false end
  local color = colors.white
  if opts.color then
    color = colors[opts.color]
    if type(color) ~= "number" then io.err("unknown colour: " .. opts.color) return false end
  end
  local text = table.concat(words, " ")
  local scale = math.max(1, math.min(8, tonumber(opts.scale) or 1))
  local w, h = t.getSize()
  -- shrink to fit the width
  while scale > 1 and math.ceil(gfx.textWidth(text, scale) / 2) > w do scale = scale - 1 end
  t.setBackgroundColor(colors.black)
  if env == nil or env.clear ~= false then t.clear() end
  local cols, rows = gfx.bigText(t, 1, 1, text, color, colors.black, scale)
  t.setCursorPos(1, math.min(h, rows + 2))
  return true
end

function M.imgview(args, io, env)
  io = io or defaultIO()
  local words, opts = parseOpts(args)
  if not words[1] then io.err("usage: imgview <file> [--monitor name]") return false end
  local path = (rawget(_G, "shell") and not (env and env.noShell)) and shell.resolve(words[1]) or words[1]
  local img, err = image.load(path)
  if not img then io.err(tostring(err)) return false end
  local t, terr = target(opts, env)
  if not t then io.err(terr) return false end
  t.setBackgroundColor(colors.black)
  t.clear()
  if img.kind == "bimg" and img.animated and #img.frames > 1 and not (env and env.once) then
    local frame = 1
    local timer = os.startTimer(img.secondsPerFrame)
    while true do
      img:draw(t, 1, 1, frame)
      local ev, a = os.pullEvent()
      if ev == "key" or ev == "mouse_click" then break end
      if ev == "timer" and a == timer then
        frame = frame % #img.frames + 1
        timer = os.startTimer(img.secondsPerFrame)
      end
    end
  else
    img:draw(t, 1, 1, 1)
    if not (env and env.once) then os.pullEvent("key") end
  end
  if not opts.monitor and not (env and env.once) then
    t.setBackgroundColor(colors.black)
    t.clear()
    t.setCursorPos(1, 1)
  end
  return true
end

function M.palette(args, io, env)
  io = io or defaultIO()
  local config = (env and env.config) or require("tsr.config")
  local t = (env and env.term) or term.current()
  local cmd = args[1] or "list"
  if cmd == "list" then
    local current = config.get("ui.palette", "default")
    for _, n in ipairs(palette.names) do io.say((n == current and "* " or "  ") .. n) end
    return true
  elseif cmd == "show" then
    for i, cname in ipairs(palette.ORDER) do
      t.setBackgroundColor(colors[cname])
      t.setTextColor(cname == "black" and colors.white or colors.black)
      t.write(" " .. cname:sub(1, 3) .. " ")
      if i % 8 == 0 then t.setBackgroundColor(colors.black) print() end
    end
    t.setBackgroundColor(colors.black)
    t.setTextColor(colors.white)
    return true
  elseif cmd == "apply" then
    local name = args[2]
    local ok, err = palette.apply(name, t)
    if not ok then io.err(tostring(err)) return false end
    config.set("ui.palette", name, "system")
    io.say("Palette " .. name .. " applied (and saved for the next boot).")
    return true
  elseif cmd == "reset" then
    local ok, err = palette.reset(t)
    if not ok then io.err(tostring(err)) return false end
    config.set("ui.palette", "default", "system")
    io.say("Original colours restored.")
    return true
  end
  io.err("usage: palette list | show | apply <name> | reset")
  return false
end

return M
