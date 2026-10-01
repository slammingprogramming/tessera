-- SPDX-License-Identifier: AGPL-3.0-or-later
local theme = require("tsr.gui.theme")
local W = require("tsr.gui.widgets")
local WM = require("tsr.gui.wm")
local desktop = require("tsr.gui.desktop")

local function screen(w, h) return window.create(term.current(), 1, 1, w or 40, h or 12, false) end

local function row(t, y) return (t.getLine(y)) end
local function text(t)
  local w, h = t.getSize()
  local out = {}
  for y = 1, h do out[y] = (t.getLine(y):gsub("%s+$", "")) end
  return table.concat(out, "\n")
end

local function newRoot(w, h)
  theme.set("dark", true)
  local t = screen(w, h)
  return W.root(t), t
end

local function click(root, x, y, button)
  root:dispatch("mouse_click", button or 1, x, y)
  root:dispatch("mouse_up", button or 1, x, y)
end

test("themes: colour terminals choose, grey-scale ones are always mono", function()
  eq(theme.resolve("light", true), "light")
  eq(theme.resolve("nonsense", true), "dark")
  eq(theme.resolve("light", false), "mono")
  eq(theme.set("contrast", true), "contrast")
  eq(theme.get().desktop, colors.black)
  for _, name in ipairs(theme.order) do
    for _, role in ipairs({ "desktop", "text", "window", "titleActive", "button", "selection", "taskbar" }) do
      ok(theme.themes[name][role], name .. "." .. role)
    end
  end
  for role, c in pairs(theme.themes.mono) do
    ok(c == colors.black or c == colors.white or c == colors.gray or c == colors.lightGray, "mono." .. role .. " must be a grey")
  end
  theme.set("dark", true)
end)

test("text wrapping", function()
  eq(W.wrap("hello world foo", 11), { "hello world", "foo" })
  eq(W.wrap("a\n\nb", 10), { "a", "", "b" })
  eq(W.wrap("abcdefghij", 4), { "abcd", "efgh", "ij" })
  eq(W.wrap("", 5), {})
end)

test("labels and panels draw", function()
  local root, t = newRoot(30, 8)
  local panel = root:add(W.panel({ x = 1, y = 1, w = 20, h = 5, title = "Box" }))
  panel:add(W.label({ x = 1, y = 1, text = "Hello" }))
  root:render()
  eq(row(t, 1):sub(1, 7), "+- Box ")
  ok(row(t, 2):sub(1, 8) == "|Hello  ", row(t, 2))
  eq(row(t, 5):sub(1, 4), "+---")
  local ax, ay = panel.children[1]:abs()
  eq({ ax, ay }, { 2, 2 })
end)

test("buttons click with the mouse and the keyboard, and not when disabled", function()
  local root, t = newRoot(30, 6)
  local n = 0
  local b = root:add(W.button({ x = 3, y = 2, text = "Go", onClick = function() n = n + 1 end }))
  root:render()
  eq(row(t, 2):sub(3, 6), " Go ")
  click(root, 4, 2)
  eq(n, 1)
  -- released outside: no click
  root:dispatch("mouse_click", 1, 4, 2)
  root:dispatch("mouse_up", 1, 10, 4)
  eq(n, 1)
  b:focus()
  root:dispatch("key", keys.enter, false)
  root:dispatch("key", keys.space, false)
  eq(n, 3)
  b.enabled = false
  click(root, 4, 2)
  root:dispatch("key", keys.enter, false)
  eq(n, 3)
end)

test("checkboxes toggle", function()
  local root, t = newRoot(30, 4)
  local seen
  local c = root:add(W.checkbox({ x = 1, y = 1, text = "Enable", onChange = function(v) seen = v end }))
  root:render()
  eq(row(t, 1):sub(1, 10), "[ ] Enable")
  click(root, 2, 1)
  eq({ c.checked, seen }, { true, true })
  root:render()
  eq(row(t, 1):sub(1, 3), "[x]")
  c:focus()
  root:dispatch("key", keys.space, false)
  eq(c.checked, false)
end)

test("text input: typing, editing keys, paste, scrolling, submit", function()
  local root, t = newRoot(30, 4)
  local changes, submitted = {}, nil
  local i = root:add(W.input({ x = 1, y = 1, w = 8, onChange = function(v) changes[#changes + 1] = v end,
                               onSubmit = function(v) submitted = v end }))
  i:focus()
  for c in ("hello"):gmatch(".") do root:dispatch("char", c) end
  eq(i.text, "hello")
  root:dispatch("key", keys.left, false)
  root:dispatch("key", keys.left, false)
  root:dispatch("char", "X")
  eq(i.text, "helXlo")
  root:dispatch("key", keys.backspace, false)
  eq(i.text, "hello")
  root:dispatch("key", keys.delete, false)
  eq(i.text, "helo")
  root:dispatch("key", keys.home, false)
  root:dispatch("char", ">")
  eq(i.text, ">helo")
  root:dispatch("key", keys["end"], false)
  root:dispatch("paste", "a\nb")
  eq(i.text, ">helo" .. "a b")
  -- scrolling keeps the cursor visible
  root:render()
  eq(#row(t, 1), 30)
  local cx = i:cursorPos()
  ok(cx >= 1 and cx <= 8, "cursor inside the field: " .. cx)
  root:dispatch("key", keys.enter, false)
  eq(submitted, ">heloa b")
  ok(#changes >= 5)
  -- backspace at the start does nothing
  i.cursor = 0
  root:dispatch("key", keys.backspace, false)
  eq(i.text, ">heloa b")
  -- secret fields never show their text; maxLength is enforced
  local s = root:add(W.input({ x = 1, y = 2, w = 8, secret = true, text = "abc", maxLength = 4 }))
  s:focus()
  root:dispatch("char", "d")
  root:dispatch("char", "e")
  eq(s.text, "abcd")
  root:render()
  ok(row(t, 2):sub(1, 4) == "****" and not row(t, 2):find("a"), row(t, 2))
  -- click sets the cursor
  i:focus()
  click(root, 3, 1)
  eq(i.cursor, 2)
end)

test("lists: keyboard, mouse, wheel, double click, scrolling", function()
  local root, t = newRoot(30, 6)
  local items = {}
  for n = 1, 10 do items[n] = "item " .. n end
  local activated, selected = nil, nil
  local l = root:add(W.list({ x = 1, y = 1, w = 14, h = 4, items = items,
                              onActivate = function(i) activated = i end, onSelect = function(i) selected = i end }))
  l:focus()
  root:render()
  eq(row(t, 1):sub(1, 8), " item 1 ")
  root:dispatch("key", keys.down, false)
  root:dispatch("key", keys.down, false)
  eq({ l.selected, selected }, { 3, 3 })
  for _ = 1, 4 do root:dispatch("key", keys.down, false) end
  eq(l.selected, 7)
  ok(l.top > 1, "scrolled to keep the selection visible")
  root:render()
  ok(text(t):find("item 7", 1, true))
  root:dispatch("key", keys.home, false)
  eq({ l.selected, l.top }, { 1, 1 })
  root:dispatch("key", keys["end"], false)
  eq(l.selected, 10)
  root:dispatch("key", keys.pageUp, false)
  eq(l.selected, 6)
  root:dispatch("mouse_scroll", 1, 3, 2)
  root:dispatch("mouse_scroll", -1, 3, 2)
  click(root, 3, 2)
  eq(l.selected, l.top + 1)
  root:dispatch("key", keys.enter, false)
  eq(activated, l.selected)
  -- double click activates
  activated = nil
  root:dispatch("mouse_click", 1, 3, 3)
  root:dispatch("mouse_up", 1, 3, 3)
  root:dispatch("mouse_click", 1, 3, 3)
  root:dispatch("mouse_up", 1, 3, 3)
  eq(activated, l.top + 2)
  -- a scrollbar column appears only when there is more than fits
  l:setItems({ "a", "b" })
  eq(l.selected, 1)
  eq(l:selectedItem(), "a")
  l:setItems({})
  eq(l.selected, 0)
  root:dispatch("key", keys.down, false)
  eq(l.selected, 0)
end)

test("tab moves focus between widgets", function()
  local root = newRoot(30, 6)
  local a = root:add(W.input({ x = 1, y = 1, w = 5 }))
  local b = root:add(W.button({ x = 1, y = 2, text = "B" }))
  local c = root:add(W.checkbox({ x = 1, y = 3, text = "C" }))
  root:dispatch("key", keys.tab, false)
  ok(root.focused == a)
  root:dispatch("key", keys.tab, false)
  ok(root.focused == b)
  root:dispatch("key", keys.tab, false)
  root:dispatch("key", keys.tab, false)
  ok(root.focused == a, "wraps around")
  root:dispatch("key", keys.leftShift, false)
  root:dispatch("key", keys.tab, false)
  ok(root.focused == c, "shift+tab goes backwards")
  root:dispatch("key_up", keys.leftShift)
end)

test("progress bars", function()
  local root, t = newRoot(20, 3)
  root:add(W.progress({ x = 1, y = 1, w = 10, value = 0.5 }))
  root:add(W.progress({ x = 1, y = 2, w = 10, value = 2, text = "full" }))
  root:render()
  eq(row(t, 1):sub(1, 10):gsub("%s", ""), "50%")
  local _, _, bg = t.getLine(1)
  local th = theme.get()
  eq(bg:sub(1, 1), colors.toBlit(th.accent))
  eq(bg:sub(10, 10), colors.toBlit(th.border))
  local _, _, bg2 = t.getLine(2)
  eq(bg2:sub(10, 10), colors.toBlit(th.accent), "values clamp to 100%")
end)

test("dialogs show a message and report the choice", function()
  local root, t = newRoot(40, 12)
  local choice
  local dlg = W.dialog(root, { title = "Delete?", text = "Really delete this file?", buttons = { "Yes", "No" }, onChoice = function(c) choice = c end })
  root:render()
  ok(text(t):find("Really delete", 1, true) and text(t):find("Yes", 1, true))
  local no = dlg.children[3]
  local ax, ay = no:abs()
  click(root, ax + 1, ay)
  eq(choice, "No")
  eq(#root.children, 0, "the dialog removed itself")
end)

--- A fake kernel recording what the window manager asks of it.
local function fakeKernel()
  local k = { sent = {}, spawned = {}, killed = {}, alive = {}, nextPid = 100 }
  function k.spawn(spec)
    local pid = k.nextPid
    k.nextPid = pid + 1
    k.spawned[pid] = spec
    k.alive[pid] = true
    if spec.fn then spec.fn() end
    return pid
  end
  function k.send(pid, ...) k.sent[#k.sent + 1] = table.pack(pid, ...) return k.alive[pid] == true end
  function k.terminate(pid) k.alive[pid] = nil k.killed[#k.killed + 1] = pid end
  function k.kill(pid) k.alive[pid] = nil end
  function k.get(pid) return k.alive[pid] and {} or nil end
  return k
end

test("window manager: open, compose, focus, raise, close", function()
  theme.set("dark", true)
  local scr = screen(40, 14)
  local wm = WM.new({ term = scr, kernel = fakeKernel() })
  local a = wm:open({ title = "Alpha", w = 16, h = 4, x = 2, y = 3, build = function(root) root:add(W.label({ x = 1, y = 1, text = "I am A" })) end })
  local b = wm:open({ title = "Beta", w = 16, h = 4, x = 10, y = 5, build = function(root) root:add(W.label({ x = 1, y = 1, text = "I am B" })) end })
  wm:tick(true)
  ok(wm.focused == b and wm.windows[#wm.windows] == b)
  local s = text(scr)
  ok(s:find("Alpha", 1, true) and s:find("Beta", 1, true))
  ok(row(scr, 3):sub(2, 7) == "I am A", row(scr, 3))
  -- B overlaps A: the part of A under B is hidden
  ok(row(scr, 5):sub(10, 15) == "I am B", row(scr, 5))
  -- clicking A raises it
  wm:event("mouse_click", 1, 3, 3)
  wm:event("mouse_up", 1, 3, 3)
  ok(wm.focused == a and wm.windows[#wm.windows] == a)
  -- closing removes the window and focus falls back
  ok(wm:close(a))
  ok(wm.focused == b)
  eq(#wm:list(), 1)
  ok(not wm:close(999))
end)

test("window manager: dragging by the title bar, maximize and minimize", function()
  theme.set("dark", true)
  local scr = screen(40, 14)
  local wm = WM.new({ term = scr, kernel = fakeKernel() })
  local w = wm:open({ title = "Mover", w = 14, h = 4, x = 5, y = 4, build = function() end })
  wm:event("mouse_click", 1, 8, 3)          -- title bar is one row above the content
  wm:event("mouse_drag", 1, 12, 5)
  wm:event("mouse_up", 1, 12, 5)
  eq({ w.x, w.y }, { 9, 6 })
  -- double click on the title maximises, again restores
  wm:event("mouse_click", 1, 12, 5)
  wm:event("mouse_up", 1, 12, 5)
  wm:event("mouse_click", 1, 12, 5)
  ok(w.maximized)
  eq({ w.x, w.w }, { 1, 40 })
  wm:toggleMaximize(w)
  eq({ w.x, w.y, w.w, w.h }, { 9, 6, 14, 4 })
  -- the title bar buttons
  local start = w.x + w.w - 7
  wm:event("mouse_click", 1, start + 1, w.y - 1)     -- " _ + x ": minimize is the 2nd cell
  ok(w.minimized)
  wm:focus(w)
  ok(not w.minimized)
  wm:event("mouse_click", 1, start + 5, w.y - 1)     -- close
  eq(#wm:list(), 0)
  -- windows cannot be dragged off the top
  local w2 = wm:open({ title = "Top", w = 14, h = 4, x = 5, y = 4, build = function() end })
  wm:event("mouse_click", 1, 8, 3)
  wm:event("mouse_drag", 1, 8, -10)
  wm:event("mouse_up", 1, 8, -10)
  ok(w2.y >= 2)
end)

test("window manager forwards translated events to widgets and processes", function()
  theme.set("dark", true)
  local scr = screen(40, 14)
  local k = fakeKernel()
  local wm = WM.new({ term = scr, kernel = k })
  local clicked
  local wid = wm:open({ title = "Widgets", w = 16, h = 4, x = 3, y = 3, build = function(root)
    root:add(W.button({ x = 2, y = 2, text = "Hit", onClick = function() clicked = true end }))
  end })
  wm:event("mouse_click", 1, 3 + 2, 3 + 1)      -- screen coords of the button
  wm:event("mouse_up", 1, 3 + 2, 3 + 1)
  ok(clicked)
  local proc = wm:open({ title = "Proc", w = 16, h = 4, x = 20, y = 5, run = function() end })
  ok(proc.pid)
  wm:event("mouse_click", 2, 22, 6)
  wm:event("mouse_up", 2, 22, 6)
  wm:event("char", "x")
  wm:event("key", keys.enter, false)
  local names = {}
  for _, s in ipairs(k.sent) do names[#names + 1] = s[2] end
  eq(names, { "mouse_click", "mouse_up", "char", "key" })
  eq({ k.sent[1][3], k.sent[1][4], k.sent[1][5] }, { 2, 3, 2 }, "button, then coordinates relative to the window")
  eq(k.sent[3][1], proc.pid)
  -- a terminate goes to the focused process
  wm:event("terminate")
  eq(k.sent[#k.sent][2], "terminate")
  -- a process that exits closes its window
  local procPid = proc.pid
  k.alive[procPid] = nil
  wm:event("tsr_proc_exit", procPid, true)
  ok(wm:findByPid(procPid) == nil)
  ok(not wm:find(proc.id))
  -- closing a process window terminates its process
  local p2 = wm:open({ title = "P2", w = 16, h = 4, run = function() end })
  local pid2 = p2.pid
  wm:close(p2)
  eq(k.killed[#k.killed], pid2)
end)

test("window manager shows the cursor of the focused window", function()
  theme.set("dark", true)
  local scr = screen(40, 14)
  local wm = WM.new({ term = scr, kernel = fakeKernel() })
  local w = wm:open({ title = "Cursor", w = 16, h = 4, x = 4, y = 4, build = function() end })
  w.term.setCursorPos(3, 2)
  w.term.setCursorBlink(true)
  wm:tick(true)
  eq({ scr.getCursorPos() }, { 4 + 2, 4 + 1 })
  ok(scr.getCursorBlink())
  w.term.setCursorBlink(false)
  wm:tick()
  ok(not scr.getCursorBlink())
end)

test("tick only recomposes when something changed", function()
  theme.set("dark", true)
  local scr = screen(40, 14)
  local wm = WM.new({ term = scr, kernel = fakeKernel() })
  local w = wm:open({ title = "Quiet", w = 16, h = 4, build = function() end })
  ok(wm:tick())
  ok(not wm:tick())
  w.term.setCursorPos(1, 1)
  w.term.write("changed")
  ok(wm:tick())
end)

test("the desktop launches apps from the start menu and shows a taskbar", function()
  theme.set("dark", true)
  local scr = screen(51, 19)
  local opened = {}
  local apps = {
    { id = "hello", name = "Hello", w = 20, h = 5, build = function(root) opened[#opened + 1] = "hello" root:add(W.label({ x = 1, y = 1, text = "Hello app" })) end },
    { id = "proc", name = "Proc", run = function() opened[#opened + 1] = "proc" end },
  }
  local d = desktop.new({ term = scr, kernel = fakeKernel(), apps = apps, now = function() return "12:34" end })
  d.wm:tick(true)
  local last = row(scr, 19)
  ok(last:find("Tessera", 1, true) and last:find("12:34", 1, true), last)
  -- open the menu
  d:event("mouse_click", 1, 3, 19)
  ok(d.menuOpen)
  d.wm:tick(true)
  ok(text(scr):find("Hello", 1, true) and text(scr):find("Shut down", 1, true))
  -- click "Hello" (first item row is menu y + 1)
  local r = d:menuRect()
  d:event("mouse_click", 1, 3, r.y + 1)
  ok(not d.menuOpen)
  eq(opened, { "hello" })
  local win = d.wm.focused
  eq(win.title, "Hello")
  d.wm:tick(true)
  ok(row(scr, 19):find("Hello", 1, true), "window button on the taskbar")
  -- taskbar button minimises the focused window, then restores it
  local tb = d.taskButtons[1]
  d:event("mouse_click", 1, tb.x1 + 1, 19)
  ok(win.minimized)
  d:event("mouse_click", 1, tb.x1 + 1, 19)
  ok(not win.minimized)
  -- the menu closes with escape or an outside click
  d:setMenu(true)
  d:event("key", keys.escape)
  ok(not d.menuOpen)
  -- exit actions
  d:setMenu(true)
  r = d:menuRect()
  local items = r.items
  local idx
  for i, it in ipairs(items) do if it.action == "logout" then idx = i end end
  d:event("mouse_click", 1, 3, r.y + idx)
  eq(d.exitAction, "logout")
end)

test("application files are loaded in order", function()
  local dir = "/tmp-gui-apps"
  if fs.exists(dir) then fs.delete(dir) end
  fs.makeDir(dir)
  local function put(name, body)
    local h = fs.open(dir .. "/" .. name, "w")
    h.write(body)
    h.close()
  end
  put("b.lua", [[return { name = "Beta", order = 20, program = "echo b" }]])
  put("a.lua", [[return { name = "Alpha", order = 20, run = function() end }]])
  put("first.lua", [[return { name = "Zeta", order = 1, build = function() end }]])
  put("broken.lua", "return {")
  put("noaction.lua", [[return { name = "Nothing" }]])
  put("readme.txt", "x")
  local d = desktop.new({ term = screen(40, 12), kernel = fakeKernel(), apps = {} })
  eq(d:loadApps(dir), 3)
  eq({ d.apps[1].name, d.apps[2].name, d.apps[3].name }, { "Zeta", "Alpha", "Beta" })
  ok(d:launchByName("Alpha"))
  local missing, err = d:launchByName("Ghost")
  ok(missing == nil and err:find("no such application"))
end)

test("the real desktop and widgets compile and the shipped apps load", function()
  local d = desktop.new({ term = screen(51, 19), kernel = fakeKernel() })
  ok(#d.apps >= 4, "shipped applications: " .. #d.apps)
  for _, app in ipairs(d.apps) do ok(app.name and (app.build or app.run or app.program), app.id) end
end)

test("with the real kernel: a program runs in a window and gets keys and clicks", function()
  theme.set("dark", true)
  local K = require("tsr.kernel")
  K.reset()
  local scr = screen(51, 19)
  K.init({ term = scr })
  local got = {}
  local d = desktop.new({ term = scr, kernel = K, apps = {
    { id = "probe", name = "Probe", w = 24, h = 6, run = function()
      print("probe ready")
      while true do
        local ev = table.pack(os.pullEvent())
        if ev[1] == "char" or ev[1] == "mouse_click" then
          got[#got + 1] = ev[1] .. ":" .. tostring(ev[2]) .. (ev[3] and ("," .. ev[3] .. "," .. ev[4]) or "")
        elseif ev[1] == "terminate" then return end
      end
    end },
  } })
  local win
  K.spawn({ name = "desk", window = false, focus = true, fn = function()
    win = d:launchByName("Probe")
    d.wm:tick(true)
    ok(row(win.term, 1):find("probe ready", 1, true), row(win.term, 1))
    ok(text(scr):find("probe ready", 1, true), "composed onto the screen")
    d:event("char", "q")
    d:event("mouse_click", 1, win.x + 3, win.y + 2)
    d:event("mouse_up", 1, win.x + 3, win.y + 2)
    -- closing the window ends the process
    local pid = win.pid
    d.wm:close(win)
    ok(K.get(pid) == nil, "process is gone")
    K.stop("craftos")
  end })
  K.run()
  eq(got, { "char:q", "mouse_click:1,4,3" })
end)
