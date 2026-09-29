-- SPDX-License-Identifier: AGPL-3.0-or-later
local semver = require("tsr.pkg.semver")
local db = require("tsr.pkg.db")

test("semver compare", function()
  eq(semver.compare("1.2.3", "1.2.3"), 0)
  eq(semver.compare("1.2.3", "1.10.0"), -1)
  eq(semver.compare("2", "1.99.99"), 1)
  eq(semver.compare("v1.0", "1.0.0"), 0)
  eq(semver.compare("1.2.3-beta", "1.2.3"), 0)
  throws(function() semver.compare("x", "1.0.0") end, "bad version")
end)

test("semver ranges", function()
  local s = semver.satisfies
  ok(s("1.2.3", "*") and s("1.2.3", "") and s("1.2.3", nil))
  ok(s("1.2.3", "1.2.3") and not s("1.2.4", "1.2.3"))
  ok(s("1.2.3", ">=1.2") and not s("1.1.9", ">=1.2"))
  ok(s("2.0.0", ">1.9") and not s("1.9.0", ">1.9"))
  ok(s("1.2.3", "<=1.2.3") and not s("1.2.4", "<=1.2.3"))
  ok(s("1.9.9", "<2") and not s("2.0.0", "<2"))
  ok(s("1.9.0", "^1.2.3") and not s("2.0.0", "^1.2.3") and not s("1.2.2", "^1.2.3"))
  ok(s("0.2.9", "^0.2.3") and not s("0.3.0", "^0.2.3"))
  ok(s("0.0.3", "^0.0.3") and not s("0.0.4", "^0.0.3"))
  ok(s("1.2.9", "~1.2.3") and not s("1.3.0", "~1.2.3"))
  ok(s("1.5.0", ">=1.2 <2") and not s("2.0.0", ">=1.2 <2") and not s("1.1.0", ">=1.2, <2"))
  throws(function() s("1.0.0", "^x") end, "bad range")
end)

test("semver best", function()
  eq(semver.best({ "1.0.0", "1.4.0", "2.0.0", "1.9.9" }, "^1.0"), "1.9.9")
  eq(semver.best({ "1.0.0" }, ">=2"), nil)
end)

test("db round trip, ownership, dependents, providers", function()
  local old = db.path
  db.path = "/tmp-db/db.json"
  db.reload()
  db.set("core", { version = "0.1.0", files = { { path = "/sys/a.lua", sha256 = "aa", size = 1 } }, provides = { "tsr:core" } })
  db.set("pkg", { version = "0.1.0", requires = { core = ">=0.1" }, files = {} })
  ok(db.save())
  db.reload()
  eq(db.names(), { "core", "pkg" })
  eq(db.get("core").version, "0.1.0")
  eq((db.owner("/sys/a.lua")), "core")
  eq(db.owner("/nope"), nil)
  eq(db.dependents("core"), { "pkg" })
  eq(db.provider("tsr:core"), "core")
  db.remove("pkg")
  eq(db.names(), { "core" })
  db.path = old
  db.reload()
  fs.delete("/tmp-db")
end)

test("db tolerates a corrupt file", function()
  local old = db.path
  db.path = "/tmp-db2/db.json"
  fs.makeDir("/tmp-db2")
  local h = fs.open(db.path, "w") h.write("{{{ not json") h.close()
  db.reload()
  eq(db.names(), {})
  db.path = old
  db.reload()
  fs.delete("/tmp-db2")
end)
