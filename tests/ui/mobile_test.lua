-- SPDX-License-Identifier: AGPL-3.0-or-later
local theme = require("tsr.gui.theme")
local W = require("tsr.gui.widgets")
local shell_ = require("tsr.mobile.shell")
local apps = require("tsr.mobile.apps")
local notify = require("tsr.notify")
local net = require("tsr.net")
local netbus = dofile("/tests/lib/netbus.lua")

local DIR = "/tmp-mobile"

local function screen(w, h) return window.create(term.current(), 1, 1, w or 26, h or 20, false) end

local function text(t)
  local w, h = t.getSize()
  local out = {}
  for y = 1, h do out[y] = (t.getLine(y):gsub("%s+$", "")) end
  return table.concat(out, "\n")
end

local function fresh()
  theme.set("dark", true)
  if fs.exists(DIR) then fs.delete(DIR) end
  fs.makeDir(DIR)
  notify.PATH = DIR .. "/notifications.json"
  apps.MESSAGE_LOG = DIR .. "/messages.json"
end

local function phoneWith(list, extra)
  fresh()
  local opts = { term = screen(), apps = list, now = function() return "12:00" end, signal = function() return true end }
  for k, v in pairs(extra or {}) do opts[k] = v end
  local p = shell_.new(opts)
  p:home()
  p:redrawAll()
  return p
end

local function click(p, x, y)
  p:event("mouse_click", 1, x, y)
  p:event("mouse_up", 1, x, y)
  p:redrawAll()
end

local function appList(n)
  local out = {}
  for i = 1, n do
    out[i] = { id = "app" .. i, name = "App" .. i, icon = "#", build = function(root) root:add(W.label({ x = 1, y = 1, text = "inside app " .. i })) end }
  end
  return out
end

test("notifications are stored, counted and cleared", function()
  fresh()
  eq(notify.unread(), 0)
  local id = notify.push("Reactor", "Temperature high", { level = "warn" })
  notify.push("Door", "Opened")
  eq(notify.unread(), 2)
  local list = notify.list()
  eq({ list[1].title, list[2].title }, { "Door", "Reactor" }, "newest first")
  eq(list[2].level, "warn")
  ok(list[2].id == id)
  notify.markRead()
  eq(notify.unread(), 0)
  for i = 1, 60 do notify.push("n" .. i, "x") end
  eq(#notify.list(), notify.MAX)
  eq(notify.list()[1].title, "n60")
  notify.clear()
  eq(#notify.list(), 0)
end)

test("home shows app tiles and a status bar", function()
  local p = phoneWith(appList(4))
  local t = text(p.t)
  local first = t:match("^[^\n]*")
  ok(first:find("12:00", 1, true) and first:find("net", 1, true), first)
  ok(t:find("App1", 1, true) and t:find("App4", 1, true), t)
  -- the navigation bar is the last row
  local rows = {}
  for line in (t .. "\n"):gmatch("(.-)\n") do rows[#rows + 1] = line end
  ok(rows[20]:find("<", 1, true) and rows[20]:find("o", 1, true) and rows[20]:find("=", 1, true), rows[20])
end)

test("tapping a tile opens the app; back and home navigate", function()
  local p = phoneWith(appList(4))
  -- tiles are two per row, 3 rows high, starting below the status bar
  click(p, 3, 3)                  -- App1
  eq(p:current().title, "App1")
  ok(text(p.t):find("inside app 1", 1, true))
  ok(text(p.t):match("^[^\n]*"):find("App1", 1, true), "title in the status bar")
  click(p, 3, 20)                 -- back
  eq(p:current().title, "Home")
  click(p, 20, 6)                 -- App4 (second column, second row)
  eq(p:current().title, "App4")
  click(p, 13, 20)                -- home
  eq(p:current().title, "Home")
  eq(#p.stack, 1)
  ok(not p:pop(), "nothing below home")
  -- keyboard shortcuts
  click(p, 3, 3)
  p:event("key", keys.backspace)
  eq(p:current().title, "Home")
end)

test("many apps are paged with the mouse wheel", function()
  local p = phoneWith(appList(20))
  ok(p.pages > 1, "pages: " .. tostring(p.pages))
  ok(text(p.t):find("App1", 1, true) and not text(p.t):find("App20", 1, true))
  p:event("mouse_scroll", 1, 5, 8)
  p:redrawAll()
  eq(p.page, 2)
  ok(not text(p.t):find("App1 ", 1, true))
  p:event("mouse_scroll", -1, 5, 8)
  eq(p.page, 1)
end)

test("the status bar shows notifications and the = button opens them", function()
  local list = appList(1)
  list[1] = { id = "notifications", name = "Alerts", icon = "!", build = function(root, phone) apps.notifications(root, phone) end }
  local p = phoneWith(list)
  notify.push("Door", "The vault door opened", { level = "warn" })
  notify.push("Backup", "Finished")
  p:redrawAll()
  ok(text(p.t):match("^[^\n]*"):find("!2", 1, true), text(p.t):match("^[^\n]*"))
  click(p, 24, 20)                -- the = button
  eq(p:current().title, "Alerts")
  local t = text(p.t)
  ok(t:find("Backup", 1, true) and t:find("Door", 1, true), t)
  eq(notify.unread(), 0, "viewing marks them read")
  -- selecting another entry shows its text
  p.root.focused = nil
  local listWidget
  for _, c in ipairs(p.root.children) do if c.items then listWidget = c end end
  listWidget:select(2)
  p:redrawAll()
  ok(text(p.t):find("vault door", 1, true), text(p.t))
  -- clear all
  for _, c in ipairs(p.root.children) do if c.text == "Clear all" then c:click() end end
  eq(#notify.list(), 0)
  p:redrawAll()
  ok(text(p.t):find("No notifications", 1, true))
end)

test("location shows coordinates or a hint", function()
  local p = phoneWith({})
  p:push("Location", function(root, phone) apps.location(root, phone, { locate = function() return 10.4, 64, -3.6 end }) end)
  p:redrawAll()
  local t = text(p.t)
  ok(t:find("x 10", 1, true) and t:find("y 64", 1, true) and t:find("z -4", 1, true), t)
  p:push("Location", function(root, phone) apps.location(root, phone, { locate = function() return nil end }) end)
  p:redrawAll()
  ok(text(p.t):find("No GPS signal", 1, true))
end)

test("settings change theme and exit actions", function()
  local config = require("tsr.config")
  config.reset()
  config.paths.system = DIR .. "/system.cfg"
  local p = phoneWith({})
  p:push("Settings", function(root, phone) apps.settings(root, phone, { config = config }) end)
  p:redrawAll()
  ok(text(p.t):find("Theme", 1, true) and text(p.t):find("contrast", 1, true))
  local list
  for _, c in ipairs(p.root.children) do if c.items then list = c end end
  for i, item in ipairs(list.items) do if item.name == "light" then list:select(i) end end
  eq(config.get("ui.theme"), "light")
  eq(theme.currentName, "light")
  local box, shutdown
  for _, c in ipairs(p.root.children) do
    if c.text == "Phone mode at boot" then box = c end
    if c.text == "Shut down" then shutdown = c end
  end
  box:toggle()
  eq(config.get("ui.default"), "mobile")
  shutdown:click()
  eq(p.exitAction, "shutdown")
  theme.set("dark", true)
end)

test("messages travel between computers and become notifications", function()
  fresh()
  local bus = netbus.new()
  local a = net.node({ id = 11, hostname = "alice", transport = bus:transport(11), peersPath = DIR .. "/a.peers" })
  local b = net.node({ id = 22, hostname = "bob", transport = bus:transport(22), peersPath = DIR .. "/b.peers" })
  local failure
  parallel.waitForAny(
    function() a:run() end, function() b:run() end,
    function()
      local okRun, err = pcall(function()
        parallel.waitForAll(
          function() ok(a:pairListen({ code = "ABCDE-FGHJK", timeout = 10 })) end,
          function() sleep(0.2) ok(b:pairConnect(11, "ABCDE-FGHJK", 5)) end)
        apps.serveMessages(a)
        local p = phoneWith({}, {})
        p:push("Messages", function(root, phone) apps.messages(root, phone, { node = b }) end)
        p:redrawAll()
        ok(text(p.t):find("alice", 1, true), text(p.t))
        -- open the conversation, type, send
        local list
        for _, c in ipairs(p.root.children) do if c.items then list = c end end
        list:focus()
        p:event("key", keys.enter)
        eq(p:current().title, "alice")
        for c in ("hello"):gmatch(".") do p:event("char", c) end
        p:event("key", keys.enter)
        p:redrawAll()
        ok(text(p.t):find("me: hello", 1, true), text(p.t))
        local note = notify.list()[1]
        ok(note and note.title == "Message from bob" and note.text == "hello", note and note.title)
        -- the log keeps both directions
        local log = require("tsr.vfs").readJSON(apps.MESSAGE_LOG)
        eq(#log >= 2, true)
      end)
      if not okRun then failure = err end
    end)
  if failure then error(failure, 0) end
end)

test("messages and remote explain what is missing", function()
  local p = phoneWith({})
  local empty = { peers = function() return {} end }
  p:push("Messages", function(root, phone) apps.messages(root, phone, { node = empty }) end)
  p:redrawAll()
  ok(text(p.t):find("No paired computers", 1, true))
  p:push("Remote", function(root, phone) apps.remote(root, phone, { node = empty }) end)
  p:redrawAll()
  ok(text(p.t):find("No paired computers", 1, true))
end)

test("remote pings and starts a shell", function()
  local node = {
    peers = function() return { { id = 22, name = "bob" } } end,
    ping = function(_, name) return 0.042, name end,
  }
  local ran
  local p = phoneWith({})
  p:push("Remote", function(root, phone) apps.remote(root, phone, { node = node, runProgram = function(line) ran = line end }) end)
  p:redrawAll()
  local ping, shell
  for _, c in ipairs(p.root.children) do
    if c.text == "Ping" then ping = c end
    if c.text == "Shell" then shell = c end
  end
  ping:click()
  p:redrawAll()
  ok(text(p.t):find("bob: 42 ms", 1, true), text(p.t))
  shell:click()
  eq(ran, "rsh bob")
end)

test("application files load; the shipped apps are valid", function()
  local p = shell_.new({ term = screen(), kernel = nil })
  ok(#p.apps >= 6, "shipped apps: " .. #p.apps)
  for _, a in ipairs(p.apps) do ok(a.name and a.icon and a.build, a.id) end
  eq(p.apps[1].id, "notifications")
end)
