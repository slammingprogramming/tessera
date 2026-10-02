-- SPDX-License-Identifier: AGPL-3.0-or-later
local vault = require("tsr.vault")
local cli = require("tsr.vault.cli")
local vfs = require("tsr.vfs")
local crypto = require("tsr.crypto")

local DIR = "/tmp-vault"
local MP = "/tmp-vault-mount"

vault.ITERATIONS = 3          -- fast for tests; the real default is 4000

local function reset()
  for _, m in pairs(vault.mounted) do m:unmount() end
  if fs.exists(DIR) then fs.delete(DIR) end
end

local F = vfs.fs

local function put(path, data)
  local parent = path:match("^(.*)/[^/]+$")
  if parent and parent ~= "" and not F.exists(parent) then F.makeDir(parent) end
  local h = assert(F.open(path, "wb"))
  h.write(data)
  h.close()
end

local function get(path)
  local h = F.open(path, "rb")
  if not h then return nil end
  local s = h.readAll() or ""        -- readAll is nil at the end of an empty file
  h.close()
  return s
end

local function allDiskBytes()
  local out = {}
  local function walk(dir)
    for _, n in ipairs(fs.list(dir)) do
      local p = dir .. "/" .. n
      if fs.isDir(p) then walk(p) else out[#out + 1] = n .. "\0" .. (vfs.readFile(p, true) or "") end
    end
  end
  walk(DIR)
  return table.concat(out, "\1")
end

test("create, mount, write files and folders, unmount: only ciphertext is on disk", function()
  reset()
  local v, recovery = vault.create(DIR, "correct horse")
  ok(v, recovery)
  ok(#crypto.base64Decode(recovery) == 32)
  v:mount(MP)
  F.makeDir(MP .. "/plans/base")
  put(MP .. "/plans/base/secret-coordinates.txt", "x=1337 y=64 z=-4242 TOP SECRET")
  put(MP .. "/notes.txt", "remember the diamonds")
  eq(get(MP .. "/notes.txt"), "remember the diamonds")
  eq(F.list(MP), { "notes.txt", "plans" })
  ok(F.isDir(MP .. "/plans/base"))
  v:unmount()
  ok(not F.exists(MP .. "/notes.txt"), "unmounted: the files are gone from view")
  local disk = allDiskBytes()
  ok(not disk:find("TOP SECRET", 1, true) and not disk:find("diamonds", 1, true), "no plaintext on disk")
  ok(not disk:find("secret-coordinates", 1, true) and not disk:find("notes.txt", 1, true), "no file names on disk either")
  ok(not disk:find("plans", 1, true))
end)

test("reopening with the passphrase restores everything; the wrong passphrase and a wrong recovery key do not", function()
  reset()
  local v, recovery = vault.create(DIR, "correct horse")
  v:mount(MP)
  put(MP .. "/a/b/c.txt", "deep file")
  put(MP .. "/big.bin", string.rep("0123456789", 1500))     -- three chunks
  put(MP .. "/empty", "")
  v:unmount()
  local bad, why = vault.open(DIR, "wrong")
  ok(bad == nil and why == "wrong passphrase")
  ok(vault.open(DIR, crypto.base64Encode(crypto.rand.bytes(32))) == nil, "a random recovery key")
  local v2 = assert(vault.open(DIR, "correct horse"))
  v2:mount(MP)
  eq(get(MP .. "/a/b/c.txt"), "deep file")
  eq(get(MP .. "/big.bin"), string.rep("0123456789", 1500))
  eq(get(MP .. "/empty"), "")
  eq(F.list(MP), { "a", "big.bin", "empty" })
  v2:unmount()
  -- the recovery key opens it too
  local v3 = assert(vault.open(DIR, recovery))
  v3:mount(MP)
  eq(get(MP .. "/a/b/c.txt"), "deep file")
  v3:unmount()
end)

test("changes persist: overwrite, append, delete, move, directory delete", function()
  reset()
  local v = vault.create(DIR, "passphrase1")
  v:mount(MP)
  put(MP .. "/f.txt", "first")
  put(MP .. "/f.txt", "second version")
  local h = F.open(MP .. "/f.txt", "ab") h.write(" + more") h.close()
  put(MP .. "/g.txt", "gone soon")
  F.delete(MP .. "/g.txt")
  F.makeDir(MP .. "/old")
  put(MP .. "/old/x.txt", "x")
  F.move(MP .. "/old", MP .. "/new")
  put(MP .. "/dir/one", "1") put(MP .. "/dir/two", "2")
  F.delete(MP .. "/dir")
  v:unmount()
  local data = #fs.list(DIR .. "/d")
  local v2 = assert(vault.open(DIR, "passphrase1"))
  v2:mount(MP)
  eq(get(MP .. "/f.txt"), "second version + more")
  ok(not F.exists(MP .. "/g.txt"))
  eq(get(MP .. "/new/x.txt"), "x")
  ok(not F.exists(MP .. "/old"))
  ok(not F.exists(MP .. "/dir"))
  eq(data, 2, "only f.txt and new/x.txt have data files; replaced and deleted ones were removed")
  v2:unmount()
end)

test("tampering is detected: damaged chunks, damaged index, swapped data files", function()
  reset()
  local v = vault.create(DIR, "passphrase1")
  v:mount(MP)
  put(MP .. "/a.txt", "AAAA content of a")
  put(MP .. "/b.txt", "BBBB content of b")
  v:unmount()
  -- flip a byte in one data file
  local names = fs.list(DIR .. "/d")
  local path = DIR .. "/d/" .. names[1]
  local raw = vfs.readFile(path, true)
  vfs.writeFile(path, raw:sub(1, 5) .. string.char((raw:byte(6) + 1) % 256) .. raw:sub(7), true)
  local v2 = assert(vault.open(DIR, "passphrase1"))
  v2:mount(MP)
  eq(#v2.problems, 1)
  ok(v2.problems[1]:find("failed authentication", 1, true), v2.problems[1])
  v2:unmount()
  -- swapping the two data files (a chunk sealed for one id must not open as another)
  reset()
  local w = vault.create(DIR, "passphrase1")
  w:mount(MP)
  put(MP .. "/a.txt", "AAAA") put(MP .. "/b.txt", "BBBB")
  w:unmount()
  local n = fs.list(DIR .. "/d")
  local p1, p2 = DIR .. "/d/" .. n[1], DIR .. "/d/" .. n[2]
  local d1, d2 = vfs.readFile(p1, true), vfs.readFile(p2, true)
  vfs.writeFile(p1, d2, true) vfs.writeFile(p2, d1, true)
  local w2 = assert(vault.open(DIR, "passphrase1"))
  w2:mount(MP)
  eq(#w2.problems, 2, "both swapped files fail")
  w2:unmount()
  -- a damaged index
  local idx = vfs.readFile(DIR .. "/index.enc", true)
  vfs.writeFile(DIR .. "/index.enc", idx:sub(1, 20) .. "X" .. idx:sub(22), true)
  local bad, why = vault.open(DIR, "passphrase1")
  ok(bad == nil and why:find("tampered", 1, true), tostring(why))
end)

test("a crash between writing data and updating the index leaves the old content; orphans are collected", function()
  reset()
  local v = vault.create(DIR, "passphrase1")
  v:mount(MP)
  put(MP .. "/f.txt", "old content")
  v:unmount()
  -- simulate the crash: a new data file was written but the index still points to the old one
  vfs.writeFile(DIR .. "/d/aaaaaaaaaaaaaaaaaaaaaaaa", "half written garbage", true)
  local v2 = assert(vault.open(DIR, "passphrase1"))
  v2:mount(MP)
  eq(get(MP .. "/f.txt"), "old content")
  ok(not fs.exists(DIR .. "/d/aaaaaaaaaaaaaaaaaaaaaaaa"), "the orphan was removed")
  v2:unmount()
end)

test("changing the passphrase keeps the data and the recovery key working", function()
  reset()
  local v, recovery = vault.create(DIR, "old passphrase")
  v:mount(MP)
  put(MP .. "/f.txt", "keep me")
  v:unmount()
  local v2 = assert(vault.open(DIR, "old passphrase"))
  ok(not v2:changePassphrase("abc"), "too short")
  ok(v2:changePassphrase("new passphrase"))
  ok(vault.open(DIR, "old passphrase") == nil)
  local v3 = assert(vault.open(DIR, "new passphrase"))
  v3:mount(MP)
  eq(get(MP .. "/f.txt"), "keep me")
  v3:unmount()
  ok(vault.open(DIR, recovery))
  ok(select(2, vault.create(DIR, "xxxxxx")):find("already holds", 1, true))
  ok(select(2, vault.create(DIR .. "-2", "abc")):find("at least 6", 1, true))
end)

test("the vault command: create, open, close, list, passwd, recover", function()
  reset()
  local answers, said, errs = {}, {}, {}
  local io = {
    say = function(t) said[#said + 1] = t end, err = function(t) errs[#errs + 1] = t end,
    readPassword = function() return table.remove(answers, 1) end, collect = function() end,
  }
  answers = { "my passphrase", "my passphrase" }
  ok(cli.run({ "create", DIR }, io), table.concat(errs, "|"))
  local recovery
  for i, line in ipairs(said) do if line:find("RECOVERY KEY", 1, true) then recovery = said[i + 1] end end
  ok(recovery and #crypto.base64Decode(recovery) == 32)
  answers = { "wrong" }
  ok(not cli.run({ "open", DIR, MP }, io))
  answers = { "my passphrase" }
  ok(cli.run({ "open", DIR, MP }, io), table.concat(errs, "|"))
  put(MP .. "/hello.txt", "hi")
  said = {}
  ok(cli.run({ "list" }, io))
  ok(said[1]:find(MP, 1, true), said[1])
  answers = { "x" }
  ok(not cli.run({ "open", DIR, MP }, io), "already mounted")
  ok(cli.run({ "close", MP }, io))
  ok(not F.exists(MP .. "/hello.txt"))
  ok(not cli.run({ "close", MP }, io))
  answers = { "my passphrase", "second passphrase", "second passphrase" }
  ok(cli.run({ "passwd", DIR }, io), table.concat(errs, "|"))
  answers = { recovery }
  ok(cli.run({ "recover", DIR, MP }, io), table.concat(errs, "|"))
  eq(get(MP .. "/hello.txt"), "hi")
  ok(cli.run({ "close", MP }, io))
end)
