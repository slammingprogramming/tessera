-- SPDX-License-Identifier: AGPL-3.0-or-later
local theme = require("tsr.gui.theme")
local W = require("tsr.gui.widgets")
local files = require("tsr.gui.apps.files")
local settings = require("tsr.gui.apps.settings")
local store = require("tsr.gui.apps.store")
local taskman = require("tsr.gui.apps.taskman")
local gui = require("tsr.gui.cli")
local testenv = dofile("/tests/lib/testenv.lua")

local DIR = "/tmp-gui"

local function screen(w, h) return window.create(term.current(), 1, 1, w, h, false) end

local function text(t)
  local w, h = t.getSize()
  local out = {}
  for y = 1, h do out[y] = (t.getLine(y):gsub("%s+$", "")) end
  return table.concat(out, "\n")
end

local function newRoot(w, h)
  theme.set("dark", true)
  return W.root(screen(w, h))
end

local function click(root, x, y)
  root:dispatch("mouse_click", 1, x, y)
  root:dispatch("mouse_up", 1, x, y)
end

local function clickWidget(root, widget)
  local ax, ay = widget:abs()
  click(root, ax + 1, ay)
end

local function findButton(root, label)
  local function walk(w)
    if w.text == label and w.onClick then return w end
    for _, c in ipairs(w.children) do
      local r = walk(c)
      if r then return r end
    end
  end
  return walk(root)
end

local function fresh()
  if fs.exists(DIR) then fs.delete(DIR) end
  fs.makeDir(DIR .. "/docs")
  fs.makeDir(DIR .. "/apps")
  local h = fs.open(DIR .. "/readme.txt", "w")
  h.write("0123456789")
  h.close()
  h = fs.open(DIR .. "/docs/a.lua", "w")
  h.write("x")
  h.close()
end

test("files: entries are sorted with folders first and labelled", function()
  fresh()
  local list = files.entries(DIR)
  eq({ list[1].name, list[2].name, list[3].name }, { "apps", "docs", "readme.txt" })
  ok(list[1].dir and not list[3].dir)
  eq(files.label(list[1]), "apps/")
  eq(files.label(list[3]), "readme.txt  (10B)")
  eq(files.human(2048), "2.0k")
  eq(files.human(3 * 1048576), "3.0M")
  local none, err = files.entries("/definitely/not/here")
  ok(none == nil and err)
end)

test("files: folder operations validate names and refuse dangerous deletes", function()
  fresh()
  ok(files.makeDir(DIR, "new"))
  ok(fs.isDir(DIR .. "/new"))
  local bad, err = files.makeDir(DIR, "new")
  ok(bad == nil and err:find("exists"))
  for _, name in ipairs({ "", "a/b", "..", ".", "x\\y" }) do ok(files.makeDir(DIR, name) == nil, name) end
  ok(files.rename(DIR .. "/new", "renamed"))
  ok(fs.isDir(DIR .. "/renamed") and not fs.exists(DIR .. "/new"))
  bad, err = files.rename(DIR .. "/renamed", "docs")
  ok(bad == nil and err:find("exists"))
  ok(files.delete(DIR .. "/renamed"))
  ok(not fs.exists(DIR .. "/renamed"))
  for _, path in ipairs({ "/", "/rom", "/rom/programs" }) do
    local r, e = files.delete(path)
    ok(r == nil and e:find("cannot be deleted"), path)
  end
end)

test("files window: navigate, open, create, rename, delete", function()
  fresh()
  local root = newRoot(44, 14)
  local opened
  local app = files.build(root, { }, nil, { path = DIR, open = function(p) opened = p end })
  root:render()
  local screenText = text(root.t)
  ok(screenText:find("docs/", 1, true) and screenText:find("readme.txt", 1, true), screenText)
  eq(app.state.path, DIR)
  -- enter a folder with the keyboard, go back up with ../
  local list = app.list
  list:focus()
  local function selectName(name)
    for i, item in ipairs(list.items) do if item.text:find(name, 1, true) then list:select(i) return end end
    error("not in list: " .. name)
  end
  selectName("docs/")
  root:dispatch("key", keys.enter, false)
  eq(app.state.path, DIR .. "/docs")
  ok(list.items[1].up)
  root:dispatch("key", keys.home, false)
  root:dispatch("key", keys.enter, false)
  eq(app.state.path, DIR)
  -- opening a file calls the handler
  selectName("readme.txt")
  root:dispatch("key", keys.enter, false)
  eq(opened, DIR .. "/readme.txt")
  -- new folder through the dialog
  clickWidget(root, findButton(root, "New"))
  for c in ("fresh"):gmatch(".") do root:dispatch("char", c) end
  root:dispatch("key", keys.enter, false)
  ok(fs.isDir(DIR .. "/fresh"))
  -- rename it
  selectName("fresh/")
  clickWidget(root, findButton(root, "Rename"))
  local input = root.focused
  input:setText("renamed")
  root:dispatch("key", keys.enter, false)
  ok(fs.isDir(DIR .. "/renamed") and not fs.exists(DIR .. "/fresh"))
  -- delete with confirmation: "No" keeps it, "Yes" removes it
  selectName("renamed/")
  clickWidget(root, findButton(root, "Delete"))
  clickWidget(root, findButton(root, "No"))
  ok(fs.exists(DIR .. "/renamed"))
  clickWidget(root, findButton(root, "Delete"))
  clickWidget(root, findButton(root, "Yes"))
  ok(not fs.exists(DIR .. "/renamed"))
  -- typing a path jumps there; a bad path reports an error
  app.go("/not-a-folder-xyz")
  ok(app.status.text:find("not a folder", 1, true))
  eq(app.state.path, DIR)
end)

test("settings: appearance applies and saves the theme", function()
  local config = require("tsr.config")
  config.reset()
  config.paths.system = "/tmp-gui/system.cfg"
  fresh()
  local root = newRoot(50, 14)
  local fakeDesktop = { t = screen(50, 14), wm = { list = function() return {} end, tick = function() end } }
  local app = settings.build(root, {}, fakeDesktop, { config = config })
  root:render()
  ok(text(root.t):find("Theme", 1, true) and text(root.t):find("light", 1, true), text(root.t))
  -- choose "light" in the theme list
  local list = app.ctx.area.children[2]
  for i, item in ipairs(list.items) do if item.name == "light" then list:select(i) end end
  eq(config.get("ui.theme"), "light")
  eq(theme.currentName, "light")
  ok(app.ctx.message.text:find("light", 1, true))
  -- boot checkbox
  local box
  for _, c in ipairs(app.ctx.area.children) do if c.text == "Start the desktop at boot" then box = c end end
  box:toggle()
  eq(config.get("ui.default"), "gui")
  box:toggle()
  eq(config.get("ui.default"), "shell")
  theme.set("dark", true)
end)

test("settings: system page validates the computer name; services page lists services", function()
  local config = require("tsr.config")
  config.reset()
  config.paths.system = "/tmp-gui/system.cfg"
  fresh()
  local root = newRoot(50, 14)
  local app = settings.build(root, {}, nil, { config = config })
  app.show("System")
  local area = app.ctx.area
  local input, save
  for _, c in ipairs(area.children) do
    if c.cursorPos then input = c end
    if c.text == "Save" then save = c end
  end
  input:setText("bad name!")
  save:click()
  ok(app.ctx.message.text:find("letters", 1, true))
  input:setText("hub-1")
  save:click()
  eq(config.get("net.hostname"), "hub-1")
  -- services
  local svc = require("tsr.svc")
  svc.reset()
  svc.dir = DIR .. "/none"
  svc.statePath = DIR .. "/svc.state"
  svc.define({ name = "demo", description = "d", run = function() while true do os.pullEvent("nothing") end end })
  local K = require("tsr.kernel")
  K.reset()
  K.init({ term = screen(20, 5) })
  app.show("Services")
  root:render()
  ok(text(root.t):find("demo", 1, true), text(root.t))
  local list = app.ctx.area.children[1]
  list:select(1)
  findButton(root, "start"):click()
  eq(svc.status("demo").state, "running")
  ok(text(root.t) ~= "")
  findButton(root, "stop"):click()
  eq(svc.status("demo").state, "stopped")
  svc.reset()
  app.show("About")
  root:render()
  ok(text(root.t):find("Tessera", 1, true))
end)

--- A fake package manager for the store.
local function fakePkg()
  local p = { installed = {}, log = {} }
  local index = {
    { name = "alpha", version = "1.0.0", type = "app", description = "The first package", size = 100 },
    { name = "beta", version = "2.0.0", type = "lib", description = "A library", size = 50 },
  }
  function p.search(q)
    local out = {}
    for _, e in ipairs(index) do if q == "" or e.name:find(q, 1, true) or e.description:lower():find(q:lower(), 1, true) then out[#out + 1] = e end end
    return out
  end
  function p.installPackages(names, opts) p.log[#p.log + 1] = "install " .. names[1] return names[1] ~= "beta" or nil, "beta cannot be installed\nsecond line" end
  function p.remove(names) p.log[#p.log + 1] = "remove " .. names[1] return true end
  function p.update() p.log[#p.log + 1] = "update" return { main = true, backup = "HTTP 404" } end
  function p.upgrade() p.log[#p.log + 1] = "upgrade" return true end
  return p
end

test("store: list, filter, install, remove, update", function()
  testenv.reset()
  local db = require("tsr.pkg.db")
  db.set("alpha", { version = "0.9.0", files = {} })
  db.save()
  local pkg = fakePkg()
  local root = newRoot(46, 16)
  local app = store.build(root, {}, nil, { pkg = pkg })
  root:render()
  local t = text(root.t)
  ok(t:find("alpha", 1, true) and t:find("beta", 1, true), t)
  ok(t:find("^ ") == nil)
  eq(app.list.items[1].text:sub(1, 1), "^", "alpha has an update available")
  eq(app.list.items[2].text:sub(1, 1), " ")
  eq(app.detail.text, "The first package")
  -- filter
  app.search:focus()
  for c in ("lib"):gmatch(".") do root:dispatch("char", c) end
  eq(#app.list.items, 1)
  eq(app.list.items[1].row.name, "beta")
  app.search:setText("")
  app.search.onChange("")
  eq(#app.list.items, 2)
  -- install the selected package
  app.list:select(1)
  clickWidget(root, findButton(root, "Install"))
  eq(pkg.log[#pkg.log], "install alpha")
  ok(app.status.text:find("Installed alpha", 1, true))
  -- failures show the first line of the message
  app.list:select(2)
  clickWidget(root, findButton(root, "Install"))
  eq(app.status.text, "beta cannot be installed")
  -- remove only works on installed packages
  clickWidget(root, findButton(root, "Remove"))
  ok(pkg.log[#pkg.log] ~= "remove beta")
  app.list:select(1)
  clickWidget(root, findButton(root, "Remove"))
  eq(pkg.log[#pkg.log], "remove alpha")
  clickWidget(root, findButton(root, "Refresh"))
  ok(app.status.text:find("backup", 1, true), app.status.text)
  clickWidget(root, findButton(root, "Upgrade all"))
  eq(pkg.log[#pkg.log], "upgrade")
  db.remove("alpha")
  db.save()
end)

test("task manager lists processes and ends tasks", function()
  local ended = {}
  local alive = { [1] = true, [2] = true, [3] = true }
  local kernel = {
    list = function()
      local out = {}
      for pid in pairs(alive) do out[#out + 1] = { pid = pid, name = "proc" .. pid, session = pid == 1 } end
      table.sort(out, function(a, b) return a.pid < b.pid end)
      return out
    end,
    current = function() return 1 end,
    terminate = function(pid) ended[#ended + 1] = pid alive[pid] = nil end,
    kill = function() end, get = function(pid) return alive[pid] and {} or nil end,
  }
  local root = newRoot(40, 12)
  local win = {}
  local app = taskman.build(root, win, nil, { kernel = kernel })
  root:render()
  ok(text(root.t):find("proc2", 1, true))
  app.list:select(1)
  clickWidget(root, findButton(root, "End task"))
  eq(#ended, 0)
  ok(app.status.text:find("cannot end itself", 1, true))
  app.list:select(2)
  clickWidget(root, findButton(root, "End task"))
  eq(ended, { 2 })
  eq(#app.list.items, 2)
  alive[9] = true
  win.onTick()
  eq(#app.list.items, 3, "the periodic refresh picks up new processes")
end)

test("the gui command", function()
  local config = require("tsr.config")
  config.reset()
  config.paths.system = "/tmp-gui/system.cfg"
  fresh()
  local function run(...)
    local io = { said = {}, errs = {} }
    function io.say(t) io.said[#io.said + 1] = t end
    function io.err(t) io.errs[#io.errs + 1] = t end
    local r = gui.run({ ... }, io, config)
    return r, table.concat(io.said, "\n"), table.concat(io.errs, "\n")
  end
  local r, out = run("status")
  ok(r and out:find("at boot: shell", 1, true), out)
  ok(run("enable"))
  eq(config.get("ui.default"), "gui")
  ok(run("disable"))
  eq(config.get("ui.default"), "shell")
  ok(run("theme", "light"))
  eq(config.get("ui.theme"), "light")
  local bad, _, err = run("theme", "pink")
  ok(bad == false and err:find("dark", 1, true))
  eq(run("bogus"), false)
end)
