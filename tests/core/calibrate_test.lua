-- SPDX-License-Identifier: AGPL-3.0-or-later
local cal = require("tsr.calibrate")

test("the paste text is deterministic and the check detects loss and corruption", function()
  local text = cal.pasteText(100)
  eq(#text, 100)
  eq(text:sub(1, 5), "abcde")
  eq(text:sub(37, 38), "ab", "the alphabet repeats")
  local full = cal.checkPaste(text, 100)
  eq({ full.received, full.intact, full.truncated }, { 100, true, false })
  local cut = cal.checkPaste(text:sub(1, 60), 100)
  eq({ cut.received, cut.intact, cut.truncated }, { 60, true, true })
  local bad = cal.checkPaste("abcXe", 100)
  eq(bad.intact, false)
  local empty = cal.checkPaste("", 100)
  eq({ empty.received, empty.truncated }, { 0, true })
end)

test("measuring a paste and a file drop from events", function()
  local r = cal.measurePaste(50, function() return "paste", cal.pasteText(50) end)
  ok(r.intact and not r.truncated)
  r = cal.measurePaste(50, function() return "paste", cal.pasteText(20) end)
  ok(r.truncated and r.received == 20)
  r = cal.measurePaste(50, function() return "paste", nil end)
  eq(r.received, 0)
  local transfer = { getFiles = function()
    return {
      { getName = function() return "a.bin" end, readAll = function() return string.rep("x", 123) end, close = function() end },
      { getName = function() return "b.txt" end, readAll = function() return "hi" end },
    }
  end }
  local files = cal.measureFiles(function() return "file_transfer", transfer end)
  eq(files.files, { { name = "a.bin", size = 123 }, { name = "b.txt", size = 2 } })
  eq(cal.measureFiles(function() return "file_transfer", nil end), { files = {} })
end)

test("feature probes answer true or false for known things", function()
  local f = cal.features()
  eq(f.bit32, true)
  eq(f.goto_statement, true)
  eq(f.bitwise_operators, false, "Cobalt and Lua 5.2 have no & operator")
  eq(f.integer_division, false)
  eq(type(f.debug_sethook), "boolean")
  eq(f.color_terminal, term.isColor())
  for name, v in pairs(f) do eq(type(v), "boolean", name) end
end)

test("facts and network facts are collected without errors", function()
  local f = cal.facts()
  eq(f.id, os.getComputerID())
  eq(#f.screen, 2)
  ok(f.free_space_type == "number" or f.free_space_type == "string")
  local n = cal.network()
  eq(type(n.http), "boolean")
  eq(type(n.modems), "table")
end)

test("the yield probe reports how long it ran", function()
  local r = cal.yieldLimit(0.2)
  eq(r.limited, false)
  ok(r.seconds >= 0.2 and r.seconds < 2, tostring(r.seconds))
end)

test("the command writes a readable report", function()
  local vfs = require("tsr.vfs")
  cal.REPORT = "/tmp-cal/report.json"
  if fs.exists("/tmp-cal") then fs.delete("/tmp-cal") end
  local io = { said = {}, errs = {} }
  function io.say(t) io.said[#io.said + 1] = t end
  function io.err(t) io.errs[#io.errs + 1] = t end
  ok(cal.run({ "all" }, io, { yieldCap = 0.1 }))
  local text = table.concat(io.said, "\n")
  ok(text:find("has:", 1, true) and text:find("lacks:", 1, true) and text:find("yield limit", 1, true), text)
  local report = vfs.readJSON(cal.REPORT)
  ok(report and report.features and report.facts and report.yield)
  io.said = {}
  ok(cal.run({ "paste", "30" }, io, { yieldCap = 0.1, pullPaste = function() return "paste", cal.pasteText(30) end }))
  ok(table.concat(io.said, "\n"):find("paste: 30 of 30", 1, true), table.concat(io.said, "\n"))
  io.said = {}
  ok(cal.run({ "files" }, io, { pullFiles = function() return "file_transfer", { getFiles = function() return { { getName = function() return "x" end, readAll = function() return "abc" end } } end } end }))
  ok(table.concat(io.said, "\n"):find("file drop: x, 3 bytes", 1, true), table.concat(io.said, "\n"))
  fs.delete("/tmp-cal")
end)
