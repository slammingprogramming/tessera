-- SPDX-License-Identifier: AGPL-3.0-or-later
local tprint = require("tsrapps.tprint")

--- A fake printer that records finished pages as arrays of lines.
local function fakePrinter(opts)
  opts = opts or {}
  local p = { pages = {}, paper = opts.paper or 10, ink = opts.ink or 5, w = opts.w or 25, h = opts.h or 21, titles = {} }
  local cur, cx, cy
  function p.getPageSize() return p.w, p.h end
  function p.getPaperLevel() return p.paper end
  function p.getInkLevel() return p.ink end
  function p.newPage()
    if p.paper <= 0 or p.ink <= 0 or opts.failNewPage then return false end
    cur = {}
    for y = 1, p.h do cur[y] = string.rep(" ", p.w) end
    cx, cy = 1, 1
    return true
  end
  function p.setCursorPos(x, y) cx, cy = x, y end
  function p.setPageTitle(t) p.titles[#p.titles + 1] = t end
  function p.write(s)
    local row = cur[cy]
    cur[cy] = (row:sub(1, cx - 1) .. s .. row:sub(cx + #s)):sub(1, p.w)
    cx = cx + #s
  end
  function p.endPage()
    if opts.failEndPage then return false end
    local lines = {}
    for y = 1, p.h do lines[y] = cur[y]:gsub("%s+$", "") end
    p.pages[#p.pages + 1] = lines
    p.paper = p.paper - 1
    return true
  end
  return p
end

local function testIo(inputs)
  local io = { said = {}, errs = {}, queue = inputs or {} }
  function io.say(t) io.said[#io.said + 1] = t end
  function io.err(t) io.errs[#io.errs + 1] = t end
  function io.prompt(_, d) if #io.queue > 0 then return table.remove(io.queue, 1) end return d end
  return io
end

test("wrap breaks at word boundaries and splits long words", function()
  eq(tprint.wrap("the quick brown fox", 10), { "the quick", "brown fox" })
  eq(tprint.wrap("abcdefghijklmnop", 6), { "abcdef", "ghijkl", "mnop" })
  eq(tprint.wrap("one\n\ntwo", 20), { "one", "", "two" })
  eq(tprint.wrap("  indented text", 20), { "  indented text" })
  eq(tprint.wrap("tab\there", 20), { "tab here" })
  eq(tprint.wrap("trailing\n\n\n", 20), { "trailing" })
end)

test("paginate honours a shorter first page", function()
  local lines = {}
  for i = 1, 10 do lines[i] = "l" .. i end
  local pages = tprint.paginate(lines, 4, 2)
  eq(#pages, 3)
  eq(#pages[1], 2)
  eq(#pages[2], 4)
  eq(pages[3][4], "l10")
  eq(#tprint.paginate({}, 5), 1)
end)

test("a short text prints one page with a centred title", function()
  local p = fakePrinter()
  eq(tprint.print(p, "Hello printer", { title = "Note" }), 1)
  local page = p.pages[1]
  ok(page[1]:find("== Note ==", 1, true), page[1])
  eq(page[3], "Hello printer")
  eq(p.titles[1], "Note")
  eq(page[21], "", "no page number on a single page")
end)

test("long text is paginated with numbers", function()
  local p = fakePrinter({ paper = 20 })
  local words = {}
  for i = 1, 200 do words[i] = "word" .. i end
  local n = tprint.print(p, table.concat(words, " "), { title = "Long" })
  ok(n >= 3, "expected several pages, got " .. tostring(n))
  eq(#p.pages, n)
  ok(p.pages[1][21]:find("1/" .. n, 1, true))
  ok(p.pages[n][21]:find(n .. "/" .. n, 1, true))
  ok(p.titles[1]:find("(1/" .. n .. ")", 1, true))
  local last = p.pages[n]
  local body = 0
  for y = 1, 20 do if last[y] ~= "" then body = body + 1 end end
  ok(body >= 1)
end)

test("copies multiply the pages", function()
  local p = fakePrinter({ paper = 10 })
  eq(tprint.print(p, "x", { copies = 3 }), 3)
  eq(#p.pages, 3)
end)

test("not enough paper is reported before anything is printed", function()
  local p = fakePrinter({ paper = 1 })
  local n, err = tprint.print(p, "x", { copies = 2 })
  ok(n == nil and err:find("need 2 sheet") and err:find("only 1"))
  eq(#p.pages, 0)
end)

test("no ink and printer failures give clear messages", function()
  local p = fakePrinter({ ink = 0 })
  local n, err = tprint.print(p, "x")
  ok(n == nil and err:find("out of ink"))
  p = fakePrinter({ failNewPage = true })
  n, err = tprint.print(p, "x")
  ok(n == nil and err:find("could not start page"))
  p = fakePrinter({ failEndPage = true })
  n, err = tprint.print(p, "x")
  ok(n == nil and err:find("output tray"))
end)

test("main prints a file and names the page after it", function()
  fs.makeDir("/tmp-print")
  local h = fs.open("/tmp-print/notes.txt", "w") h.write("some notes to print") h.close()
  local p = fakePrinter()
  local io = testIo()
  ok(tprint.main({ "/tmp-print/notes.txt" }, io, p))
  ok(p.pages[1][1]:find("notes.txt", 1, true))
  ok(io.said[1]:find("Printed 1 page"))
  eq(tprint.main({ "/tmp-print/missing.txt" }, io, fakePrinter()), false)
  fs.delete("/tmp-print")
end)

test("main works interactively like the old script, but with several lines", function()
  local p = fakePrinter()
  local io = testIo({ "My Title", "first line", "second line", "." })
  ok(tprint.main({}, io, p))
  ok(p.pages[1][1]:find("My Title", 1, true))
  eq(p.pages[1][3], "first line")
  eq(p.pages[1][4], "second line")
  local empty = testIo({ "T", "." })
  eq(tprint.main({}, empty, fakePrinter()), false)
  ok(empty.errs[1]:find("Nothing"))
end)

test("main explains when there is no printer", function()
  local io = testIo()
  local realFind = peripheral.find
  peripheral.find = function() return nil end
  local res = tprint.main({ "x" }, io)
  peripheral.find = realFind
  eq(res, false)
  ok(io.errs[1]:find("No printer"))
end)
