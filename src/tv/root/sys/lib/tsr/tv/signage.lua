-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Digital signage: a slideshow on a monitor that runs by itself.
-- /etc/tsr/signage.cfg:  { monitor = "monitor_0", slides = { ... } }   (no monitor = the computer's own screen)
-- Slides (each lasts `seconds`, default 8):
--   { kind = "text",   text = "Welcome!", scale = 2, color = "yellow" }      big letters, centred
--   { kind = "image",  path = "/media/logo.nfp" }                           a picture (NFP or a one-frame BIMG)
--   { kind = "video",  path = "/media/loop.bimg" }                          an animation (plays for `seconds`, looping)
--   { kind = "clock" }                                                      the time of day
--   { kind = "metric", device = "cell", metric = "energy.percent", label = "Power" }   a live reading through the HAL
--   signage list | add text <text...> | add image|video <path> [seconds] | add clock | remove <n> | monitor <name> | run
local vfs = require("tsr.vfs")
local gfx = require("tsr.gfx")
local media = require("tsr.media")

local M = {}

M.CFG_PATH = "/etc/tsr/signage.cfg"
M.DEFAULT_SECONDS = 8

function M.loadConfig() return vfs.readTable(M.CFG_PATH) or { slides = {} } end
function M.saveConfig(cfg) return vfs.writeTable(M.CFG_PATH, cfg) end

local function clear(t)
  t.setBackgroundColor(colors.black)
  t.clear()
end

--- Draw big text centred on `t`, scaled down to fit. Returns the scale that was used.
local function centered(t, text, colorName, scale)
  local w, h = t.getSize()
  scale = math.max(1, scale or 1)
  while scale > 1 and (math.ceil(gfx.textWidth(text, scale) / 2) > w or math.ceil(gfx.textHeight(scale) / 3) > h) do scale = scale - 1 end
  local cols = math.ceil(gfx.textWidth(text, scale) / 2)
  local rows = math.ceil(gfx.textHeight(scale) / 3)
  local color = (colorName and colors[colorName]) or colors.white
  gfx.bigText(t, math.max(1, math.floor((w - cols) / 2) + 1), math.max(1, math.floor((h - rows) / 2) + 1), text, color, colors.black, scale)
  return scale
end

--- Show one slide. Returns the number of seconds it should stay (0 when playing already took that time).
--- env: peripheral (for metrics), pull (events), sleep.
function M.show(slide, t, env)
  env = env or {}
  local seconds = slide.seconds or M.DEFAULT_SECONDS
  clear(t)
  if slide.kind == "text" then
    centered(t, tostring(slide.text or ""), slide.color, slide.scale or 2)
    return seconds
  elseif slide.kind == "clock" then
    centered(t, textutils.formatTime(os.time("local"), true), slide.color or "lime", slide.scale or 2)
    return seconds
  elseif slide.kind == "metric" then
    local okHal, hal = pcall(require, "tsr.hal")
    local text = (slide.label and (slide.label .. ": ") or "") .. "?"
    if okHal then
      local dev = hal.get(slide.device, { peripheral = env.peripheral })
      if dev then
        local v, unit = dev:get(slide.metric)
        if v ~= nil then
          text = (slide.label and (slide.label .. ": ") or "") .. (type(v) == "number" and (v == math.floor(v) and ("%d"):format(v) or ("%.1f"):format(v)) or tostring(v)) .. (unit and (" " .. unit) or "")
        end
      end
    end
    centered(t, text, slide.color, slide.scale or 1)
    return seconds
  elseif slide.kind == "image" or slide.kind == "video" then
    local result, err = media.playVideo(slide.path or "", t, { duration = seconds, loop = slide.kind == "video", interruptible = false, pull = env.pull })
    if not result then
      centered(t, "MISSING", "red", 1)
      return seconds
    end
    return 0
  end
  centered(t, "?", "red", 1)
  return 1
end

--- The slideshow loop. env: term, peripheral, maxSlides (tests), sleep.
function M.run(cfg, env)
  env = env or {}
  cfg = cfg or M.loadConfig()
  local per = env.peripheral or peripheral
  local t = env.term or (cfg.monitor and per.wrap(cfg.monitor)) or term.current()
  if cfg.monitor and not env.term and not per.wrap(cfg.monitor) then return nil, "monitor '" .. cfg.monitor .. "' not found" end
  if #(cfg.slides or {}) == 0 then return nil, "no slides: add some with `signage add`" end
  local shown = 0
  local pause = env.sleep or sleep
  while true do
    for _, slide in ipairs(cfg.slides) do
      local wait = M.show(slide, t, env)
      if wait > 0 then pause(wait) end
      shown = shown + 1
      if env.maxSlides and shown >= env.maxSlides then return true end
    end
  end
end

local function defaultIO()
  local io = {}
  function io.say(t) print(t) end
  function io.err(t) if term.isColor() then term.setTextColor(colors.red) end print(t) term.setTextColor(colors.white) end
  return io
end

function M.cli(args, io, env)
  io = io or defaultIO()
  local cfg = M.loadConfig()
  cfg.slides = cfg.slides or {}
  local cmd = args[1] or "list"
  if cmd == "list" then
    io.say("monitor: " .. tostring(cfg.monitor or "this screen"))
    if #cfg.slides == 0 then io.say("No slides.") end
    for i, s in ipairs(cfg.slides) do
      io.say(("%d. %-6s %s (%ds)"):format(i, s.kind, s.text or s.path or (s.device and (s.device .. " " .. s.metric)) or "", s.seconds or M.DEFAULT_SECONDS))
    end
    return true
  elseif cmd == "add" then
    local kind = args[2]
    local slide
    if kind == "text" and args[3] then
      slide = { kind = "text", text = table.concat(args, " ", 3) }
    elseif (kind == "image" or kind == "video") and args[3] then
      slide = { kind = kind, path = args[3], seconds = tonumber(args[4]) }
    elseif kind == "clock" then
      slide = { kind = "clock", seconds = tonumber(args[3]) }
    elseif kind == "metric" and args[3] and args[4] then
      slide = { kind = "metric", device = args[3], metric = args[4], label = args[5] }
    else
      io.err("usage: signage add text <text...> | image|video <path> [seconds] | clock [seconds] | metric <device> <reading> [label]")
      return false
    end
    cfg.slides[#cfg.slides + 1] = slide
    M.saveConfig(cfg)
    io.say("Slide " .. #cfg.slides .. " added.")
    return true
  elseif cmd == "remove" then
    local n = tonumber(args[2])
    if not n or not cfg.slides[n] then io.err("usage: signage remove <number>") return false end
    table.remove(cfg.slides, n)
    M.saveConfig(cfg)
    io.say("Removed.")
    return true
  elseif cmd == "monitor" then
    if not args[2] then io.err("usage: signage monitor <name>") return false end
    cfg.monitor = args[2]
    M.saveConfig(cfg)
    io.say("Showing on " .. args[2] .. ".")
    return true
  elseif cmd == "run" then
    local ok, err = M.run(cfg, env)
    if not ok then io.err(tostring(err)) return false end
    return true
  end
  io.err("usage: signage list | add | remove | monitor | run")
  return false
end

function M.main(args) return M.cli(args) end

--- The signaged service.
function M.daemon()
  local ok, err = M.run(M.loadConfig(), {})
  if not ok then error(tostring(err), 0) end
end

return M
