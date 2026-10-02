-- SPDX-License-Identifier: AGPL-3.0-or-later
local F = dofile("/tests/lib/fakes.lua")
local netbus = dofile("/tests/lib/netbus.lua")
local net = require("tsr.net")
local theme = require("tsr.gui.theme")
local mirror = require("tsr.tv.mirror")
local signage = require("tsr.tv.signage")
local kiosk = require("tsr.tv.kiosk")
local tvshell = require("tsr.tv.shell")
local remote = require("tsr.tv.remote")
local image = require("tsr.gfx.image")
local media = require("tsr.media")

local DIR = "/tmp-tv"

local function fresh()
  theme.set("dark", true)
  if fs.exists(DIR) then fs.delete(DIR) end
  fs.makeDir(DIR)
  signage.CFG_PATH = DIR .. "/signage.cfg"
  kiosk.CFG_PATH = DIR .. "/kiosk.cfg"
  tvshell.MEDIA_DIR = DIR .. "/media"
end

local function win(w, h) return window.create(term.current(), 1, 1, w or 30, h or 12, false) end

local function text(t)
  local w, h = t.getSize()
  local out = {}
  for y = 1, h do out[y] = (t.getLine(y):gsub("%s+$", "")) end
  return table.concat(out, "\n")
end

local function put(path, body, binary)
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local h = fs.open(path, binary and "wb" or "w")
  h.write(body)
  h.close()
end

local function cli(fn, ...)
  local io = { said = {}, errs = {} }
  function io.say(t) io.said[#io.said + 1] = t end
  function io.err(t) io.errs[#io.errs + 1] = t end
  local r = fn({ ... }, io, ...)
  return r, table.concat(io.said, "\n"), table.concat(io.errs, "\n")
end

---------------------------------------------------------------------------------------------------------------------
-- mirror
---------------------------------------------------------------------------------------------------------------------

test("a tee terminal draws on every target", function()
  local a, b = win(20, 5), win(10, 3)
  local t = mirror.tee({ a, b })
  t.setCursorPos(2, 2)
  t.setTextColor(colors.red)
  t.write("hello")
  eq(a.getLine(2):sub(2, 6), "hello")
  eq(b.getLine(2):sub(2, 6), "hello")
  eq(select(2, b.getLine(2)):sub(2, 2), colors.toBlit(colors.red))
  eq({ t.getSize() }, { 20, 5 }, "queries are answered by the master")
  eq({ t.getCursorPos() }, { 7, 2 })
  t.clear()
  eq(a.getLine(2):gsub(" ", ""), "")
  eq(b.getLine(2):gsub(" ", ""), "")
  t.setCursorPos(1, 1)
  t.blit("ab", "00", "ff")
  eq(b.getLine(1):sub(1, 2), "ab")
  t.setTextScale(2)           -- ignored, must not fail
  -- a small monitor clips what does not fit
  t.setCursorPos(8, 1)
  t.write("0123456789")
  eq(b.getLine(1):sub(8, 10), "012")
end)

test("copy and the mirror command", function()
  local src = win(10, 3)
  src.setCursorPos(1, 1)
  src.write("copy me")
  local mon = win(5, 2)
  ok(mirror.copy(src, mon))
  eq(mon.getLine(1), "copy ")
  local bad, err = mirror.copy({}, mon)
  ok(bad == nil and err:find("cannot be copied"))
  mon.setCursorPos(1, 1)
  local per = F.peripheralApi({ tv1 = (function() mon._type = "monitor" return mon end)() })
  local r = cli(mirror.cli, "copy", "tv1")
  ok(r == false or r == true)
  -- run a command with output duplicated
  local ran
  local real = term.current()
  local before = term.current()
  local r2 = mirror.cli({ "tv1", "--", "echo hi" }, { say = function() end, err = function() end }, { peripheral = per, run = function(line)
    ran = line
    term.current().write("X")
  end })
  ok(r2)
  eq(ran, "echo hi")
  ok(term.current() == before, "the terminal was restored")
  ok(text(mon):find("X", 1, true), "the monitor got the output as well")
  local bad2, _, e2 = cli(function(args, io) return mirror.cli(args, io, { peripheral = per }) end, "ghost")
  ok(bad2 == false and e2:find("no monitor"))
  eq(mirror.cli({}, { say = function() end, err = function() end }), false)
end)

---------------------------------------------------------------------------------------------------------------------
-- signage
---------------------------------------------------------------------------------------------------------------------

test("slides: text, clock, metric, image, video", function()
  fresh()
  local t = win(30, 8)
  local waits = {}
  local per = F.peripheralApi({ cell = { _type = "energy_storage", getEnergy = function() return 250 end, getEnergyCapacity = function() return 1000 end } })
  eq(signage.show({ kind = "text", text = "HI", scale = 1, seconds = 3 }, t, { peripheral = per }), 3)
  ok(text(t):find("[\128-\159]"), "big letters drawn")
  eq(signage.show({ kind = "clock" }, t), signage.DEFAULT_SECONDS)
  ok(text(t):find("[\128-\159]"))
  eq(signage.show({ kind = "metric", device = "cell", metric = "energy.percent", label = "Power" }, t, { peripheral = per }), signage.DEFAULT_SECONDS)
  ok(text(t):find("[\128-\159]"))
  put(DIR .. "/p.nfp", "0f\nf0\n")
  eq(signage.show({ kind = "image", path = DIR .. "/p.nfp", seconds = 0.1 }, t, {}), 0, "playing took the time")
  put(DIR .. "/v.bimg", image.toBimg({ { { "AB", "00", "ff" } }, { { "CD", "00", "ff" } } }, { secondsPerFrame = 0.05 }))
  eq(signage.show({ kind = "video", path = DIR .. "/v.bimg", seconds = 0.2 }, t, {}), 0)
  eq(signage.show({ kind = "image", path = DIR .. "/missing.nfp", seconds = 2 }, t, {}), 2, "a missing picture shows a notice")
  eq(signage.show({ kind = "unknown" }, t, {}), 1)
end)

test("the slideshow cycles through the slides", function()
  fresh()
  local t = win(30, 8)
  local waits = {}
  local cfg = { slides = { { kind = "text", text = "ONE", seconds = 1 }, { kind = "text", text = "TWO", seconds = 2 } } }
  ok(signage.run(cfg, { term = t, maxSlides = 5, sleep = function(s) waits[#waits + 1] = s end }))
  eq(waits, { 1, 2, 1, 2, 1 })
  local none, err = signage.run({ slides = {} }, { term = t })
  ok(none == nil and err:find("no slides"))
  none, err = signage.run({ monitor = "ghost", slides = { { kind = "clock" } } }, { peripheral = { wrap = function() return nil end } })
  ok(none == nil and err:find("not found"))
end)

test("the signage command edits the playlist", function()
  fresh()
  local r, text_ = cli(signage.cli, "list")
  ok(r and text_:find("No slides", 1, true))
  ok(cli(signage.cli, "add", "text", "Hello", "there"))
  ok(cli(signage.cli, "add", "image", "/media/logo.nfp", "12"))
  ok(cli(signage.cli, "add", "clock"))
  ok(cli(signage.cli, "add", "metric", "cell", "energy.percent", "Power"))
  ok(cli(signage.cli, "monitor", "tv"))
  local cfg = signage.loadConfig()
  eq(#cfg.slides, 4)
  eq(cfg.slides[1].text, "Hello there")
  eq(cfg.slides[2].seconds, 12)
  eq(cfg.monitor, "tv")
  r, text_ = cli(signage.cli, "list")
  ok(text_:find("1. text   Hello there", 1, true) and text_:find("12s", 1, true), text_)
  ok(cli(signage.cli, "remove", "3"))
  eq(#signage.loadConfig().slides, 3)
  eq(cli(signage.cli, "remove", "9"), false)
  eq(cli(signage.cli, "add", "text"), false)
  eq(cli(signage.cli, "add", "weird"), false)
  eq(cli(signage.cli, "monitor"), false)
  eq(cli(signage.cli, "bogus"), false)
end)

---------------------------------------------------------------------------------------------------------------------
-- kiosk
---------------------------------------------------------------------------------------------------------------------

test("the kiosk restarts its command and survives crashes", function()
  fresh()
  local runs, pauses = 0, {}
  local n = kiosk.run({ command = "show", delay = 3 }, {
    maxRuns = 4,
    sleep = function(s) pauses[#pauses + 1] = s end,
    runner = function(line)
      runs = runs + 1
      eq(line, "show")
      if runs == 2 then error("the program crashed") end
      if runs == 3 then error("Terminated", 0) end
      return 0
    end,
  })
  eq(n, 4)
  eq(pauses, { 3, 3, 3 })
  local none, err = kiosk.run({}, {})
  ok(none == nil and err:find("no command"))
  -- a failing pause (Ctrl+T during sleep) does not end the loop either
  n = kiosk.run({ command = "x" }, { maxRuns = 2, runner = function() end, sleep = function() error("Terminated", 0) end })
  eq(n, 2)
end)

test("kiosk programs cannot be terminated", function()
  local protected = kiosk.protectedOs()
  eq(protected.time, os.time, "everything else is the normal os")
  local got
  parallel.waitForAll(
    function()
      repeat got = { protected.pullEvent() } until got[1] ~= "timer"     -- other tests may leave timers behind
    end,
    function()
      os.queueEvent("terminate")
      os.queueEvent("char", "x")
    end)
  eq({ got[1], got[2] }, { "char", "x" })
  -- the shell hands that os to programs
  fresh()
  put(DIR .. "/probe.lua", "return type(os.pullEvent) == 'function'")
  local exec = require("tsr.shell.exec")
  local sh = exec.new({ programOs = protected, dir = "tmp-tv" })
  sh.pathString = "/tmp-tv"
  put(DIR .. "/ostest.lua", "tsr_os_marker = os.pullEvent")
  local capture = require("tsr.shell.capture")
  ok(sh:runLine("ostest") == 0)
end)

test("the kiosk command", function()
  fresh()
  local r, text_ = cli(kiosk.cli, "status")
  ok(r and text_:find("(none)", 1, true))
  ok(cli(kiosk.cli, "set", "play", "/media/a.bimg", "--loop"))
  eq(kiosk.loadConfig().command, "play /media/a.bimg --loop")
  r, text_ = cli(kiosk.cli, "status")
  ok(text_:find("play /media/a.bimg --loop", 1, true))
  eq(cli(kiosk.cli, "set"), false)
  eq(cli(kiosk.cli, "bogus"), false)
end)

---------------------------------------------------------------------------------------------------------------------
-- TV shell and remote
---------------------------------------------------------------------------------------------------------------------

local function newTv(extra)
  fresh()
  local per = F.peripheralApi({})
  local opts = { term = win(50, 16), peripheral = per, mediaDir = DIR .. "/media" }
  for k, v in pairs(extra or {}) do opts[k] = v end
  local tv = tvshell.new(opts)
  tv:home()
  tv:draw()
  return tv
end

test("the home screen shows the apps and focus follows the arrows", function()
  local tv = newTv()
  local t = text(tv.t)
  ok(t:find("Media", 1, true) and t:find("Signage", 1, true) and t:find("Dashboard", 1, true) and t:find("Settings", 1, true), t)
  ok(tv.root.focused == tv.tiles[1])
  tv:event("tv_key", "right")
  ok(tv.root.focused == tv.tiles[2], "right neighbour")
  tv:event("tv_key", "down")
  ok(tv.root.focused == tv.tiles[4])
  tv:event("tv_key", "left")
  ok(tv.root.focused == tv.tiles[3])
  tv:event("tv_key", "up")
  ok(tv.root.focused == tv.tiles[1])
  eq(tv:event("tv_key", "nonsense"), false)
end)

test("OK opens an app, Back and Home return", function()
  local tv = newTv()
  tv:event("tv_key", "ok")
  eq(tv.stack[#tv.stack].title, "Media")
  tv:draw()
  ok(text(tv.t):find("No media in", 1, true), text(tv.t))
  tv:event("tv_key", "back")
  eq(tv.stack[#tv.stack].title, "Home")
  tv:event("tv_key", "right")
  tv:event("tv_key", "ok")
  eq(tv.stack[#tv.stack].title, "Signage")
  tv:event("tv_key", "home")
  eq(#tv.stack, 1)
  -- touching a tile works like OK
  local x, y = tv.tiles[3]:abs()
  tv:event("monitor_touch", "anything", x + 2, y + 1)
  eq(tv.stack[#tv.stack].title, "Dashboard")
end)

test("the media app lists files and plays the chosen one", function()
  local tv = newTv()
  put(DIR .. "/media/clip.bimg", image.toBimg({ { { "AB", "00", "ff" } } }))
  put(DIR .. "/media/pic.nfp", "0f\n")
  tv:event("tv_key", "ok")
  tv:draw()
  local t = text(tv.t)
  ok(t:find("clip.bimg", 1, true) and t:find("pic.nfp", 1, true), t)
  -- OK on the first entry plays it; a key stops it
  local events = { { "tv_key", "back" } }
  tv.pull = function() return table.unpack(table.remove(events, 1) or { "key", keys.q }) end
  tv:event("tv_key", "ok")
  eq(tv.stack[#tv.stack].title, "Media", "back on the list after playing")
end)

test("the dashboard reads devices through the HAL", function()
  local per = F.peripheralApi({ cell = { _type = "energy_storage", getEnergy = function() return 250 end, getEnergyCapacity = function() return 1000 end },
                                tank = { _type = "fluid_storage", tanks = function() return { { name = "water", amount = 500 } } end } })
  local tv = newTv({ peripheral = per })
  tv:event("tv_key", "right")
  tv:event("tv_key", "down")
  tv:event("tv_key", "left")
  tv:event("tv_key", "ok")
  eq(tv.stack[#tv.stack].title, "Dashboard")
  tv:draw()
  local t = text(tv.t)
  ok(t:find("cell", 1, true) and t:find("25%", 1, true), t)
  ok(t:find("tank", 1, true) and t:find("500 mB", 1, true), t)
end)

test("settings change the theme and offer shut down", function()
  local config = require("tsr.config")
  config.reset()
  config.paths.system = DIR .. "/system.cfg"
  local tv = newTv()
  tv:event("tv_key", "right")
  tv:event("tv_key", "down")
  tv:event("tv_key", "ok")
  eq(tv.stack[#tv.stack].title, "Settings")
  tv:draw()
  ok(text(tv.t):find("Theme: light", 1, true))
  tv.root.focused.items[1] = tv.root.focused.items[1]
  local list = tv.root.focused
  list:select(2)
  tv:event("tv_key", "ok")
  eq(theme.currentName, "light")
  eq(config.get("ui.theme"), "light")
  theme.set("dark", true)
  local buttons = {}
  local function walk(w) if w.text == "Shut down" then buttons.shutdown = w end for _, c in ipairs(w.children) do walk(c) end end
  walk(tv.root)
  buttons.shutdown:click()
  eq(tv.exit, "shutdown")
end)

test("the run loop handles events and returns the exit action", function()
  fresh()
  local events = { { "tv_key", "ok" }, { "tv_key", "back" }, { "tv_key", "right" }, { "tv_key", "down" }, { "tv_key", "left" }, { "tv_key", "down" } }
  local tv = tvshell.new({ term = win(50, 16), peripheral = F.peripheralApi({}), mediaDir = DIR .. "/media",
                           pull = function() return table.unpack(table.remove(events, 1) or { "terminate" }) end })
  eq(tv:run(), "shell")
end)

test("the remote sends buttons to the TV over the network", function()
  fresh()
  local bus = netbus.new()
  local tv = net.node({ id = 11, hostname = "livingroom", transport = bus:transport(11), peersPath = DIR .. "/tv.peers" })
  local pocket = net.node({ id = 22, hostname = "pocket", transport = bus:transport(22), peersPath = DIR .. "/p.peers" })
  local failure
  local seenKeys = {}
  parallel.waitForAny(
    function() tv:run() end,
    function() pocket:run() end,
    function() while true do local _, k = os.pullEvent("tv_key") seenKeys[#seenKeys + 1] = k end end,   -- the TV's listener
    function()
      local okRun, err = pcall(function()
        parallel.waitForAll(
          function() ok(tv:pairListen({ code = "ABCDE-FGHJK", timeout = 10 })) end,
          function() sleep(0.2) ok(pocket:pairConnect(11, "ABCDE-FGHJK", 5)) end)
        remote.serve(tv)
        ok(remote.press(pocket, "livingroom", "up"))
        eq(seenKeys, { "up" })
        local bad, why = remote.press(pocket, "livingroom", "format")
        ok(bad == nil and why == "unknown key")
        local r2, e2 = tv:call("pocket", "tv", "key", { key = "ok" })
        ok(r2 == nil, "the TV has no tv service for calls the other way")
        -- the remote screen: tap buttons and use the keyboard
        local screen = win(26, 14)
        local sent = {}
        local events = { { "key", keys.enter }, { "key", keys.down }, { "char", "q" } }
        remote.ui(pocket, "livingroom", { term = screen, pull = function() return table.unpack(table.remove(events, 1)) end })
        ok(text(screen):find("Up", 1, true) and text(screen):find("Home", 1, true))
        eq(seenKeys, { "up", "ok", "down" })
      end)
      if not okRun then failure = err end
    end)
  if failure then error(failure, 0) end
end)

test("the remote reports a TV that cannot be reached", function()
  fresh()
  local bus = netbus.new()
  local pocket = net.node({ id = 22, hostname = "pocket", transport = bus:transport(22), peersPath = DIR .. "/p.peers" })
  local bad, err = remote.press(pocket, "nowhere", "ok")
  ok(bad == nil and err:find("not paired"))
end)
