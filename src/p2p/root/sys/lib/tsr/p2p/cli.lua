-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The torrent command: share and fetch files between the computers of one game world, BitTorrent-style (never the real Internet).
--   torrent create <file|folder> [--name N] [--piece 16384] [--tracker host] [-o file.tsrt]    hash content into a torrent file
--   torrent info <file.tsrt | magnet:...>                                                    what is in it
--   torrent seed <file.tsrt> <path>                                                          offer content (also kept for the daemon)
--   torrent get <file.tsrt | magnet:...> [-d folder] [--tracker host]                         download and then keep seeding
--   torrent list | unseed <infohash prefix> | tracker on|off | packages on|off | status
-- The daemon (service torrentd) seeds what `torrent seed` registered, and runs a tracker or shares package files if you turn those on.
local meta = require("tsr.p2p.meta")
local swarmMod = require("tsr.p2p.swarm")
local vfs = require("tsr.vfs")
local util = require("tsr.util")

local M = {}

M.CONFIG = "/etc/tsr/p2p.cfg"

local function defaultIO()
  local io = {}
  local function color(c) if term.isColor() then term.setTextColor(c) end end
  function io.say(t) print(t) end
  function io.err(t) color(colors.red) print(t) color(colors.white) end
  function io.progress(owned, count) write(("\r%d/%d pieces (%d%%)  "):format(owned, count, count > 0 and math.floor(owned * 100 / count) or 100)) end
  return io
end

--- The configuration: { seeds = { { meta = path, path = path } }, tracker = bool, packages = bool, uploadRate = bytes/s }.
function M.config()
  local c = vfs.readTable(M.CONFIG) or {}
  c.seeds = c.seeds or {}
  return c
end

function M.saveConfig(c) return vfs.writeTable(M.CONFIG, c) end

local function flagsOf(args)
  local flags, words, i = {}, {}, 1
  local VALUE = { name = true, piece = true, tracker = true, o = true, d = true }
  while i <= #args do
    local a = args[i]
    local name = a:match("^%-%-(.+)$") or a:match("^%-(%a)$")
    if name and VALUE[name] then flags[name] = args[i + 1] i = i + 1
    elseif name then flags[name] = true
    else words[#words + 1] = a end
    i = i + 1
  end
  return flags, words
end

local function loadMeta(spec)
  if tostring(spec):sub(1, 7) == "magnet:" then return nil, meta.parseMagnet(spec) end
  local data = vfs.readFile(spec, true)
  if not data then return nil, nil, "cannot read " .. tostring(spec) end
  local m, err = meta.parse(data)
  if not m then return nil, nil, err end
  return m
end

local function describe(m)
  local lines = {
    ("name:      %s"):format(m.info.name),
    ("size:      %s in %d piece(s) of %s"):format(util.fmtBytes(m.total), meta.pieceCount(m), util.fmtBytes(m.info["piece length"])),
    ("info hash: %s"):format(m.infohash),
  }
  if m.info.files then lines[#lines + 1] = ("files:     %d"):format(#m.info.files) end
  if m.announce then lines[#lines + 1] = "tracker:   " .. tostring(m.announce) end
  if m.comment then lines[#lines + 1] = "comment:   " .. tostring(m.comment) end
  return lines
end

function M.run(args, io, node)
  io = io or defaultIO()
  local flags, words = flagsOf(args)
  local sub = table.remove(words, 1) or "status"

  if sub == "create" then
    local path = words[1]
    if not path then io.err("usage: torrent create <file|folder> [--name N] [--piece bytes] [--tracker host] [-o file.tsrt]") return false end
    io.say("Hashing " .. path .. " ...")
    local m, err = meta.create(path, { name = flags.name, pieceLength = tonumber(flags.piece), tracker = flags.tracker })
    if not m then io.err(tostring(err)) return false end
    local out = flags.o or (fs.getName(path) .. ".tsrt")
    vfs.writeFile(out, meta.encode(m), true)
    for _, l in ipairs(describe(m)) do io.say(l) end
    io.say("wrote " .. out)
    io.say("magnet:  " .. meta.magnet(m))
    return true

  elseif sub == "info" then
    local m, magnet, err = loadMeta(words[1] or "")
    if err then io.err(err) return false end
    if magnet then
      io.say("magnet link: info hash " .. magnet.infohash .. (magnet.name and (", name " .. magnet.name) or ""))
    else
      for _, l in ipairs(describe(m)) do io.say(l) end
    end
    return true

  elseif sub == "seed" then
    local m, _, err = loadMeta(words[1] or "")
    if not m then io.err(err or "usage: torrent seed <file.tsrt> <path>") return false end
    local path = words[2]
    if not path or not fs.exists(path) then io.err("usage: torrent seed <file.tsrt> <path to the content>") return false end
    local c = M.config()
    for _, s in ipairs(c.seeds) do if s.meta == words[1] then s.path = path m = nil end end
    if m then c.seeds[#c.seeds + 1] = { meta = "/" .. fs.combine(words[1], ""), path = "/" .. fs.combine(path, "") } end
    M.saveConfig(c)
    io.say("Registered. The torrentd service seeds it (svc restart torrentd).")
    return true

  elseif sub == "get" then
    local m, magnet, err = loadMeta(words[1] or "")
    if err then io.err(err) return false end
    node = node or require("tsr.net").default()
    local sw = swarmMod.forNode(node)
    local trackers = {}
    if flags.tracker then trackers[1] = flags.tracker end
    if magnet then
      for _, t in ipairs(magnet.trackers) do trackers[#trackers + 1] = t end
      io.say("Asking the swarm for the torrent's description ...")
      m, err = sw:fetchMeta(magnet.infohash, trackers)
      if not m then io.err(tostring(err)) return false end
    end
    for _, l in ipairs(describe(m)) do io.say(l) end
    local dest = flags.d or "downloads"
    if not fs.exists(dest) then fs.makeDir(dest) end
    local path, derr = sw:download(m, dest, { trackers = trackers, onProgress = io.progress })
    if io.progress then io.say("") end
    if not path then io.err(tostring(derr)) return false end
    io.say("Done: " .. path .. "  (now seeding it for others while this computer keeps running its swarm)")
    return true

  elseif sub == "list" or sub == "status" then
    local c = M.config()
    io.say(("tracker role: %s    share packages: %s"):format(c.tracker and "on" or "off", c.packages and "on" or "off"))
    if #c.seeds == 0 then io.say("no registered seeds") end
    for _, s in ipairs(c.seeds) do
      local m = loadMeta(s.meta)
      io.say(("%s  %s  ->  %s"):format(m and m.infohash:sub(1, 12) or "????????????", m and m.info.name or "(unreadable)", s.path))
    end
    if node then
      local sw = swarmMod.forNode(node)
      local n = 0
      for _ in pairs(sw.seeds) do n = n + 1 end
      io.say(("serving now: %d torrent(s), uploaded %s, downloaded %s"):format(n, util.fmtBytes(sw.uploaded), util.fmtBytes(sw.downloaded)))
    end
    return true

  elseif sub == "unseed" then
    local prefix = words[1]
    if not prefix then io.err("usage: torrent unseed <info hash prefix>") return false end
    local c, keep, removed = M.config(), {}, 0
    for _, s in ipairs(c.seeds) do
      local m = loadMeta(s.meta)
      if m and m.infohash:sub(1, #prefix) == prefix then removed = removed + 1 else keep[#keep + 1] = s end
    end
    c.seeds = keep
    M.saveConfig(c)
    io.say(removed > 0 and "removed" or "no such seed")
    return removed > 0

  elseif sub == "tracker" or sub == "packages" then
    local c = M.config()
    if words[1] ~= "on" and words[1] ~= "off" then io.err("usage: torrent " .. sub .. " on|off") return false end
    c[sub] = words[1] == "on"
    M.saveConfig(c)
    io.say(sub .. " is now " .. words[1] .. " (restart the service: svc restart torrentd)")
    return true
  end

  io.err("usage: torrent create | info | seed | get | list | unseed | tracker on|off | packages on|off")
  return false
end

function M.main(args) return M.run(args) end

--- The torrentd service: serve the registered seeds, the tracker role and package payloads as configured.
function M.daemon()
  local net = require("tsr.net")
  local c = M.config()
  local sw = swarmMod.forNode(net.default(), { uploadRate = c.uploadRate })
  for _, s in ipairs(c.seeds) do
    local m, _, err = loadMeta(s.meta)
    if m and fs.exists(s.path) then sw:addSeed(m, s.path) else require("tsr.log").get("p2p").warn("cannot seed %s: %s", tostring(s.meta), tostring(err or "content missing")) end
  end
  if c.tracker then require("tsr.p2p.tracker").attach(sw) end
  if c.packages then require("tsr.p2p.blobs").attach(sw) end
  while true do os.pullEvent("p2p_never") end
end

return M
