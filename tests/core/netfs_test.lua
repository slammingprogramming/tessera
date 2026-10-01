-- SPDX-License-Identifier: AGPL-3.0-or-later
local net = require("tsr.net")
local netfs = require("tsr.netfs")
local vfs = require("tsr.vfs")
local netbus = dofile("/tests/lib/netbus.lua")

local DIR = "/tmp-nfs"

local function put(path, data)
  local h = fs.open(path, "wb")
  h.write(data)
  h.close()
end

local function get(path)
  local h = fs.open(path, "rb")
  local s = h.readAll()
  h.close()
  return s
end

--- Server node (id 11, "alpha") exporting `exports`; client node (id 22, "beta") paired with it. fn(server, client, V) runs with
--- both daemons going; V is the routed fs API.
local function withShare(exports, fn)
  if fs.exists(DIR) then fs.delete(DIR) end
  fs.makeDir(DIR .. "/srv/sub")
  put(DIR .. "/srv/hello.txt", "hello\nworld\n")
  put(DIR .. "/srv/sub/deep.txt", "deep")
  put(DIR .. "/secret.txt", "outside the export")
  netfs.EXPORTS_PATH = DIR .. "/exports"
  local bus = netbus.new()
  local server = net.node({ id = 11, hostname = "alpha", transport = bus:transport(11), peersPath = DIR .. "/a.peers" })
  local client = net.node({ id = 22, hostname = "beta", transport = bus:transport(22), peersPath = DIR .. "/b.peers" })
  local failure
  parallel.waitForAny(
    function() server:run() end,
    function() client:run() end,
    function()
      local ok, err = pcall(function()
        parallel.waitForAll(
          function() ok(server:pairListen({ code = "ABCDE-FGHJK", timeout = 10 })) end,
          function() sleep(0.2) ok(client:pairConnect(11, "ABCDE-FGHJK", 5)) end)
        netfs.serve(server, exports)
        fn(server, client, vfs.fs)
      end)
      vfs.unmount(DIR .. "/mnt")
      if not ok then failure = err end
    end)
  if failure then error(failure, 0) end
end

local RO = { data = { path = DIR .. "/srv", readonly = true } }
local RW = { data = { path = DIR .. "/srv", readonly = false } }

test("a remote folder can be mounted and read like a local one", function()
  withShare(RO, function(server, client, V)
    ok(netfs.mount(client, "alpha", "data", DIR .. "/mnt"))
    ok(V.exists(DIR .. "/mnt/hello.txt"))
    ok(not V.exists(DIR .. "/mnt/nothing.txt"))
    ok(V.isDir(DIR .. "/mnt/sub"))
    ok(not V.isDir(DIR .. "/mnt/hello.txt"))
    local names = V.list(DIR .. "/mnt")
    table.sort(names)
    eq(names, { "hello.txt", "sub" })
    eq(V.getSize(DIR .. "/mnt/hello.txt"), 12)
    local h = V.open(DIR .. "/mnt/hello.txt", "r")
    eq(h.readLine(), "hello")
    eq(h.readLine(), "world")
    eq(h.readLine(), nil)
    h.close()
    h = V.open(DIR .. "/mnt/sub/deep.txt", "rb")
    eq(h.readAll(), "deep")
    h.close()
    eq(V.open(DIR .. "/mnt/missing", "r"), nil)
  end)
end)

test("large files cross in several chunks, byte for byte", function()
  withShare(RW, function(server, client, V)
    local data = {}
    for i = 0, 20000 do data[#data + 1] = string.char(i % 256) end
    data = table.concat(data)
    put(DIR .. "/srv/big.bin", data)
    ok(netfs.mount(client, "alpha", "data", DIR .. "/mnt"))
    local h = V.open(DIR .. "/mnt/big.bin", "rb")
    local got = h.readAll()
    h.close()
    eq(#got, #data)
    ok(got == data, "content differs")
    -- and back, through a write
    local w = V.open(DIR .. "/mnt/copy.bin", "wb")
    w.write(data)
    w.close()
    ok(get(DIR .. "/srv/copy.bin") == data, "uploaded content differs")
  end)
end)

test("read-only exports refuse changes", function()
  withShare(RO, function(server, client, V)
    ok(netfs.mount(client, "alpha", "data", DIR .. "/mnt"))
    local ok1, err = pcall(function() local h = V.open(DIR .. "/mnt/new.txt", "w") h.write("x") h.close() end)
    ok(not ok1 and tostring(err):find("read%-only"), tostring(err))
    ok(not pcall(V.delete, DIR .. "/mnt/hello.txt"))
    ok(fs.exists(DIR .. "/srv/hello.txt"))
    ok(V.isReadOnly(DIR .. "/mnt/hello.txt"))
  end)
end)

test("read-write exports can create, append, move and delete", function()
  withShare(RW, function(server, client, V)
    ok(netfs.mount(client, "alpha", "data", DIR .. "/mnt"))
    local w = V.open(DIR .. "/mnt/new.txt", "w")
    w.write("one\n")
    w.close()
    eq(get(DIR .. "/srv/new.txt"), "one\n")
    w = V.open(DIR .. "/mnt/new.txt", "a")
    w.writeLine("two")
    w.close()
    eq(get(DIR .. "/srv/new.txt"), "one\ntwo\n")
    V.makeDir(DIR .. "/mnt/made/deeper")
    ok(fs.isDir(DIR .. "/srv/made/deeper"))
    V.move(DIR .. "/mnt/new.txt", DIR .. "/mnt/moved.txt")
    ok(fs.exists(DIR .. "/srv/moved.txt") and not fs.exists(DIR .. "/srv/new.txt"))
    V.delete(DIR .. "/mnt/moved.txt")
    ok(not fs.exists(DIR .. "/srv/moved.txt"))
    -- the export root itself is protected
    ok(not pcall(V.delete, DIR .. "/mnt"))
    ok(fs.isDir(DIR .. "/srv"))
  end)
end)

test("paths cannot escape the export", function()
  withShare(RW, function(server, client, V)
    ok(netfs.mount(client, "alpha", "data", DIR .. "/mnt"))
    -- ask the server directly with traversal paths
    for _, evil in ipairs({ "../secret.txt", "sub/../../secret.txt", "/../secret.txt" }) do
      local res, err = client:call("alpha", "fs", "read", { export = "data", path = evil, offset = 0, length = 100 })
      -- the path is resolved inside the export, so it can only name something that does not exist there
      ok(res == nil and tostring(err):find("No such file"), evil .. ": " .. tostring(err))
    end
    ok(get(DIR .. "/secret.txt") == "outside the export")
  end)
end)

test("exports can be limited to named peers; unknown exports fail", function()
  local limited = { data = { path = DIR .. "/srv", readonly = true, peers = { "someone-else" } } }
  withShare(limited, function(server, client, V)
    local ok1, err = netfs.mount(client, "alpha", "data", DIR .. "/mnt")
    ok(ok1 == nil and tostring(err):find("not allowed"), tostring(err))
    local res, e2 = client:call("alpha", "fs", "stat", { export = "nope", path = "/" })
    ok(res == nil and e2:find("no such export"))
  end)
end)

test("the netfs command manages exports and mounts", function()
  withShare(RO, function(server, client, V)
    local function run(node, ...)
      local out = { said = {}, errs = {} }
      function out.say(t) out.said[#out.said + 1] = t end
      function out.err(t) out.errs[#out.errs + 1] = t end
      local r = netfs.run({ ... }, out, node)
      return r, table.concat(out.said, " / "), table.concat(out.errs, " / ")
    end
    netfs.MOUNTS_PATH = DIR .. "/mounts"
    local r, text = run(server, "export", "docs", DIR .. "/srv", "--peers", "beta,gamma")
    ok(r, text)
    local all = netfs.loadExports()
    eq(all.docs.peers, { "beta", "gamma" })
    eq(all.docs.readonly, true)
    r, text = run(server, "exports")
    ok(text:find("docs", 1, true) and text:find("beta,gamma", 1, true), text)
    local bad = run(server, "export", "x", "/does/not/exist")
    eq(bad, false)
    r = run(server, "unexport", "docs")
    ok(r)
    eq(next(netfs.loadExports()), nil)
    -- mount via command (the server already serves RO from withShare)
    r, text = run(client, "mount", "alpha", "data", DIR .. "/mnt")
    ok(r, text)
    ok(V.exists(DIR .. "/mnt/hello.txt"))
    r, text = run(client, "mounts")
    ok(text:find("alpha:data", 1, true), text)
    r = run(client, "umount", DIR .. "/mnt")
    ok(r)
    ok(not V.exists(DIR .. "/mnt/hello.txt"))
  end)
end)
