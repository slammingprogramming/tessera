-- SPDX-License-Identifier: AGPL-3.0-or-later
local doctor = require("tsr.doctor")

test("every check runs without crashing and reports a status", function()
  local results = doctor.run({ quick = true })
  ok(#results >= 10, "checks: " .. #results)
  for _, r in ipairs(results) do
    ok(r.status == "ok" or r.status == "warn" or r.status == "fail" or r.status == "skip", r.id .. ": " .. tostring(r.status))
    ok(not r.detail:find("the check crashed", 1, true), r.id .. ": " .. r.detail)
  end
end)

test("the cryptography known-answer check passes on this VM", function()
  local r = doctor.run({ only = { "crypto" } })[1]
  eq(r.status, "ok", r.detail)
  local speed = doctor.run({ only = { "crypto-speed" } })[1]
  ok(speed.status == "ok" or speed.status == "warn", speed.detail)
  ok(speed.detail:find("Ed25519 verify", 1, true))
end)

test("a crashing check is reported as a failure, selection works, the report counts", function()
  doctor.checks[#doctor.checks + 1] = { id = "boom", title = "boom check", fn = function() error("kaboom") end }
  local results = doctor.run({ only = { "boom", "host" } })
  eq(#results, 2)
  local boom
  for _, r in ipairs(results) do if r.id == "boom" then boom = r end end
  eq(boom.status, "fail")
  ok(boom.detail:find("kaboom", 1, true))
  table.remove(doctor.checks)
  local text, counts = doctor.report(results)
  eq(counts.fail, 1)
  ok(text:find("[FAIL] boom check", 1, true) and text:find("summary:", 1, true))
end)

test("the command writes a report file and lists the checks", function()
  local lines = {}
  local io = { say = function(t) lines[#lines + 1] = t end }
  ok(doctor.main({ "--list" }, io))
  ok(#lines >= 10)
  lines = {}
  local out = "/tmp-doctor-report.txt"
  doctor.main({ "--quick", "--out", out, "host", "disk" }, io)
  ok(fs.exists(out))
  local h = fs.open(out, "r")
  local text = h.readAll()
  h.close()
  fs.delete(out)
  ok(text:find("Tessera doctor report", 1, true) and text:find("ComputerCraft and Minecraft version", 1, true), text)
  ok(not text:lower():find("password", 1, true), "no secrets in the report")
end)
