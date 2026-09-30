-- SPDX-License-Identifier: AGPL-3.0-or-later
local F = dofile("/tests/lib/fakes.lua")
local filesync = require("tsrapps.filesync")
local secure = require("tsrapps.secure")
local hash = require("tsr.hash")

local SECRET = "a shared passphrase"

local function put(path, text)
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local h = fs.open(path, "wb") h.write(text) h.close()
end

local function read(path)
  local h = fs.open(path, "rb")
  if not h then return nil end
  local s = h.readAll() h.close()
  return s
end

local function setup()
  fs.delete("/tmp-fs")
  filesync.STATE_FILE = "/tmp-fs/state.json"
  filesync.KEY_FILE = "/tmp-fs/key"
  fs.makeDir("/tmp-fs/server")
  fs.makeDir("/tmp-fs/client")
end

--- Connect a client to a server through in-memory queues: the client's send() lets the server answer immediately.
local function loopback(cfg, secret, serverId)
  local state = { last = {} }
  local inbox = {}
  local net = {
    send = function(target, msg)
      local m = secure.gate(secret, state, 7, msg)
      if m then
        local ok, data = filesync.dispatch(cfg, m)
        inbox[#inbox + 1] = { from = target, msg = secure.reply(secret, m, ok, data) }
      end
    end,
    receive = function() local m = table.remove(inbox, 1) if m then return m.from, m.msg end end,
  }
  return net
end

test("safe paths", function()
  local s = filesync.safe
  ok(s("a.txt") and s("dir/sub/file.lua") and s("a b/c"))
  ok(not s("") and not s("/etc/passwd") and not s("../x") and not s("a/../../x") and not s("a//b"))
  ok(not s("./x") and not s("dir/") and not s("a\\b") and not s(nil) and not s(42))
  ok(not s("x\0y") and not s(string.rep("a", 300)))
end)

test("manifest lists files with hashes, sorted", function()
  setup()
  put("/tmp-fs/server/b.txt", "bee")
  put("/tmp-fs/server/sub/a.txt", "ay")
  local m = assert(filesync.manifest("/tmp-fs/server"))
  eq(#m, 2)
  eq(m[1], { path = "b.txt", size = 3, sha256 = hash.sha256("bee") })
  eq(m[2].path, "sub/a.txt")
  eq(filesync.manifest("/tmp-fs/none"), {})
  fs.delete("/tmp-fs")
end)

test("diff: copy what is new or changed, remove what is extra", function()
  local src = { { path = "a", sha256 = "1" }, { path = "b", sha256 = "2" }, { path = "c", sha256 = "3" } }
  local dst = { { path = "a", sha256 = "1" }, { path = "b", sha256 = "OLD" }, { path = "z", sha256 = "9" } }
  local plan = filesync.diff(src, dst)
  eq({ plan.copy[1].path, plan.copy[2].path }, { "b", "c" })
  eq(plan.remove, { "z" })
end)

test("the server refuses unsafe paths, writes when read-only, and unknown commands", function()
  setup()
  put("/tmp-fs/server/ok.txt", "fine")
  put("/tmp-fs/secret.txt", "outside the share")
  local cfg = { root = "/tmp-fs/server", writable = false }
  local ok1, why = filesync.dispatch(cfg, { cmd = "get", arg = { path = "../secret.txt", offset = 0 } })
  ok(not ok1 and why == "bad path")
  ok1, why = filesync.dispatch(cfg, { cmd = "get", arg = { path = "/tmp-fs/secret.txt", offset = 0 } })
  ok(not ok1 and why == "bad path")
  ok1, why = filesync.dispatch(cfg, { cmd = "put", arg = { path = "x.txt", chunk = "x", offset = 0, eof = true } })
  ok(not ok1 and why:find("read%-only"))
  ok1, why = filesync.dispatch(cfg, { cmd = "delete", arg = "ok.txt" })
  ok(not ok1 and why:find("read%-only"))
  ok(fs.exists("/tmp-fs/server/ok.txt"))
  ok1, why = filesync.dispatch(cfg, { cmd = "format" })
  ok(not ok1 and why == "unknown command")
  ok1, why = filesync.dispatch(cfg, { cmd = "get", arg = { path = "missing.txt" } })
  ok(not ok1 and why == "no such file")
  fs.delete("/tmp-fs")
end)

test("pull copies new and changed files in chunks and checks them", function()
  setup()
  local big = string.rep("0123456789abcdef", 2000) -- 32000 bytes -> 4 chunks
  put("/tmp-fs/server/big.bin", big)
  put("/tmp-fs/server/docs/readme.txt", "hello")
  put("/tmp-fs/client/docs/readme.txt", "stale")
  put("/tmp-fs/client/extra.txt", "only here")
  local net = loopback({ root = "/tmp-fs/server", writable = false }, SECRET)
  local io = F.io()
  local res = assert(filesync.sync("pull", SECRET, net, 5, "/tmp-fs/client", {}, io))
  eq(res.copied, 2)
  eq(res.removed, 0)
  eq(read("/tmp-fs/client/big.bin"), big)
  eq(read("/tmp-fs/client/docs/readme.txt"), "hello")
  ok(fs.exists("/tmp-fs/client/extra.txt"), "extras stay without --delete")
  local again = assert(filesync.sync("pull", SECRET, net, 5, "/tmp-fs/client", {}, io))
  eq(again.copied, 0, "second run has nothing to do")
  local del = assert(filesync.sync("pull", SECRET, net, 5, "/tmp-fs/client", { delete = true }, io))
  eq(del.removed, 1)
  ok(not fs.exists("/tmp-fs/client/extra.txt"))
  fs.delete("/tmp-fs")
end)

test("dry run changes nothing", function()
  setup()
  put("/tmp-fs/server/a.txt", "a")
  local net = loopback({ root = "/tmp-fs/server" }, SECRET)
  local res = assert(filesync.sync("pull", SECRET, net, 5, "/tmp-fs/client", { dryRun = true }, F.io()))
  eq(#res.plan.copy, 1)
  ok(not fs.exists("/tmp-fs/client/a.txt"))
  fs.delete("/tmp-fs")
end)

test("push needs a writable server and updates it", function()
  setup()
  put("/tmp-fs/client/new.txt", "fresh")
  put("/tmp-fs/client/dir/deep.txt", string.rep("z", 20000))
  put("/tmp-fs/server/old.txt", "goes away")
  local ro = loopback({ root = "/tmp-fs/server", writable = false }, SECRET)
  local res, err = filesync.sync("push", SECRET, ro, 5, "/tmp-fs/client", {}, F.io())
  ok(res == nil and err:find("read%-only"))
  local rw = loopback({ root = "/tmp-fs/server", writable = true }, SECRET)
  res = assert(filesync.sync("push", SECRET, rw, 5, "/tmp-fs/client", { delete = true }, F.io()))
  eq(res.copied, 2)
  eq(res.removed, 1)
  eq(read("/tmp-fs/server/new.txt"), "fresh")
  eq(#read("/tmp-fs/server/dir/deep.txt"), 20000)
  ok(not fs.exists("/tmp-fs/server/old.txt"))
  ok(not fs.exists("/tmp-fs/server/new.txt.tsr-upload"), "no temp files left")
  fs.delete("/tmp-fs")
end)

test("a wrong passphrase gets no answer", function()
  setup()
  put("/tmp-fs/server/a.txt", "a")
  local net = loopback({ root = "/tmp-fs/server" }, "the real passphrase")
  local os_clock = os.clock
  local t = 0
  os.clock = function() t = t + 3 return t end   -- make the 5 s timeout expire immediately
  local res, err = filesync.sync("pull", "a wrong passphrase", net, 5, "/tmp-fs/client", {}, F.io())
  os.clock = os_clock
  ok(res == nil and err:find("no answer"))
  fs.delete("/tmp-fs")
end)

test("serve authenticates, ignores replays, and persists counters", function()
  setup()
  put("/tmp-fs/server/a.txt", "hello")
  local queue, replies = {}, {}
  local net = {
    receive = function() local m = table.remove(queue, 1) if m then return m.from, m.msg end end,
    send = function(id, msg) replies[#replies + 1] = msg end,
  }
  local good = secure.request(SECRET, "list", nil, 500)
  queue[#queue + 1] = { from = 9, msg = good }
  queue[#queue + 1] = { from = 9, msg = good }                                   -- replay
  queue[#queue + 1] = { from = 9, msg = secure.request("wrong pass!!", "list", nil, 501) }
  queue[#queue + 1] = { from = 9, msg = secure.request(SECRET, "list", nil, 502) }
  eq(filesync.serve({ root = "/tmp-fs/server" }, SECRET, net, nil, { rounds = 2 }), 2)
  eq(#replies, 2)
  ok(replies[1].ok and replies[1].data.files[1].path == "a.txt")
  local st = secure.loadState("/tmp-fs/state.json")
  eq(st.last["9"] or st.last[9], 502)
  fs.delete("/tmp-fs")
end)

test("commands: serve validation, pull usage errors", function()
  setup()
  local key = F.io({ "long enough passphrase" })
  eq(filesync.main({ "serve", "/tmp-fs/missing" }, key, { net = {} }), false)
  eq(filesync.main({ "pull" }, F.io(), { net = {} }), false)
  eq(filesync.main({ "explode" }, F.io(), { net = {} }), false)
  local short = F.io({ "short" })
  fs.delete("/tmp-fs/key")
  eq(filesync.main({ "pull", "5", "/tmp-fs/client" }, short, { net = {} }), false)
  ok(short.errs[1]:find("8 characters"))
  fs.delete("/tmp-fs")
end)

test("main pulls end to end through the loopback", function()
  setup()
  put("/tmp-fs/server/a.txt", "from the server")
  secure.saveKey("/tmp-fs/key", SECRET)
  local net = loopback({ root = "/tmp-fs/server" }, SECRET)
  local io = F.io()
  ok(filesync.main({ "pull", "5", "/tmp-fs/newdir" }, io, { net = net }))
  eq(read("/tmp-fs/newdir/a.txt"), "from the server")
  ok(io.said[#io.said]:find("1 copied"))
  ok(filesync.main({ "pull", "5", "/tmp-fs/newdir", "--dry-run" }, io, { net = net }))
  ok(io.said[#io.said]:find("Would copy 0"))
  fs.delete("/tmp-fs")
end)
