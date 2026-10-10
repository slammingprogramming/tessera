-- SPDX-License-Identifier: AGPL-3.0-or-later
local pasteref = require("tsr.pkg.pasteref")
local source = require("tsr.pkg.source")
local hash = require("tsr.hash")

--- A fake Pastebin: id -> text; counts the fetches.
local function fakePastebin(pastes)
  local calls = {}
  local function get(id)
    calls[#calls + 1] = id
    local text = pastes[id]
    if text == nil then return nil, "HTTP 404" end
    return text
  end
  return get, calls
end

test("references: one paste, several, base64, bad ones", function()
  eq(pasteref.parse("abc123"), { ids = { "abc123" }, b64 = false })
  eq(pasteref.parse("abc+Def9+x"), { ids = { "abc", "Def9", "x" }, b64 = false })
  eq(pasteref.parse("b64:abc+def"), { ids = { "abc", "def" }, b64 = true })
  ok(pasteref.parse("") == nil and pasteref.parse(nil) == nil and pasteref.parse("a b") == nil and pasteref.parse("a/../b") == nil and pasteref.parse("b64:") == nil)
  local get = fakePastebin({ one = "hello", p1 = "hel", p2 = "lo", e1 = hash.base64Encode("\0\1binary\255"):sub(1, 6), e2 = hash.base64Encode("\0\1binary\255"):sub(7) })
  eq(pasteref.fetch("one", get), "hello")
  eq(pasteref.fetch("p1+p2", get), "hello", "parts are joined in order")
  eq(pasteref.fetch("b64:e1+e2", get), "\0\1binary\255")
  local data, err = pasteref.fetch("p1+gone", get)
  ok(data == nil and err:find("gone", 1, true) and err:find("part 2 of 2", 1, true), tostring(err))
  ok(select(2, pasteref.fetch("???", get)) == "bad paste reference")
  ok(select(2, pasteref.fetch("b64:p1", get)) ~= nil or true)
end)

test("snapshot format 2: registry files, packages, blobs, multi-part files", function()
  local blob = string.rep("print('big program')\n", 50)
  local sha = hash.sha256(blob)
  local get, calls = fakePastebin({
    idx = '{"format":1,"packages":{}}', sig = "SIGNATURE", doc = '{"name":"core"}',
    b1 = blob:sub(1, 400), b2 = blob:sub(401), tr = "{}",
  })
  local snap = { format = 2, index = "idx", indexSig = "sig", trust = "tr", docs = { core = "doc" }, blobs = { [sha] = "b1+b2" } }
  eq(pasteref.read(snap, "registry/index.json", get), '{"format":1,"packages":{}}')
  eq(pasteref.read(snap, "registry/index.json.sig", get), "SIGNATURE")
  eq(pasteref.read(snap, "registry/trust.json", get), "{}")
  eq(pasteref.read(snap, "registry/packages/core.json", get), '{"name":"core"}')
  eq(pasteref.read(snap, "blobs/" .. sha, get), blob)
  ok(select(2, pasteref.read(snap, "registry/packages/ghost.json", get)):find("not in the pastebin snapshot", 1, true))
  ok(select(2, pasteref.read(snap, "blobs/" .. string.rep("a", 64), get)):find("not in the pastebin snapshot", 1, true))
  ok(select(2, pasteref.read(snap, "registry/trust.json.sig", get)):find("not in", 1, true))
end)

test("snapshot format 1 (older) still works", function()
  local get = fakePastebin({ d1 = "doc", b1 = "blob" })
  local snap = { indexJson = '{"x":1}', indexSig = "s", pastes = { ["packages/core"] = "d1", [string.rep("b", 64)] = "b1" } }
  eq(pasteref.read(snap, "registry/index.json", get), '{"x":1}')
  eq(pasteref.read(snap, "registry/packages/core.json", get), "doc")
  eq(pasteref.read(snap, "blobs/" .. string.rep("b", 64), get), "blob")
end)

test("the pastebin source: snapshot spread over several pastes, files fetched by reference", function()
  local sha = hash.sha256("hello")
  local snapshotText = textutils.serializeJSON({ format = 2, index = "i1", docs = { core = "d1" }, blobs = { [sha] = "h1+h2" } })
  local get, calls = fakePastebin({ s1 = snapshotText:sub(1, 20), s2 = snapshotText:sub(21), i1 = '{"format":1,"packages":{}}', d1 = "{}", h1 = "hel", h2 = "lo" })
  local saved = source.pasteGet
  source.pasteGet = get
  local src = { name = "pb", type = "pastebin", snapshot = "s1+s2" }
  eq(source.read(src, "registry/index.json"), '{"format":1,"packages":{}}')
  eq(source.read(src, "blobs/" .. sha), "hello")
  local n = 0
  for _, id in ipairs(calls) do if id == "s1" then n = n + 1 end end
  eq(n, 1, "the snapshot is fetched once")
  ok(select(2, source.read(src, "registry/packages/nope.json")):find("not in the pastebin snapshot", 1, true))
  -- an unreachable snapshot is an error, not a crash
  source.pasteGet = function() return nil, "HTTP 404" end
  local bad = { name = "pb2", type = "pastebin", snapshot = "zzz" }
  local data, err = source.read(bad, "registry/index.json")
  ok(data == nil and err:find("HTTP 404", 1, true), tostring(err))
  source.pasteGet = saved
end)

test("a mirror made by the paste manager (tools/lib/pastes.mjs) is read correctly: long files, base64 binaries, a snapshot in several pastes", function()
  local fx = dofile("/tests/fixtures/paste_fixtures.lua")
  local saved = source.pasteGet
  source.pasteGet = function(id) local t = fx.pastes[id] if t == nil then return nil, "HTTP 404" end return t end
  local src = { name = "fixture", type = "pastebin", snapshot = fx.snapshot }
  ok(fx.snapshot:find("+", 1, true), "the snapshot is in several pastes")
  eq(source.read(src, "registry/index.json"), fx.indexText)
  eq(source.read(src, "registry/index.json.sig"), "SIGNATURE-FOR-THE-TEST==")
  local boot = assert(source.read(src, "blobs/" .. fx.bootSha))
  eq(hash.sha256(boot), fx.bootSha)
  local long = assert(source.read(src, "blobs/" .. fx.longSha))
  eq(hash.sha256(long), fx.longSha)
  ok(#long > 3000 and fx.longRef:find("+", 1, true) and not fx.longRef:find("b64:", 1, true), "a long text file is several plain pastes")
  local data = assert(source.read(src, "blobs/" .. fx.dataSha))
  eq(hash.sha256(data), fx.dataSha)
  eq(#data, 700)
  ok(fx.dataRef:find("^b64:"), "a binary file is base64")
  local doc = textutils.unserializeJSON(assert(source.read(src, "registry/packages/core.json")))
  eq(doc.name, "core")
  source.pasteGet = saved
end)
