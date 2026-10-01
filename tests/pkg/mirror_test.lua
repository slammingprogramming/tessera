-- SPDX-License-Identifier: AGPL-3.0-or-later
local net = require("tsr.net")
local pkg = require("tsr.pkg")
local source = require("tsr.pkg.source")
local config = require("tsr.config")
local mirror = require("tsr.pkgmirror")
local hash = require("tsr.hash")
local vfs = require("tsr.vfs")
local testenv = dofile("/tests/lib/testenv.lua")
local netbus = dofile("/tests/lib/netbus.lua")

local DIR = "/tmp-mirror"

local function publish()
  testenv.reset()
  return testenv.publish({
    app = { version = "1.0.0", requires = { lib = ">=1.0.0" }, files = { [testenv.ROOT .. "/bin/app.lua"] = "print('app')" } },
    lib = { version = "1.2.0", files = { [testenv.ROOT .. "/lib/lib.lua"] = "return 1" } },
    other = { version = "0.5.0", files = { [testenv.ROOT .. "/other.lua"] = "return 'other'" } },
  })
end

local function setupMirror()
  if fs.exists(DIR) then fs.delete(DIR) end
  mirror.cacheDir = DIR .. "/cache"
  mirror.upstreamList = function() return { { name = "up", type = "dir", path = testenv.REG } } end
end

test("the mirror serves registry files and caches them", function()
  local b = publish()
  setupMirror()
  local index = mirror.get("registry/index.json")
  ok(index and textutils.unserializeJSON(index).packages.app)
  ok(fs.exists(DIR .. "/cache/registry/index.json"))
  local sha = next(b.blobs)
  eq(mirror.get("blobs/" .. sha), b.blobs[sha])
  ok(fs.exists(DIR .. "/cache/blobs/" .. sha))
  -- stale beats nothing: upstream disappears, the cache still answers
  fs.delete(testenv.REG)
  eq(mirror.get("blobs/" .. sha), b.blobs[sha])
  ok(mirror.get("registry/index.json"))
  local nothing, err = mirror.get("registry/packages/ghost.json")
  ok(nothing == nil and err)
end)

test("only registry paths are served", function()
  publish()
  setupMirror()
  for _, rel in ipairs({ "../etc/tsr/users.db", "/etc/passwd", "registry/../../x", "registry/packages/../index.json", "blobs/zz",
                         "blobs/" .. string.rep("a", 63), "registry/packages/a b.json", 5 }) do
    local data, err = mirror.get(rel)
    ok(data == nil and err == "bad path", tostring(rel) .. " -> " .. tostring(err))
  end
end)

test("a tampered upstream blob is not cached or served", function()
  local b = publish()
  setupMirror()
  local sha = next(b.blobs)
  vfs.writeFile(testenv.REG .. "/blobs/" .. sha, "evil", true)
  local data, err = mirror.get("blobs/" .. sha)
  ok(data == nil and err:find("verification"), tostring(err))
  ok(not fs.exists(DIR .. "/cache/blobs/" .. sha))
end)

test("prefetch downloads packages with their dependencies", function()
  local b = publish()
  setupMirror()
  local res = mirror.prefetch({ "app" })
  eq(res.packages, 2)
  eq(res.blobs, 2)
  eq(res.problems, {})
  ok(not fs.exists(DIR .. "/cache/registry/packages/other.json"))
  res = mirror.prefetch(nil)
  eq(res.packages, 3)
  eq(res.blobs, 3)
  fs.delete(testenv.REG)   -- now fully offline
  ok(mirror.get("registry/packages/other.json"))
end)

test("clients install through a lan source", function()
  publish()
  setupMirror()
  local bus = netbus.new()
  local server = net.node({ id = 11, hostname = "store", transport = bus:transport(11), peersPath = DIR .. "/s.peers" })
  local client = net.node({ id = 22, hostname = "shop", transport = bus:transport(22), peersPath = DIR .. "/c.peers" })
  require("tsr.pkg.src_lan").node = client
  config.set("pkg.sources", { { name = "lan-store", type = "lan", peer = "store" } }, "user")
  local failure
  parallel.waitForAny(
    function() server:run() end,
    function() client:run() end,
    function()
      local okRun, err = pcall(function()
        parallel.waitForAll(
          function() ok(server:pairListen({ code = "ABCDE-FGHJK", timeout = 10 })) end,
          function() sleep(0.2) ok(client:pairConnect(11, "ABCDE-FGHJK", 5)) end)
        mirror.serve(server)
        local list = source.update()
        eq(list["lan-store"], true)
        local doc = source.findPackage("app")
        ok(doc and doc.latest == "1.0.0")
        local done, plan = pkg.installPackages({ "app" })
        ok(done, tostring(plan))
        eq(vfs.readFile(testenv.ROOT .. "/bin/app.lua"), "print('app')")
        eq(vfs.readFile(testenv.ROOT .. "/lib/lib.lua"), "return 1")
        -- the mirror cached what it served
        ok(fs.exists(DIR .. "/cache/registry/index.json"))
      end)
      if not okRun then failure = err end
    end)
  require("tsr.pkg.src_lan").node = nil
  if failure then error(failure, 0) end
end)

test("an unpaired computer cannot read from the mirror", function()
  publish()
  setupMirror()
  local bus = netbus.new()
  local server = net.node({ id = 11, hostname = "store", transport = bus:transport(11), peersPath = DIR .. "/s.peers" })
  local stranger = net.node({ id = 33, hostname = "eve", transport = bus:transport(33), peersPath = DIR .. "/e.peers" })
  require("tsr.pkg.src_lan").node = stranger
  local result, why
  parallel.waitForAny(
    function() server:run() end,
    function()
      mirror.serve(server)
      result, why = source.read({ name = "lan-store", type = "lan", peer = "store" }, "registry/index.json")
    end)
  require("tsr.pkg.src_lan").node = nil
  ok(result == nil and tostring(why):find("not paired"), tostring(why))
end)

test("the pkgmirror command", function()
  publish()
  setupMirror()
  local function run(...)
    local io = { said = {}, errs = {} }
    function io.say(t) io.said[#io.said + 1] = t end
    function io.err(t) io.errs[#io.errs + 1] = t end
    local r = mirror.run({ ... }, io)
    return r, table.concat(io.said, " / "), table.concat(io.errs, " / ")
  end
  local r, text = run("status")
  ok(r and text:find("0 files", 1, true), text)
  r, text = run("prefetch", "app")
  ok(r and text:find("cached 2 packages, 2 files", 1, true), text)
  r, text = run("status")
  ok(text:find("files", 1, true) and not text:find("0 files", 1, true), text)
  config.set("pkg.sources", {}, "user")
  r, text = run("add", "store")
  ok(r, text)
  eq(config.get("pkg.sources")[1], { name = "lan-store", type = "lan", peer = "store" })
  r = run("clear")
  ok(r and not fs.exists(DIR .. "/cache"))
  eq(run("bogus"), false)
end)
