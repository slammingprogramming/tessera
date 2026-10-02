-- SPDX-License-Identifier: AGPL-3.0-or-later
local help = require("tsr.help")

local DIR = "/tmp-help"

local function put(name, text)
  local h = fs.open(DIR .. "/" .. name, "w")
  h.write(text)
  h.close()
end

local function fresh()
  if fs.exists(DIR) then fs.delete(DIR) end
  fs.makeDir(DIR)
  help.DIR = DIR
  help.TOUR_DONE = DIR .. "/tour.done"
  put("20-shell.txt", "The shell\nPipes and redirects\n  list | grep lua\n")
  put("10-start.txt", "Getting started\nInstall things with pkg.\n")
  put("30-shellscripts.txt", "Scripts\nFiles ending in .tsh\n")
  put("notes.md", "ignored")
end

local function io_()
  local io = { said = {}, errs = {} }
  function io.say(t) io.said[#io.said + 1] = t end
  function io.err(t) io.errs[#io.errs + 1] = t end
  return io
end

test("topics are read in order with id, title and body", function()
  fresh()
  local t = help.topics()
  eq({ #t, t[1].id, t[2].id, t[3].id }, { 3, "start", "shell", "shellscripts" })
  eq(t[1].title, "Getting started")
  eq(t[1].text, "Install things with pkg.\n")
  help.DIR = "/does/not/exist"
  eq(help.topics(), {})
end)

test("finding a topic by id or prefix", function()
  fresh()
  eq(help.find("start").title, "Getting started")
  eq(help.find("sta").id, "start")
  eq(help.find("shell").id, "shell", "an exact id wins over a longer one with the same prefix")
  local none, err = help.find("shellx")
  ok(none == nil and err:find("no topic"))
  none, err = help.find("s")
  ok(none == nil and err:find("several"), tostring(err))
end)

test("search finds topics and lines", function()
  fresh()
  local r = help.search("PKG")
  eq(#r, 1)
  eq(r[1].topic.id, "start")
  eq(r[1].lines, { "Install things with pkg." })
  eq(#help.search("nothing-like-this"), 0)
  eq(#help.search("shell"), 1, "titles count (ids do not)")
end)

test("layout wraps long lines and keeps indentation", function()
  eq(help.layout("one two three", 7), { "one two", "three" })
  eq(help.layout("  indented text here", 12), { "  indented", "  text here" })
  eq(help.layout("a\n\nb", 10), { "a", "", "b" })
  eq(help.layout("trailing\n\n\n", 10), { "trailing" })
  eq(help.layout("supercalifragilistic", 5), { "supercalifragilistic" }, "a single long word is left whole")
end)

test("the command: topic, search, errors, menu", function()
  fresh()
  local shown = {}
  local opts = { pager = function(title, lines) shown[#shown + 1] = { title = title, lines = lines } end }
  local io = io_()
  ok(help.run({ "start" }, io, opts))
  eq(shown[1].title, "Getting started")
  ok(shown[1].lines[1]:find("Install", 1, true))
  eq(help.run({ "nope" }, io, opts), false)
  ok(io.errs[1]:find("no topic", 1, true))
  io = io_()
  ok(help.run({ "search", "pkg" }, io, opts))
  ok(io.said[1]:find("start", 1, true) and io.said[2]:find("Install", 1, true))
  ok(help.run({ "search", "zzzz" }, io, opts))
  ok(io.said[#io.said]:find("Nothing found", 1, true))
  eq(help.run({ "search" }, io, opts), false)
  -- the menu lists titles and opens the chosen topic until the user backs out
  local picks = { 2, nil }
  local ui = { menu = function(title, items)
    eq(items[1].label, "Getting started")
    return table.remove(picks, 1)
  end }
  shown = {}
  ok(help.run({}, io_(), { ui = ui, pager = opts.pager }))
  eq(shown[1].title, "The shell")
  help.DIR = "/does/not/exist"
  local io2 = io_()
  ok(help.run({}, io2, { ui = ui }))
  ok(io2.said[1]:find("No manual", 1, true))
end)

test("the pager scrolls and quits", function()
  fresh()
  local lines = {}
  for i = 1, 60 do lines[i] = "line " .. i end
  local events = {
    { "key", keys.down }, { "key", keys.down }, { "key", keys.pageDown }, { "key", keys.home }, { "key", keys.q },
  }
  local count = 0
  help.pager("Title", lines, { pull = function() count = count + 1 return table.unpack(table.remove(events, 1)) end })
  eq(count, 5)
  -- space runs to the end and leaves
  local seen = 0
  help.pager("Title", { "a", "b" }, { pull = function() seen = seen + 1 return "key", keys.space end })
  eq(seen, 1)
end)

test("the tour shows every page and remembers it was seen", function()
  fresh()
  local titles = {}
  local ui = { message = function(title, lines) titles[#titles + 1] = title end }
  ok(not help.tourDone())
  ok(help.tour({ ui = ui }))
  eq(#titles, #help.TOUR)
  eq(titles[1], "Welcome to Tessera")
  ok(help.tourDone())
end)

test("the shipped manual has the expected topics and no stale commands", function()
  help.DIR = "/usr/share/help"
  local topics = help.topics()
  ok(#topics >= 10, "topics: " .. #topics)
  for _, t in ipairs(topics) do
    ok(t.title ~= "" and #t.text > 100, t.id)
  end
  local ids = {}
  for _, t in ipairs(topics) do ids[t.id] = true end
  for _, id in ipairs({ "start", "shell", "packages", "services", "network", "users", "gui", "turtles", "devices", "recovery", "about" }) do
    ok(ids[id], "missing topic " .. id)
  end
end)
