-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Regression tests for the hardening done after the code review: folder names, MIME limits, header injection, the accounts cache, the failure table.
local msg = require("tsr.mail.message")
local storeMod = require("tsr.mail.store")
local mailMod = require("tsr.mail")
local vfs = require("tsr.vfs")

local ROOT = "/tmp/mailguard-test"

local function newStore()
  if vfs.fs.exists(ROOT) then vfs.fs.delete(ROOT) end
  vfs.fs.makeDir(ROOT)
  return storeMod.new({ root = ROOT .. "/mb", users = ROOT .. "/users.db", iterations = 3 })
end

test("folder and mailbox names cannot leave the mail directory", function()
  local st = newStore()
  assert(st:addUser("alice", "pw-alice"))
  for _, bad in ipairs({ "..", "../..", "a/../b", "/etc", "", ".hidden", ("x"):rep(80) }) do
    local okCall = pcall(st.dir, st, "alice", bad)
    ok(not okCall, "folder " .. bad:sub(1, 12) .. " must be refused")
  end
  ok(not pcall(st.dir, st, "../alice", "INBOX"), "mailbox with ..")
  ok(pcall(st.dir, st, "alice", "Sent Items"), "an ordinary folder name is fine")
end)

test("deep or wide multipart messages are cut off", function()
  local text = "Content-Type: text/plain\r\n\r\nhello\r\n"
  local raw = text
  for i = 1, 30 do
    local b = "b" .. i
    raw = 'Content-Type: multipart/mixed; boundary="' .. b .. '"\r\n\r\n--' .. b .. "\r\n" .. raw .. "\r\n--" .. b .. "--\r\n"
  end
  local m = msg.parse(raw)
  local parts = m:parts()
  ok(#parts <= msg.MAX_PARTS, "part count is bounded")
  -- many sibling parts
  local pieces = { 'Content-Type: multipart/mixed; boundary="w"', "" }
  for i = 1, 500 do pieces[#pieces + 1] = "--w" pieces[#pieces + 1] = "Content-Type: text/plain" pieces[#pieces + 1] = "" pieces[#pieces + 1] = "p" .. i end
  pieces[#pieces + 1] = "--w--"
  local wide = msg.parse(table.concat(pieces, "\r\n")):parts()
  ok(#wide <= msg.MAX_PARTS, "wide messages are bounded: " .. #wide)
end)

test("line breaks in subjects, names and headers cannot inject headers", function()
  local raw = msg.build({ from = "a@example.lan", to = "b@example.lan", subject = "hi\r\nBcc: evil@example.lan", body = "x",
    headers = { ["X-One"] = "v\r\nBcc: evil2@example.lan" } })
  local m = msg.parse(raw)
  ok(m:header("bcc") == nil, "no injected Bcc header")
  ok(not raw:find("\r\nBcc:", 1, true))
  local word = msg.encodeWord("name\r\nBcc: x")
  ok(not word:find("[\r\n]"), "encoded words are one line")
end)

test("the accounts table follows the file and saving clears the cache", function()
  local st = newStore()
  assert(st:addUser("alice", "pw-alice"))
  ok(st:exists("alice"))
  -- a second store object (another process) adds a user; the first sees it once the file changed
  local other = storeMod.new({ root = ROOT .. "/mb", users = ROOT .. "/users.db", iterations = 3 })
  assert(other:addUser("bob", "pw-bob"))
  ok(st:exists("bob"), "the cache is validated against the file")
  ok(st:authenticate("bob", "pw-bob") == "bob")
end)

test("the failure table is pruned and entries are shared per address", function()
  local stack = { clock = function() return 100 end }
  local m = mailMod.new(stack, { root = ROOT .. "/mb", users = ROOT .. "/u2.db" }, newStore())
  local fr = m.failureRecord
  local a = fr(m, "10.0.0.1")
  a.n = 3
  ok(fr(m, "10.0.0.1") == a, "same record for the same address")
  for i = 1, 400 do fr(m, "10.1." .. math.floor(i / 250) .. "." .. (i % 250)) end
  ok(m.authFailureCount <= 260, "pruned: " .. m.authFailureCount)
  ok(fr(m, "10.0.0.1") == a, "a record with failures survives pruning")
end)
