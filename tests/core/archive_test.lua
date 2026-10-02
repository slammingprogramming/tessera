-- SPDX-License-Identifier: AGPL-3.0-or-later
local deflate = require("tsr.archive.deflate")
local tar = require("tsr.archive.tar")
local cli = require("tsr.archive.cli")
local vfs = require("tsr.vfs")
local fx = dofile("/tests/fixtures/archive_fixtures.lua")

local F = vfs.fs
local ROOT = "/tmp/archive-test"          -- the RAM disk: the host file system limits long paths

local function reset()
  if F.exists(ROOT) then F.delete(ROOT) end
  vfs.mkdirp(ROOT)
end

local function put(path, data) assert(vfs.writeFile(path, data, true)) end

-- the Node side (tools/test/archive-interop.mjs) checks the compressor's output with real zlib: we leave the files in /out
local function interop(name, bytes, original)
  pcall(function()
    if not fs.exists("/out/interop") then fs.makeDir("/out/interop") end
    for suffix, data in pairs({ gz = bytes, orig = original }) do
      local h = fs.open("/out/interop/" .. name .. "." .. suffix, "wb")
      h.write(data)
      h.close()
    end
  end)
end

local function sample(n)
  local t = {}
  for i = 1, n do t[#t + 1] = ("row %d: Tessera stores %d blocks in chest %d\n"):format(i, i * 7 % 97, i % 13) end
  return table.concat(t)
end

test("deflate round trips through tsr.inflate: empty, short, repetitive, text, binary", function()
  local inflate = require("tsr.inflate")
  local cases = {
    "", "a", "ab", "abc", string.rep("a", 1000), string.rep("abcd", 5000), sample(300),
    (function() local t = {} for i = 0, 3000 do t[#t + 1] = string.char((i * 131 + math.floor(i / 7)) % 256) end return table.concat(t) end)(),
  }
  for i, data in ipairs(cases) do
    local packed = deflate.deflate(data)
    local back = inflate.inflate(packed, 1)
    eq(back, data, "case " .. i)
  end
  ok(#deflate.deflate(string.rep("a", 10000)) < 200, "long runs shrink a lot")
  local text = sample(400)
  ok(#deflate.deflate(text) < #text * 0.5, "text shrinks below half")
  local noise = {}
  local seed = 12345
  for i = 1, 5000 do seed = (seed * 1103515245 + 12345) % 2147483648 noise[i] = string.char(math.floor(seed / 65536) % 256) end
  noise = table.concat(noise)
  ok(#deflate.deflate(noise) <= #noise + 20, "incompressible data is stored, not inflated")
  eq(inflate.inflate(deflate.deflate(noise, 0), 1), noise, "level 0 stores")
  local big = string.rep("x", 70000)      -- two stored blocks
  eq(inflate.inflate(deflate.deflate(big, 0), 1), big)
end)

test("gzip: round trip, name in header, damaged files are refused; real zlib files are read", function()
  local text = sample(200)
  local gz = deflate.gzip(text, { name = "rows.txt" })
  local back, name = deflate.gunzip(gz)
  eq(back, text) eq(name, "rows.txt")
  interop("lua-rows", gz, text)
  interop("lua-empty", deflate.gzip(""), "")
  interop("lua-long-run", deflate.gzip(string.rep("z", 100000)), string.rep("z", 100000))
  local bad = gz:sub(1, 30) .. string.char((gz:byte(31) + 1) % 256) .. gz:sub(32)
  local r, why = deflate.gunzip(bad)
  ok(r == nil and why, "a flipped byte is detected")
  ok(deflate.gunzip(gz:sub(1, #gz - 3)) == nil, "truncated")
  ok(deflate.gunzip("not gzip at all, really not") == nil)
  -- files made by zlib at several levels, and one with a name in the header
  for _, g in ipairs(fx.gz) do eq((deflate.gunzip(g.bytes)), fx.text, "zlib level " .. g.level) end
  local data, named = deflate.gunzip(fx.named)
  eq(data, fx.text) eq(named, "text.txt")
end)

test("tar: reads an archive made by another implementation (folders, empty file, binary, long path)", function()
  local list = assert(tar.list(fx.tar))
  eq(#list, 5)
  eq(list[1].name, "project/") ok(list[1].isDir)
  eq(list[2].name, "project/readme.txt") eq(list[2].size, 22)
  local long = assert(tar.list(fx.longtar))
  ok(long[1].name:find("deep/file.txt", 1, true) and #long[1].name > 100, long[1].name)
  reset()
  local r = assert(tar.extract(fx.tar, ROOT .. "/out"))
  eq(r.files, 4) eq(r.dirs, 1)
  eq(vfs.readFile(ROOT .. "/out/project/readme.txt", true), "hello from a real tar\n")
  eq(vfs.readFile(ROOT .. "/out/project/empty.bin", true), "")
  eq(vfs.readFile(ROOT .. "/out/project/text.txt", true), fx.text)
  eq(#vfs.readFile(ROOT .. "/out/project/binary.bin", true), 700)
  -- a gzipped tar is detected
  local r2 = assert(tar.extract(fx.tgz, ROOT .. "/out2"))
  eq(r2.files, 4)
  eq(vfs.readFile(ROOT .. "/out2/project/text.txt", true), fx.text)
end)

test("tar: create and extract round trip, with and without gzip; the header is standard", function()
  reset()
  put(ROOT .. "/src/a.txt", "alpha")
  put(ROOT .. "/src/sub/b.bin", string.rep("\0\1\2", 400))
  put(ROOT .. "/src/sub/empty", "")
  F.makeDir(ROOT .. "/src/emptydir")
  for _, gz in ipairs({ false, true }) do
    local bytes = assert(tar.create({ ROOT .. "/src" }, { gzip = gz, mtime = 1700000000 }))
    eq(bytes:sub(1, 2) == "\31\139", gz)
    local list = assert(tar.list(bytes))
    local names = {}
    for _, e in ipairs(list) do names[#names + 1] = e.name end
    table.sort(names)
    eq(names, { "src/", "src/a.txt", "src/emptydir/", "src/sub/", "src/sub/b.bin", "src/sub/empty" })
    local dest = ROOT .. "/back" .. (gz and "gz" or "")
    local r = assert(tar.extract(bytes, dest))
    eq(r.files, 3)
    eq(vfs.readFile(dest .. "/src/a.txt", true), "alpha")
    eq(vfs.readFile(dest .. "/src/sub/b.bin", true), string.rep("\0\1\2", 400))
    ok(F.isDir(dest .. "/src/emptydir"))
    if not gz then
      eq(#bytes % 512, 0) eq(bytes:sub(258, 262), "ustar")
      -- the header checksum is the sum of the bytes with the checksum field taken as spaces
      local h = bytes:sub(1, 512)
      local sum = 0
      for i = 1, 512 do sum = sum + ((i >= 149 and i <= 156) and 32 or h:byte(i)) end
      eq(tonumber(h:sub(149, 154), 8), sum)
      interop("lua-tar", deflate.gzip(bytes), bytes)
    end
  end
  ok(select(2, tar.create({ ROOT .. "/nothing" })):find("no such", 1, true))
end)

test("tar: unsafe names and damaged archives are refused before anything is written", function()
  reset()
  local function evil(name)
    local h = { name .. string.rep("\0", 100 - #name), "0000644\0", "0000000\0", "0000000\0", "00000000003\0", "14000000000\0", "        ", "0",
      string.rep("\0", 100), "ustar\0", "00", string.rep("\0", 32 + 32 + 8 + 8 + 155 + 12) }
    h = table.concat(h)
    local sum = 0
    for i = 1, 512 do sum = sum + h:byte(i) end
    h = h:sub(1, 148) .. ("%06o\0 "):format(sum) .. h:sub(157)
    return h .. "abc" .. string.rep("\0", 509) .. string.rep("\0", 1024)
  end
  for _, name in ipairs({ "../escape.txt", "a/../../escape.txt", "/etc/passwd" }) do
    local r, why = tar.extract(evil(name), ROOT .. "/jail")
    ok(r == nil and why:find("unsafe", 1, true), name .. ": " .. tostring(why))
  end
  ok(not F.exists(ROOT .. "/escape.txt") and not F.exists(ROOT .. "/jail"))
  local bytes = assert(tar.create({ ROOT }, {}))
  local broken = bytes:sub(1, 10) .. "X" .. bytes:sub(12)
  ok(tar.list(broken) == nil)
  ok(tar.list("this is not a tar archive") == nil or #tar.list("this is not a tar archive") == 0)
  -- existing files are not overwritten silently
  put(ROOT .. "/dst/project/readme.txt", "mine")
  local r, why = tar.extract(fx.tar, ROOT .. "/dst")
  ok(r == nil and why:find("exists", 1, true), tostring(why))
  eq(vfs.readFile(ROOT .. "/dst/project/readme.txt", true), "mine")
  ok(tar.extract(fx.tar, ROOT .. "/dst", { overwrite = true }))
  eq(vfs.readFile(ROOT .. "/dst/project/readme.txt", true), "hello from a real tar\n")
end)

test("commands: tar -czf / -tf / -xf, gzip, gunzip, zcat", function()
  reset()
  local said, errs = {}, {}
  local io = { say = function(t) said[#said + 1] = t end, err = function(t) errs[#errs + 1] = t end }
  put(ROOT .. "/data/one.txt", "first file")
  put(ROOT .. "/data/two.txt", "second file")
  ok(cli.tar({ "-czf", ROOT .. "/data.tgz", ROOT .. "/data" }, io), table.concat(errs, "|"))
  ok(F.exists(ROOT .. "/data.tgz"))
  said = {}
  ok(cli.tar({ "-tf", ROOT .. "/data.tgz" }, io))
  eq(#said, 3)
  ok(cli.tar({ "-xf", ROOT .. "/data.tgz", "-C", ROOT .. "/x" }, io), table.concat(errs, "|"))
  eq(vfs.readFile(ROOT .. "/x/data/two.txt", true), "second file")
  ok(not cli.tar({ "-xf", ROOT .. "/data.tgz", "-C", ROOT .. "/x" }, io), "second extract would overwrite")
  ok(not cli.tar({ "-q" }, io))
  ok(not cli.tar({ "-cf", ROOT .. "/e.tar" }, io), "nothing to archive")
  -- gzip family
  put(ROOT .. "/notes.txt", sample(50))
  ok(cli.gzip({ "-k", ROOT .. "/notes.txt" }, io))
  ok(F.exists(ROOT .. "/notes.txt") and F.exists(ROOT .. "/notes.txt.gz"))
  said = {}
  ok(cli.gunzip({ ROOT .. "/notes.txt.gz" }, io, true))
  eq(said[1], sample(50))
  ok(not cli.gunzip({ ROOT .. "/notes.txt.gz" }, io), "the target exists")
  F.delete(ROOT .. "/notes.txt")
  ok(cli.gunzip({ ROOT .. "/notes.txt.gz" }, io))
  eq(vfs.readFile(ROOT .. "/notes.txt", true), sample(50))
  ok(not F.exists(ROOT .. "/notes.txt.gz"), "the .gz is removed without -k")
  ok(not cli.gzip({ ROOT .. "/missing" }, io))
end)
