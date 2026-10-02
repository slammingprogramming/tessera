-- SPDX-License-Identifier: AGPL-3.0-or-later
local net = require("tsr.net")
local bencode = require("tsr.p2p.bencode")
local meta = require("tsr.p2p.meta")
local store = require("tsr.p2p.store")
local swarmMod = require("tsr.p2p.swarm")
local tracker = require("tsr.p2p.tracker")
local blobs = require("tsr.p2p.blobs")
local cli = require("tsr.p2p.cli")
local hash = require("tsr.hash")
local vfs = require("tsr.vfs")
local netbus = dofile("/tests/lib/netbus.lua")

local DIR = "/tmp-p2p"

local function reset()
  if fs.exists(DIR) then fs.delete(DIR) end
  fs.makeDir(DIR)
  cli.CONFIG = DIR .. "/p2p.cfg"
end

local function pattern(n, salt)
  local t = {}
  for i = 1, n do t[i] = string.char((i * 31 + (salt or 0) * 7 + math.floor(i / 256)) % 256) end
  return table.concat(t)
end

test("bencode: canonical encoding, round trip, strict decoding", function()
  eq(bencode.encode(42), "i42e")
  eq(bencode.encode(-7), "i-7e")
  eq(bencode.encode("spam"), "4:spam")
  eq(bencode.encode({ 1, 2, "x" }), "li1ei2e1:xe")
  eq(bencode.encode({ b = 1, a = { c = "d" } }), "d1:ad1:c1:de1:bi1ee", "keys are sorted")
  local v = { name = "a", list = { 1, 2, { x = "y" } }, n = 5, empty = {} }
  local back = assert(bencode.decode(bencode.encode(v)))
  eq(back.list[3].x, "y")
  eq(back.n, 5)
  eq(bencode.encode(back), bencode.encode(v), "re-encoding is identical")
  eq(bencode.encode("binary\0\255data"), "12:binary\0\255data")
  ok(not pcall(bencode.encode, 1.5))
  for _, bad in ipairs({ "", "i01e", "i-0e", "ie", "l", "d1:b1:x1:a1:ye", "5:ab", "i1ex", "d1:ai1e", "x", "di1e1:ae" }) do
    ok(bencode.decode(bad) == nil, "should reject: " .. bad)
  end
end)

test("metainfo: single file, folder, round trip, tampering, magnet links", function()
  reset()
  local data = pattern(5000, 1)
  vfs.writeFile(DIR .. "/one.bin", data, true)
  local m = assert(meta.create(DIR .. "/one.bin", { pieceLength = 1024, tracker = "tracker1" }))
  eq(meta.pieceCount(m), 5)
  eq(meta.pieceLength(m, 1), 1024)
  eq(meta.pieceLength(m, 5), 5000 - 4 * 1024)
  eq(m.info.length, 5000)
  eq(m.infohash, hash.sha256(m.infoRaw))
  eq(meta.pieceHash(m, 2), hash.fromHex(hash.sha256(data:sub(1025, 2048))))
  local parsed = assert(meta.parse(meta.encode(m)))
  eq(parsed.infohash, m.infohash)
  eq(parsed.announce, "tracker1")
  eq(parsed.total, 5000)
  -- folder
  fs.makeDir(DIR .. "/dir/sub")
  vfs.writeFile(DIR .. "/dir/a.txt", pattern(1500, 2), true)
  vfs.writeFile(DIR .. "/dir/sub/b.txt", pattern(2600, 3), true)
  vfs.writeFile(DIR .. "/dir/empty", "", true)
  local d = assert(meta.create(DIR .. "/dir", { pieceLength = 1024 }))
  eq(d.total, 4100)
  eq(meta.pieceCount(d), 5)
  eq(#meta.files(d), 3)
  eq(meta.files(d)[2].path, { "empty" })
  eq(d.info.files[3].path, { "sub", "b.txt" })
  -- an empty file is a valid torrent with one empty piece
  vfs.writeFile(DIR .. "/nothing", "", true)
  local e = assert(meta.create(DIR .. "/nothing"))
  eq(meta.pieceCount(e), 1)
  eq(meta.pieceLength(e, 1), 0)
  -- tampering with what the file claims
  local doc = bencode.decode(meta.encode(m))
  doc.info.pieces = doc.info.pieces:sub(1, -33)
  ok(meta.parse(bencode.encode(doc)) == nil, "piece count must match the size")
  doc = bencode.decode(meta.encode(m))
  doc.info.name = "../../etc/startup"
  ok(meta.parse(bencode.encode(doc)) == nil, "unsafe name")
  doc = bencode.decode(meta.encode(d))
  doc.info.files[1].path = { "..", "x" }
  ok(meta.parse(bencode.encode(doc)) == nil, "unsafe path")
  ok(meta.parse("garbage") == nil)
  ok(select(2, meta.create(DIR .. "/missing")))
  -- metadata received from the network must hash to the info hash
  ok(meta.fromInfoRaw(m.infoRaw, m.infohash))
  ok(meta.fromInfoRaw(m.infoRaw .. " ", m.infohash) == nil)
  -- magnet
  local uri = meta.magnet(m)
  ok(uri:find("^magnet:%?xt=urn:btmh:1220" .. m.infohash))
  local mg = assert(meta.parseMagnet(uri))
  eq(mg.infohash, m.infohash)
  eq(mg.name, "one.bin")
  eq(mg.trackers, { "tracker1" })
  ok(meta.parseMagnet("magnet:?dn=x") == nil)
  ok(meta.parseMagnet("http://x") == nil)
end)

test("storage: seeding reads across file boundaries, downloads resume and assemble without keeping two copies", function()
  reset()
  fs.makeDir(DIR .. "/dir/sub")
  local a, b = pattern(1500, 2), pattern(2600, 3)
  vfs.writeFile(DIR .. "/dir/a.txt", a, true)
  vfs.writeFile(DIR .. "/dir/sub/b.txt", b, true)
  local m = assert(meta.create(DIR .. "/dir", { pieceLength = 1024 }))
  local seed = store.seed(m, DIR .. "/dir")
  eq(seed.read(2), (a .. b):sub(1025, 2048), "piece 2 spans both files")
  ok(seed.verify(1) and seed.verify(5))
  eq(seed.bitfield(), "11111")
  vfs.writeFile(DIR .. "/dir/sub/b.txt", b:sub(1, -2) .. "X", true)          -- a damaged file
  local damaged = store.seed(m, DIR .. "/dir")
  eq(damaged.bitfield(), "11110", "only the last piece fails")
  vfs.writeFile(DIR .. "/dir/sub/b.txt", b, true)
  -- download storage
  local st = store.download(m, DIR .. "/out")
  eq(st.owned(), 0)
  local ok1, why = st.put(1, string.rep("x", 1024))
  ok(not ok1 and why:find("hash", 1, true))
  ok(not st.put(1, "short"))
  for i = 1, 3 do ok(st.put(i, seed.read(i))) end
  eq(st.bitfield(), "11100")
  -- a new object on the same folder resumes
  local again = store.download(m, DIR .. "/out")
  eq(again.owned(), 3)
  for i = 4, 5 do ok(again.put(i, seed.read(i))) end
  ok(again.complete())
  local path = assert(again.assemble())
  eq(path, DIR .. "/out/dir")
  eq(vfs.readFile(DIR .. "/out/dir/a.txt", true), a)
  eq(vfs.readFile(DIR .. "/out/dir/sub/b.txt", true), b)
  ok(not fs.exists(again.work), "the work folder is gone")
  -- a corrupt piece file is dropped when resuming
  local st2 = store.download(m, DIR .. "/out2")
  st2.put(1, seed.read(1))
  vfs.writeFile(st2.work .. "/1", "corrupt", true)
  eq(store.download(m, DIR .. "/out2").owned(), 0)
end)

--- N nodes (ids 11, 12, ...) with swarms on one in-memory network; fn(swarms, nodes, bus) runs while all of them answer messages.
local function withSwarm(count, fn, opts)
  opts = opts or {}
  local bus = netbus.new()
  local nodes, swarms, loops = {}, {}, {}
  for i = 1, count do
    local id = 10 + i
    nodes[i] = net.node({ id = id, hostname = "n" .. id, transport = bus:transport(id), peersPath = DIR .. "/p" .. id })
    swarms[i] = swarmMod.new(nodes[i], { uploadRate = opts.uploadRate or 10000000, maxRequesters = opts.maxRequesters })
    loops[i] = function() nodes[i]:run() end
  end
  local failure
  loops[#loops + 1] = function()
    local okRun, err = pcall(fn, swarms, nodes, bus)
    if not okRun then failure = err end
  end
  parallel.waitForAny(table.unpack(loops))
  if failure then error(failure, 0) end
end

local function makeContent(name, size, pieceLength, salt)
  vfs.writeFile(DIR .. "/" .. name, pattern(size, salt), true)
  return assert(meta.create(DIR .. "/" .. name, { pieceLength = pieceLength }))
end

test("a leecher downloads from a seeder, verifies, resumes and then seeds for the next one", function()
  reset()
  local m = makeContent("movie.bin", 30000, 1024, 5)               -- 30 pieces
  withSwarm(3, function(sw)
    sw[1]:addSeed(m, DIR .. "/movie.bin")
    local progress = {}
    local path, err = sw[2]:download(m, DIR .. "/c2", { onProgress = function(o, c) progress[#progress + 1] = o end })
    ok(path, err)
    eq(vfs.readFile(path, true), pattern(30000, 5))
    ok(#progress >= 30 and progress[#progress] == 30)
    ok(sw[1].uploaded >= 30000)
    -- the seeder goes away; the new seed serves the next downloader
    sw[1]:removeSeed(m.infohash)
    local path3, err3 = sw[3]:download(m, DIR .. "/c3", {})
    ok(path3, err3)
    eq(vfs.readFile(path3, true), pattern(30000, 5))
  end)
end)

test("several seeders share the work; a seeder that sends bad pieces is ignored and the download still finishes", function()
  reset()
  local m = makeContent("big.bin", 24000, 1024, 9)
  withSwarm(4, function(sw, nodes, bus)
    sw[1]:addSeed(m, DIR .. "/big.bin")
    sw[2]:addSeed(m, DIR .. "/big.bin")
    -- node 12 corrupts every piece it sends
    bus.filter = function(from, to, msg)
      if from == 12 and msg.k == "piece" then
        local raw = hash.base64Decode(msg.data)
        msg.data = hash.base64Encode(raw:sub(1, -2) .. string.char((raw:byte(-1) + 1) % 256))
        return msg
      end
    end
    local path, err = sw[3]:download(m, DIR .. "/c3", { maxWorkers = 2 })
    ok(path, err)
    eq(vfs.readFile(path, true), pattern(24000, 9))
    ok(sw[3].banned[12] ~= nil, "the lying peer is banned")
    ok(sw[1].uploaded > 0)
  end)
end)

test("a seeder with a damaged file never serves it; downloads from nobody fail cleanly", function()
  reset()
  local m = makeContent("dmg.bin", 4096, 1024, 4)
  vfs.writeFile(DIR .. "/dmg.bin", pattern(4096, 4):sub(1, 2000) .. "damage" .. pattern(4096, 4):sub(2007), true)
  withSwarm(2, function(sw)
    local entry = sw[1]:addSeed(m, DIR .. "/dmg.bin")
    local path, err = sw[2]:download(m, DIR .. "/c", { stall = 3 })
    ok(path == nil, "pieces 2 and 3 are damaged: the download cannot complete")
    ok(tostring(err):find("stall", 1, true) or tostring(err):find("no peers", 1, true), tostring(err))
  end)
  reset()
  withSwarm(2, function(sw)
    local path, err = sw[2]:download(m, DIR .. "/d", { stall = 2 })
    ok(path == nil and err:find("no peers", 1, true), tostring(err))
  end)
end)

test("magnet links: the metadata comes from the swarm and must match the hash", function()
  reset()
  local m = makeContent("mag.bin", 9000, 2048, 6)
  withSwarm(3, function(sw, nodes, bus)
    sw[1]:addSeed(m, DIR .. "/mag.bin")
    local got, err = sw[2]:fetchMeta(m.infohash, {})
    ok(got, err)
    eq(got.infohash, m.infohash)
    eq(got.info.name, "mag.bin")
    -- a seeder that lies about the metadata is detected
    bus.filter = function(from, to, msg)
      if msg.k == "meta" then msg.data = hash.base64Encode("garbage" .. hash.base64Decode(msg.data)) return msg end
    end
    local bad, berr = sw[3]:fetchMeta(m.infohash, {})
    ok(bad == nil and berr:find("could not get", 1, true), tostring(berr))
    bus.filter = nil
    eq(select(2, sw[3]:fetchMeta(string.rep("0", 64), {})) ~= nil, true)
  end)
end)

test("the seeder limits its upload rate and the number of computers it serves", function()
  reset()
  local m = makeContent("slow.bin", 16384, 1024, 3)
  withSwarm(3, function(sw, nodes, bus)
    sw[1].uploadRate = 4096
    sw[1].bucket = { tokens = 4096, last = sw[1].clock() }
    sw[1]:addSeed(m, DIR .. "/slow.bin")
    local busy, served = 0, 0
    bus.filter = function(from, to, msg)
      if from == 11 and msg.k == "no" and msg.why == "busy" then busy = busy + 1 end
      if from == 11 and msg.k == "piece" then served = served + 1 end
    end
    local path, err = sw[2]:download(m, DIR .. "/c2", { stall = 60 })
    ok(path, err)
    ok(busy > 0, "the seeder asked the downloader to slow down")
    eq(served, 16)
  end, { uploadRate = 4096 })
  reset()
  local m2 = makeContent("cap.bin", 4096, 1024, 8)
  withSwarm(4, function(sw, nodes, bus)
    sw[1].maxRequesters = 1
    sw[1]:addSeed(m2, DIR .. "/cap.bin")
    sw[1]:handle(12, { k = "req", ih = m2.infohash, i = 1 })
    local replies = {}
    bus.filter = function(from, to, msg) if from == 11 and to == 13 then replies[#replies + 1] = msg end end
    sw[1]:handle(13, { k = "req", ih = m2.infohash, i = 1 })
    sleep(0.2)
    eq(replies[1].k, "no")
    eq(replies[1].why, "busy")
  end)
end)

test("tracker: announce, peers, scrape, expiry, limits; downloads can find the seeder through it", function()
  reset()
  local m = makeContent("tr.bin", 6000, 1024, 2)
  withSwarm(3, function(sw, nodes, bus)
    local t = tracker.attach(sw[3])
    local clockNow = 1000
    sw[1]:addSeed(m, DIR .. "/tr.bin")
    local res, err = sw[1]:announce(13, m.infohash, "started", 0)
    ok(res, err)
    eq(res.peers, {})
    eq(res.seeders, 1)
    res = sw[2]:announce(13, m.infohash, "started", 6000)
    eq(res.peers, { 11 })
    eq(res.leechers, 1)
    eq(tracker.summary(t), { swarms = 1, peers = 2 })
    -- the broadcast "find" never reaches the seeder (out of range): the tracker leads the way
    local dropped = {}
    bus.filter = function(from, to, msg)
      if msg.k == "find" and from == 12 and to == 11 and not dropped[1] then dropped[1] = true return false end
    end
    local path, derr = sw[2]:download(m, DIR .. "/c2", { trackers = { 13 } })
    ok(path, derr)
    eq(vfs.readFile(path, true), pattern(6000, 2))
    -- bad announcements are ignored; stopping removes the peer
    sw[2]:announce(13, m.infohash, "stopped", 0)
    eq(tracker.summary(t).peers, 1)
    sw[1]:send(13, "announce", { ih = "nothex", event = "started" })
    sleep(0.2)
    eq(tracker.summary(t).swarms, 1)
  end)
end)

test("package blobs travel between computers; modified files are never served", function()
  reset()
  local content = pattern(40000, 7)
  local sha = hash.sha256(content)
  vfs.writeFile(DIR .. "/blobs/" .. sha, content, true)
  blobs.CACHES = { DIR .. "/blobs" }
  blobs.refresh()
  withSwarm(3, function(sw, nodes, bus)
    blobs.attach(sw[1])
    local data, err = sw[2]:fetchBlob(sha, { wait = 0.6 })
    ok(data, err)
    eq(data, content)
    eq(blobs.lookup(string.rep("0", 64)), nil)
    eq(blobs.lookup("short"), nil)
    -- nobody has it
    local none, nerr = sw[2]:fetchBlob(string.rep("a", 64), { wait = 0.4 })
    ok(none == nil and nerr:find("no computer", 1, true), tostring(nerr))
    -- the seeder's copy gets modified: it must notice and refuse
    sw[1].blobVerified = {}
    vfs.writeFile(DIR .. "/blobs/" .. sha, content:sub(1, -2) .. "!", true)
    local bad, berr = sw[3]:fetchBlob(sha, { wait = 0.6 })
    ok(bad == nil, "a modified file must not be served")
    -- a lying holder: data that fails the hash is rejected and the sender ignored
    vfs.writeFile(DIR .. "/blobs/" .. sha, content, true)
    sw[1].blobVerified = { [sha] = true }               -- pretend it was verified before the damage
    bus.filter = function(from, to, msg)
      if msg.k == "bdata" then msg.data = hash.base64Encode(string.rep("z", #hash.base64Decode(msg.data))) return msg end
    end
    local liar, lerr = sw[3]:fetchBlob(sha, { wait = 0.6 })
    ok(liar == nil and lerr:find("checksum", 1, true), tostring(lerr))
    ok(sw[3].banned[11] ~= nil)
  end)
  blobs.CACHES = { "/var/cache/tsr/offline/blobs", "/var/cache/tsr/mirror/blobs" }
  blobs.refresh()
end)

test("package manager source 'p2p' installs payloads from a neighbour", function()
  reset()
  local source = require("tsr.pkg.source")
  require("tsr.pkg.src_p2p")
  local content = "return 'from the swarm'"
  local sha = hash.sha256(content)
  vfs.writeFile(DIR .. "/blobs/" .. sha, content, true)
  blobs.CACHES = { DIR .. "/blobs" }
  blobs.refresh()
  withSwarm(2, function(sw, nodes)
    blobs.attach(sw[1])
    local got, err = source.fetchers.p2p.read({ name = "swarm", type = "p2p", node = nodes[2], wait = 0.5 }, "blobs/" .. sha)
    eq(got, content, tostring(err))
    local no, nerr = source.fetchers.p2p.read({ type = "p2p", node = nodes[2] }, "registry/index.json")
    ok(no == nil and nerr:find("contents only", 1, true))
  end)
  blobs.CACHES = { "/var/cache/tsr/offline/blobs", "/var/cache/tsr/mirror/blobs" }
  blobs.refresh()
end)

local function io()
  local t = { lines = {}, errs = {} }
  function t.say(s) t.lines[#t.lines + 1] = s end
  function t.err(s) t.errs[#t.errs + 1] = s end
  function t.progress() end
  function t.text() return table.concat(t.lines, "\n") end
  return t
end

test("torrent command: create, info, seed registration, get with a magnet link", function()
  reset()
  local content = pattern(7000, 11)
  vfs.writeFile(DIR .. "/doc.bin", content, true)
  local o = io()
  ok(cli.run({ "create", DIR .. "/doc.bin", "--piece", "1024", "-o", DIR .. "/doc.tsrt" }, o), table.concat(o.errs, "|"))
  ok(o.text():find("magnet:", 1, true) and fs.exists(DIR .. "/doc.tsrt"), o.text())
  o = io()
  ok(cli.run({ "info", DIR .. "/doc.tsrt" }, o))
  ok(o.text():find("7 piece", 1, true) or o.text():find("7000", 1, true), o.text())
  o = io()
  ok(not cli.run({ "info", DIR .. "/nothing.tsrt" }, o))
  o = io()
  ok(cli.run({ "seed", DIR .. "/doc.tsrt", DIR .. "/doc.bin" }, o), table.concat(o.errs, "|"))
  eq(#cli.config().seeds, 1)
  o = io()
  ok(cli.run({ "list" }, o))
  ok(o.text():find("doc.bin", 1, true), o.text())
  ok(cli.run({ "tracker", "on" }, io()))
  ok(cli.config().tracker)
  ok(not cli.run({ "tracker", "maybe" }, io()))
  local m = assert(meta.parse(vfs.readFile(DIR .. "/doc.tsrt", true)))
  withSwarm(2, function(sw, nodes)
    sw[1]:addSeed(m, DIR .. "/doc.bin")
    o = io()
    ok(cli.run({ "get", meta.magnet(m), "-d", DIR .. "/dl" }, o, nodes[2]), table.concat(o.errs, "|"))
    eq(vfs.readFile(DIR .. "/dl/doc.bin", true), content)
    ok(o.text():find("Done:", 1, true))
  end)
  o = io()
  ok(cli.run({ "unseed", m.infohash:sub(1, 8) }, o))
  eq(#cli.config().seeds, 0)
end)
