-- SPDX-License-Identifier: AGPL-3.0-or-later
local fm = require("tsr.utils.fm")
local repl = require("tsr.utils.repl")

local DIR = "/tmp-utils"

local function put(path, text)
  local h = fs.open(path, "w")
  h.write(text)
  h.close()
end

local function fresh()
  if fs.exists(DIR) then fs.delete(DIR) end
  fs.makeDir(DIR .. "/docs")
  put(DIR .. "/b.txt", "bbbb")
  put(DIR .. "/a.txt", "a")
  put(DIR .. "/docs/x.lua", "return 1")
end

test("fm model: listing and file operations", function()
  fresh()
  local list = fm.entries(DIR)
  eq({ list[1].name, list[2].name, list[3].name }, { "docs", "a.txt", "b.txt" })
  eq(list[3].size, 4)
  ok(fm.copy(DIR .. "/a.txt", DIR .. "/c.txt"))
  eq(({ fm.copy(DIR .. "/a.txt", DIR .. "/c.txt") })[2], "the destination already exists")
  ok(fm.move(DIR .. "/c.txt", DIR .. "/d.txt"))
  ok(fs.exists(DIR .. "/d.txt") and not fs.exists(DIR .. "/c.txt"))
  ok(fm.rename(DIR .. "/d.txt", "e.txt"))
  ok(fs.exists(DIR .. "/e.txt"))
  eq(fm.rename(DIR .. "/e.txt", "a/b"), nil)
  ok(fm.mkdir(DIR, "newdir"))
  eq(fm.mkdir(DIR, "newdir"), nil)
  eq(fm.mkdir(DIR, ".."), nil)
  ok(fm.delete(DIR .. "/e.txt"))
  for _, p in ipairs({ "/", "/rom", "/rom/programs" }) do eq(fm.delete(p), nil, p) end
  eq(fm.move("/rom/programs", DIR .. "/x"), nil)
  local info = fm.info(DIR .. "/b.txt")
  ok(info[1]:find("b.txt", 1, true) and info[2] == "Size: 4B")
  local folder = fm.info(DIR .. "/docs")
  ok(folder[2]:find("1 files", 1, true), folder[2])
  eq(fm.human(1500), "1.5k")
end)

--- A scripted stand-in for the text UI: `menus` is a queue of functions(title, items) -> index.
local function scriptedUi(menus, answers)
  local ui = { shown = {}, messages = {}, inputs = {}, confirms = {} }
  function ui.menu(title, items)
    ui.shown[#ui.shown + 1] = { title = title, items = items }
    local step = table.remove(menus, 1)
    if not step then return nil end
    if type(step) == "function" then return step(title, items) end
    return step
  end
  function ui.message(title, lines) ui.messages[#ui.messages + 1] = title .. ": " .. table.concat(lines, " ") end
  function ui.input(title, prompt, default) return table.remove(answers or {}, 1) end
  function ui.confirm(title, lines) ui.confirms[#ui.confirms + 1] = title return true end
  return ui
end

local function labelIndex(items, text)
  for i, it in ipairs(items) do if it.label == text then return i end end
  error("no menu item " .. text)
end

test("fm screens: navigate, create, copy and paste, delete", function()
  fresh()
  local menus = {
    function(_, items) return labelIndex(items, "docs/") end,                -- into docs
    function(_, items) return labelIndex(items, "../") end,                  -- back
    function(_, items) return labelIndex(items, "[ New folder ]") end,       -- create
    function(_, items) return labelIndex(items, "a.txt") end,                 -- file actions...
    function(_, items) return labelIndex(items, "Copy") end,                 -- ...copy
    function(_, items) return labelIndex(items, "docs/") end,                -- go into docs
    function(_, items) return labelIndex(items, "[ Paste a.txt here ]") end, -- paste
    function(_, items) return labelIndex(items, "x.lua") end,
    function(_, items) return labelIndex(items, "Delete") end,
    function(_, items) return labelIndex(items, "[ Quit ]") end,
  }
  local ui = scriptedUi(menus, { "made" })
  fm.run({ path = DIR, ui = ui })
  ok(fs.isDir(DIR .. "/made"))
  ok(fs.exists(DIR .. "/docs/a.txt"))
  ok(not fs.exists(DIR .. "/docs/x.lua"))
  ok(fs.exists(DIR .. "/a.txt"), "copy keeps the original")
  eq(ui.shown[1].title, DIR)
  eq(ui.shown[2].title, DIR .. "/docs")
  eq(#ui.confirms, 1)
end)

test("fm: backspace goes up and quits at the top; errors are shown", function()
  fresh()
  local ui = scriptedUi({ function(_, items) return labelIndex(items, "docs/") end, nil, nil })
  fm.run({ path = DIR, ui = ui })
  eq(ui.shown[3].title, DIR, "backspace in docs went up")
  -- an unreadable folder produces a message and does not crash
  local ui2 = scriptedUi({ nil })
  fm.run({ path = "/definitely-not-here", ui = ui2 })
  ok(ui2.messages[1] and ui2.messages[1]:find("Cannot open", 1, true), ui2.messages[1])
  -- an editor hook receives the file
  fresh()
  local opened
  local ui3 = scriptedUi({
    function(_, items) return labelIndex(items, "b.txt") end,
    function(_, items) return labelIndex(items, "Open / edit") end,
    function(_, items) return labelIndex(items, "[ Quit ]") end,
  })
  fm.run({ path = DIR, ui = ui3, edit = function(p) opened = p end })
  eq(opened, DIR .. "/b.txt")
end)

test("repl: evaluates expressions and statements, keeps state", function()
  local out = {}
  local r = repl.new({ write = function(t) out[#out + 1] = t end })
  eq(r.line("1 + 2"), "ok")
  eq(out[#out], "3")
  r.line("x = 40")
  r.line("x + 2")
  eq(out[#out], "42")
  r.line("_ * 2")
  eq(out[#out], "84")
  r.line("{1, 2, a = 'b'}")
  eq(out[#out], '{ 1, 2, a = "b" }')
  r.line("nil")
  eq(out[#out], "nil")
  local before = #out
  r.line("local y = 1")
  eq(#out, before, "statements print nothing")
  r.line("return 1, 'two'")
  eq(out[#out], "1  two")
end)

test("repl: errors are reported and do not stop the session", function()
  local out = {}
  local r = repl.new({ write = function(t) out[#out + 1] = t end })
  eq(r.line("error('boom', 0)"), "error")
  eq(out[#out], "boom")
  eq(r.line("1 +"), "incomplete")
  eq(r.line("x ="), "incomplete")
  eq(r.line("1 + * 2"), "error")
  ok(out[#out]:find("repl", 1, true))
  eq(r.line("nothing.field"), "error")
  eq(r.line("2 + 2"), "ok")
end)

test("repl: multi-line input continues until complete", function()
  local out = {}
  local r = repl.new({ write = function(t) out[#out + 1] = t end })
  local state, code = r.line("for i = 1, 3 do")
  eq(state, "incomplete")
  state, code = r.line("  total = (total or 0) + i", code)
  eq(state, "incomplete")
  state = r.line("end", code)
  eq(state, "ok")
  r.line("total")
  eq(out[#out], "6")
  local s, c = r.line("function f(a)")
  s, c = r.line("return a * 2", c)
  s = r.line("end", c)
  eq(s, "ok")
  r.line("f(21)")
  eq(out[#out], "42")
end)

test("repl: commands, loading files, completion", function()
  fresh()
  put(DIR .. "/lib.lua", "answer = 42")
  local out = {}
  local r = repl.new({ write = function(t) out[#out + 1] = t end, env = { mytable = { alpha = 1, alpine = 2, beta = 3 } } })
  eq(r.line(":load " .. DIR .. "/lib.lua"), "command")
  ok(out[#out]:find("loaded", 1, true))
  r.line("answer")
  eq(out[#out], "42")
  r.line(":load /nope.lua")
  ok(out[#out]:find("no such file", 1, true))
  r.line(":bogus")
  ok(out[#out]:find("unknown command", 1, true))
  r.line(":help")
  ok(out[#out]:find(":quit", 1, true))
  eq(r.complete("mytable.al"), { "pha", "pine" })
  eq(r.complete("mytable.b"), { "eta" })
  ok(#r.complete("mytab") >= 1)
  eq(r.complete("mytable.zzz"), {})
  r.line(":quit")
  ok(r.quit)
end)

test("repl: the run loop uses history and stops at the end of input", function()
  local out = {}
  local r = repl.new({ write = function(t) out[#out + 1] = t end })
  local inputs = { "a = 1", "", "a + 1", "for i=1,2 do", "b = i", "end", "b", ":quit" }
  local i = 0
  local oldWrite = write
  write = function() end
  r.run(function(history) i = i + 1 return inputs[i] end)
  write = oldWrite
  eq(r.history, { "a = 1", "a + 1", "for i=1,2 do", "b", ":quit" }, "empty lines and continuation lines are not history")
  eq(out[#out], "2")
  ok(r.quit)
end)

test("repl: show formats values", function()
  eq(repl.show("text"), "text")
  eq(repl.show({ "a" }), '{ "a" }')
  eq(repl.show({}), "{}")
  eq(repl.show(12), "12")
  eq(repl.show(true), "true")
  ok(repl.show({ a = { b = { c = { d = 1 } } } }):find("{...}", 1, true), "deep tables are cut")
  ok(repl.show(print):find("function", 1, true))
end)
