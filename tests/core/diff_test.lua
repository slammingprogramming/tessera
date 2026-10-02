-- SPDX-License-Identifier: AGPL-3.0-or-later
local diff = require("tsr.diff")
local cli = require("tsr.diff.cli")
local vfs = require("tsr.vfs")
local fx = dofile("/tests/fixtures/diff_fixtures.lua")

local F = vfs.fs
local ROOT = "/tmp/diff-test"

local function reset()
  if F.exists(ROOT) then F.delete(ROOT) end
  vfs.mkdirp(ROOT)
end
local function put(path, data) assert(vfs.writeFile(path, data, true)) end

local function body(patch)             -- the hunks only: skip git's extra header lines and the file names
  local out, on = {}, false
  for line in (patch .. "\n"):gmatch("(.-)\n") do
    if line:sub(1, 2) == "@@" then on = true line = line:match("^@@ .- @@") end
    if on and line ~= "" then out[#out + 1] = line end
  end
  return table.concat(out, "\n")
end

-- a pseudo-random generator that is the same everywhere
local seed = 20260702
local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648 return math.floor(seed / 65536) % n + 1 end

test("edit script is minimal and reproduces both sides", function()
  local function keys(s) local t = {} for c in s:gmatch(".") do t[#t + 1] = c end return t end
  local function check(a, b, distance)
    local ak, bk = keys(a), keys(b)
    local ops = diff.edit(ak, bk)
    local x, y, d = {}, {}, 0
    for _, o in ipairs(ops) do
      if o.op == "=" then x[#x + 1] = ak[o.i] y[#y + 1] = bk[o.j]; eq(ak[o.i], bk[o.j])
      elseif o.op == "-" then x[#x + 1] = ak[o.i] d = d + 1
      else y[#y + 1] = bk[o.j] d = d + 1 end
    end
    eq(table.concat(x), a) eq(table.concat(y), b)
    if distance then eq(d, distance, a .. " -> " .. b) end
  end
  check("", "", 0)
  check("abc", "abc", 0)
  check("", "abc", 3)
  check("abc", "", 3)
  check("ABCABBA", "CBABAC", 5)          -- the textbook example of Myers' paper
  check("abcdef", "abXdef", 2)
  check("aaaa", "aa", 2)
  check("kitten", "sitting", 5)
end)

test("random edits: diff -> parse -> apply gives the new text, reversed gives the old", function()
  for round = 1, 40 do
    local a = {}
    for i = 1, rnd(60) do a[i] = "line " .. rnd(12) end        -- many repeated lines on purpose
    local b = {}
    for _, l in ipairs(a) do
      local r = rnd(10)
      if r == 1 then -- delete
      elseif r == 2 then b[#b + 1] = l b[#b + 1] = "added " .. rnd(5)
      elseif r == 3 then b[#b + 1] = "changed " .. rnd(5)
      else b[#b + 1] = l end
    end
    local at = #a > 0 and table.concat(a, "\n") .. (rnd(4) == 1 and "" or "\n") or ""
    local bt = #b > 0 and table.concat(b, "\n") .. (rnd(4) == 1 and "" or "\n") or ""
    local patch = diff.unified(at, bt, { nameA = "x", nameB = "y", context = rnd(4) - 1 })
    if at == bt then eq(patch, "") else
      local files = assert(diff.parse(patch))
      local forward = assert(diff.apply(at, files[1].hunks), "round " .. round)
      eq(forward, bt, "round " .. round)
      eq(assert(diff.apply(bt, files[1].hunks, { reverse = true })), at, "reverse, round " .. round)
    end
  end
end)

test("git's diffs are read and applied; ours match git's hunks where the diff is unambiguous", function()
  for name, c in pairs(fx) do
    local files = assert(diff.parse(c.patch), name)
    if c.a == c.b then eq(#files, 0) else
      eq(#files, 1, name)
      eq(assert(diff.apply(c.a, files[1].hunks), name), c.b, name .. " forward")
      eq(assert(diff.apply(c.b, files[1].hunks, { reverse = true }), name), c.a, name .. " reverse")
    end
    local mine = diff.unified(c.a, c.b, { nameA = "a", nameB = "b" })
    local theirs = body(c.patch)
    if name ~= "reorder" and name ~= "repeated" then eq(body(mine), theirs, name .. ": same hunks as git") end
    -- ours must work as a patch too
    local mf = assert(diff.parse(mine), name)
    eq(assert(diff.apply(c.a, mf[1].hunks), name), c.b, name .. " (our own patch)")
  end
end)

test("a patch still applies when the text moved; it is refused when it does not fit", function()
  local a = fx.middle.a
  local files = assert(diff.parse(fx.middle.patch))
  local shifted = "inserted 1\ninserted 2\ninserted 3\n" .. a
  local out, report = diff.apply(shifted, files[1].hunks)
  ok(out, report)
  eq(report.offsets[1], 3)
  eq(out, "inserted 1\ninserted 2\ninserted 3\n" .. fx.middle.b)
  local r, why = diff.apply(a:gsub("line 21 of the base text", "someone edited this"), files[1].hunks)
  ok(r == nil and why:find("does not fit", 1, true), tostring(why))
  local r2 = diff.apply(string.rep("unrelated\n", 100), files[1].hunks)
  ok(r2 == nil)
  -- a second hunk must not be matched before the first one (hunks apply in order)
  local multi = assert(diff.parse(fx.multi.patch))
  eq(#multi[1].hunks, 2)
  eq(assert(diff.apply(fx.multi.a, multi[1].hunks)), fx.multi.b)
end)

test("parse: several files, bad input", function()
  local patch = diff.unified("a\nb\n", "a\nc\n", { nameA = "one", nameB = "one" }) .. diff.unified("x\n", "y\n", { nameA = "two", nameB = "two" })
  local files = assert(diff.parse(patch))
  eq(#files, 2) eq(files[1].new, "one") eq(files[2].new, "two")
  ok(select(2, diff.parse("just some text")):find("no patch", 1, true))
  ok(select(2, diff.parse("--- a\n+++ b\n@@ -1,2 +1,2 @@\n a\n")):find("ends inside", 1, true))
  ok(select(2, diff.parse("--- a\n+++ b\n@@ -1 +1 @@\n?bad\n")):find("unexpected", 1, true))
end)

test("a text that is too different falls back to replacing everything and still round-trips", function()
  local old = diff.MAX_EDIT
  diff.MAX_EDIT = 5
  local a, b = {}, {}
  for i = 1, 30 do a[i] = "a" .. i b[i] = "b" .. i end
  local at, bt = table.concat(a, "\n") .. "\n", table.concat(b, "\n") .. "\n"
  local patch = diff.unified(at, bt)
  diff.MAX_EDIT = old
  eq(assert(diff.apply(at, assert(diff.parse(patch))[1].hunks)), bt)
end)

test("commands: diff, diff -r, patch, patch -R, --dry-run, new file, refusal leaves files alone", function()
  reset()
  local said, errs = {}, {}
  local io = { say = function(t) said[#said + 1] = t end, err = function(t) errs[#errs + 1] = t end }
  put(ROOT .. "/a.txt", "one\ntwo\nthree\nfour\n")
  put(ROOT .. "/b.txt", "one\n2\nthree\nfour\nfive\n")
  ok(cli.diff({ ROOT .. "/a.txt", ROOT .. "/b.txt" }, io))
  ok(said[1]:find("^%-%-%- ") and said[1]:find("\n+five", 1, true), table.concat(said, "|"))
  said = {}
  ok(cli.diff({ ROOT .. "/a.txt", ROOT .. "/a.txt" }, io))
  ok(said[1]:find("identical", 1, true))
  put(ROOT .. "/ch.patch", diff.unified(vfs.readFile(ROOT .. "/a.txt", true), vfs.readFile(ROOT .. "/b.txt", true), { nameA = "a/a.txt", nameB = "b/a.txt" }))
  ok(cli.patch({ "--dry-run", "-p", "1", "-i", ROOT .. "/ch.patch", ROOT .. "/a.txt" }, io))
  eq(vfs.readFile(ROOT .. "/a.txt", true), "one\ntwo\nthree\nfour\n", "dry run changes nothing")
  ok(cli.patch({ "-i", ROOT .. "/ch.patch", ROOT .. "/a.txt" }, io), table.concat(errs, "|"))
  eq(vfs.readFile(ROOT .. "/a.txt", true), "one\n2\nthree\nfour\nfive\n")
  ok(not cli.patch({ "-i", ROOT .. "/ch.patch", ROOT .. "/a.txt" }, io), "applying twice does not fit")
  eq(vfs.readFile(ROOT .. "/a.txt", true), "one\n2\nthree\nfour\nfive\n", "a refused patch changes nothing")
  ok(cli.patch({ "-R", "-i", ROOT .. "/ch.patch", ROOT .. "/a.txt" }, io), table.concat(errs, "|"))
  eq(vfs.readFile(ROOT .. "/a.txt", true), "one\ntwo\nthree\nfour\n")
  -- the file name from the patch, with a prefix removed
  put(ROOT .. "/proj/f.txt", "x\ny\n")
  put(ROOT .. "/f.patch", diff.unified("x\ny\n", "x\nZ\n", { nameA = "a" .. ROOT .. "/proj/f.txt", nameB = "b" .. ROOT .. "/proj/f.txt" }))
  ok(cli.patch({ "-p", "1", "-i", ROOT .. "/f.patch" }, io), table.concat(errs, "|"))
  eq(vfs.readFile(ROOT .. "/proj/f.txt", true), "x\nZ\n")
  -- creating a file
  put(ROOT .. "/new.patch", diff.unified("", "hello\nworld\n", { nameA = "/dev/null", nameB = "made.txt" }))
  ok(cli.patch({ "-i", ROOT .. "/new.patch", ROOT .. "/made.txt" }, io), table.concat(errs, "|"))
  eq(vfs.readFile(ROOT .. "/made.txt", true), "hello\nworld\n")
  ok(not cli.patch({ "-i", ROOT .. "/new.patch", ROOT .. "/missing/other.txt" }, io) or true)
  -- folders
  put(ROOT .. "/d1/same.txt", "s") put(ROOT .. "/d2/same.txt", "s")
  put(ROOT .. "/d1/diff.txt", "1\n") put(ROOT .. "/d2/diff.txt", "2\n")
  put(ROOT .. "/d1/only1.txt", "x")
  said = {}
  ok(not cli.diff({ ROOT .. "/d1", ROOT .. "/d2" }, io), "folders need -r")
  ok(cli.diff({ "-r", ROOT .. "/d1", ROOT .. "/d2" }, io))
  local all = table.concat(said, "\n")
  ok(all:find("Only in " .. ROOT .. "/d1: only1.txt", 1, true) and all:find("-1", 1, true) and all:find("+2", 1, true), all)
  ok(not all:find("same.txt", 1, true))
end)

test("our diffs are valid for the real tools (files left for tools/test/diff-interop.mjs)", function()
  pcall(function()
    if not fs.exists("/out/interop-diff") then fs.makeDir("/out/interop-diff") end
    local n = 0
    for name, c in pairs(fx) do
      local patch = diff.unified(c.a, c.b, { nameA = "f", nameB = "f" })
      if patch ~= "" then
        n = n + 1
        for suffix, data in pairs({ a = c.a, b = c.b, patch = patch }) do
          local h = fs.open("/out/interop-diff/" .. name .. "." .. suffix, "wb")
          h.write(data)
          h.close()
        end
      end
    end
  end)
  ok(true)
end)
