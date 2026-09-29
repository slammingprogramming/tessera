-- SPDX-License-Identifier: AGPL-3.0-or-later
local tui = require("tsr.ui.tui")

--- Run fn with `term` redirected to a window of the given size; returns fn's results plus the window.
local function withScreen(w, h, fn)
  local win = window.create(term.current(), 1, 1, w, h, false)
  local prev = term.redirect(win)
  local res = table.pack(pcall(fn))
  term.redirect(prev)
  if not res[1] then error(res[2], 0) end
  return win, table.unpack(res, 2, res.n)
end

local function screenText(win)
  local w, h = win.getSize()
  local lines = {}
  for y = 1, h do lines[#lines + 1] = win.getLine(y) end
  return table.concat(lines, "\n")
end

local function key(k) os.queueEvent("key", k, false) end
local function char(c) os.queueEvent("char", c) end

test("fit and wrap", function()
  eq(tui.fit("abc", 5), "abc  ")
  eq(tui.fit("abcdefgh", 5), "abc..")
  eq(#tui.fit("x", 10), 10)
  eq(tui.wrap("the quick brown fox", 10), { "the quick", "brown fox" })
  eq(tui.wrap("supercalifragilistic", 8), { "supercal", "ifragili", "stic" })
  eq(tui.wrap("a\n\nb", 10), { "a", "", "b" })
end)

test("menu: arrows and enter", function()
  local items = { { label = "One" }, { label = "Two", desc = "second choice" }, { label = "Three" } }
  key(keys.down)
  key(keys.enter)
  local win, sel
  win, sel = withScreen(30, 12, function() return tui.menu("Pick", items) end)
  eq(sel, 2)
  local text = screenText(win)
  ok(text:find("Pick", 1, true) and text:find("One", 1, true) and text:find("second choice", 1, true), text)
end)

test("menu: disabled items are skipped and cannot be chosen", function()
  local items = { { label = "A" }, { label = "B", disabled = true }, { label = "C" } }
  key(keys.down)
  key(keys.enter)
  local _, sel = withScreen(30, 12, function() return tui.menu("T", items) end)
  eq(sel, 3)
end)

test("menu: number shortcut, backspace cancels, wrap-around", function()
  local items = { { label = "A" }, { label = "B" }, { label = "C" } }
  char("2")
  local _, sel = withScreen(30, 12, function() return tui.menu("T", items) end)
  eq(sel, 2)
  key(keys.backspace)
  local _, cancelled = withScreen(30, 12, function() return tui.menu("T", items) end)
  eq(cancelled, nil)
  key(keys.up)
  key(keys.enter)
  local _, wrapped = withScreen(30, 12, function() return tui.menu("T", items) end)
  eq(wrapped, 3)
end)

test("menu: scrolls long lists and End selects the last item", function()
  local items = {}
  for i = 1, 30 do items[i] = { label = "Item " .. i } end
  key(keys["end"])
  key(keys.enter)
  local win, sel = withScreen(30, 10, function() return tui.menu("Long", items) end)
  eq(sel, 30)
  ok(screenText(win):find("Item 30", 1, true))
  ok(not screenText(win):find("Item 1 ", 1, true))
end)

test("menu: mouse click selects a row", function()
  local items = { { label = "First" }, { label = "Second" }, { label = "Third" } }
  os.queueEvent("mouse_click", 1, 5, 4) -- header row 1, blank 2, list starts at row 3
  local _, sel = withScreen(30, 12, function() return tui.menu("T", items) end)
  eq(sel, 2)
end)

test("checklist: space toggles, a/n set all, initial state respected", function()
  local items = { { id = "a", label = "A" }, { id = "b", label = "B" }, { id = "c", label = "C", disabled = true } }
  key(keys.space)            -- toggles A off (it starts checked)
  key(keys.down)
  key(keys.space)            -- toggles B on
  key(keys.enter)
  local _, res = withScreen(30, 12, function() return tui.checklist("T", items, { checked = { a = true } }) end)
  eq(res, { a = false, b = true, c = false })
  char("a")
  key(keys.enter)
  local _, all = withScreen(30, 12, function() return tui.checklist("T", items) end)
  eq(all, { a = true, b = true, c = false }, "'a' must not tick disabled items")
  char("n")
  key(keys.enter)
  local _, none = withScreen(30, 12, function() return tui.checklist("T", items, { checked = { a = true, b = true } }) end)
  eq(none, { a = false, b = false, c = false })
  key(keys.backspace)
  local _, back = withScreen(30, 12, function() return tui.checklist("T", items) end)
  eq(back, nil)
end)

test("confirm: keys", function()
  char("y")
  local _, a = withScreen(30, 12, function() return tui.confirm("Q", { "Sure?" }) end)
  eq(a, true)
  char("n")
  local _, b = withScreen(30, 12, function() return tui.confirm("Q", { "Sure?" }) end)
  eq(b, false)
  key(keys.right)
  key(keys.enter)
  local _, c = withScreen(30, 12, function() return tui.confirm("Q", { "Sure?" }) end)
  eq(c, false, "default yes, moved to no")
  key(keys.enter)
  local _, d = withScreen(30, 12, function() return tui.confirm("Q", "Sure?", { default = false }) end)
  eq(d, false)
end)

test("message waits for a key and shows its text", function()
  key(keys.enter)
  local win = withScreen(30, 8, function() tui.message("Hello", { "First line", "Second line" }) end)
  local text = screenText(win)
  ok(text:find("Hello", 1, true) and text:find("First line", 1, true) and text:find("Second line", 1, true))
end)

test("Ctrl+T aborts a screen with Terminated", function()
  os.queueEvent("terminate")
  local ok2, err = pcall(function()
    withScreen(30, 8, function() return tui.menu("T", { { label = "A" } }) end)
  end)
  eq(ok2, false)
  eq(err, "Terminated")
end)

test("progress bar draws proportionally", function()
  local win = withScreen(22, 6, function()
    tui.frame("Work")
    tui.bar(3, 0.5, "half")
  end)
  local line = win.getLine(3)
  ok(line:sub(1, 1) == "[" and line:sub(22, 22) == "]", line)
  ok(win.getLine(4):find("half", 1, true))
end)

test("works on small pocket-sized screens", function()
  local items = {}
  for i = 1, 8 do items[i] = { label = "A long option label number " .. i, desc = "some description text for " .. i } end
  key(keys.down)
  key(keys.enter)
  local win, sel = withScreen(26, 20, function() return tui.menu("Pocket", items) end)
  eq(sel, 2)
  ok(screenText(win):find("Pocket", 1, true))
end)
