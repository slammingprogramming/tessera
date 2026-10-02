-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The `pkg` command as a user sees it: output of search, info, install, list, verify, remove and the error paths.
local testenv = dofile("/tests/lib/testenv.lua")
local capture = require("tsr.shell.capture")

local function pkgCmd(...)
  local args = { ... }
  local cap = capture.new()
  local prev = term.redirect(cap.term)
  local chunk, err = loadfile("/sys/bin/pkg.lua", "t", setmetatable({ require = require }, { __index = _G }))
  local ok, res
  if chunk then ok, res = pcall(chunk, table.unpack(args)) else ok, res = false, err end
  term.redirect(prev)
  return cap.text(), ok, res
end

local function setup()
  testenv.reset()
  testenv.publish({
    app = { version = "1.0.0", description = "The application", requires = { lib = ">=1.0.0" },
            files = { [testenv.ROOT .. "/bin/app.lua"] = "print('app')" } },
    lib = { version = "1.2.0", description = "A helper library", files = { [testenv.ROOT .. "/lib/lib.lua"] = "return 1" } },
    extra = { version = "0.3.0", description = "Something else", files = { [testenv.ROOT .. "/extra.lua"] = "return 'x'" } },
  })
end

test("pkg with no command shows the help", function()
  setup()
  local out = pkgCmd()
  ok(out:find("pkg <command>", 1, true) and out:find("install", 1, true) and out:find("import", 1, true), out)
  out = pkgCmd("help")
  ok(out:find("pkg <command>", 1, true))
  out = pkgCmd("frobnicate")
  ok(out:find("unknown command: frobnicate", 1, true) and out:find("pkg <command>", 1, true), out)
end)

test("search and info", function()
  setup()
  local out = pkgCmd("search")
  ok(out:find("app", 1, true) and out:find("lib", 1, true) and out:find("extra", 1, true), out)
  out = pkgCmd("search", "helper")
  ok(out:find("lib", 1, true) and not out:find("The application", 1, true), out)
  out = pkgCmd("search", "zzz-nothing")
  ok(out:lower():find("no ", 1, true) or out == "" or out:find("found", 1, true), out)
  out = pkgCmd("info", "app")
  ok(out:find("app", 1, true) and out:find("1.0.0", 1, true) and out:find("lib", 1, true), out)
  out = pkgCmd("info", "ghost")
  ok(out:lower():find("ghost", 1, true), out)
  out = pkgCmd("info")
  ok(out:find("usage: pkg info", 1, true), out)
end)

test("install shows the plan, installs dependencies and files, and list shows them", function()
  setup()
  local out = pkgCmd("install", "app", "-y")
  ok(out:find("lib", 1, true) and out:find("app", 1, true), out)
  ok(fs.exists(testenv.ROOT .. "/bin/app.lua") and fs.exists(testenv.ROOT .. "/lib/lib.lua"), "files are on disk")
  out = pkgCmd("list")
  ok(out:find("app", 1, true) and out:find("1.0.0", 1, true) and out:find("lib", 1, true) and out:find("1.2.0", 1, true), out)
  ok(not out:find("extra", 1, true), "only installed packages are listed")
  -- installing again changes nothing and says so
  out = pkgCmd("install", "app", "-y")
  ok(out:lower():find("nothing", 1, true) or out:lower():find("already", 1, true) or out:lower():find("up to date", 1, true), out)
end)

test("a dry run installs nothing", function()
  setup()
  local out = pkgCmd("install", "extra", "--dry")
  ok(out:find("extra", 1, true), out)
  ok(not fs.exists(testenv.ROOT .. "/extra.lua"))
  eq(pkgCmd("install"):find("usage: pkg install", 1, true) ~= nil, true)
end)

test("installing something that does not exist explains why", function()
  setup()
  local out = pkgCmd("install", "ghost", "-y")
  ok(out:find("ghost", 1, true), out)
  ok(not fs.exists(testenv.ROOT .. "/ghost"))
end)

test("remove refuses to break dependants unless forced, and cleans up", function()
  setup()
  pkgCmd("install", "app", "-y")
  local out = pkgCmd("remove", "lib", "-y")
  ok(out:lower():find("app", 1, true), "mentions the package that needs it: " .. out)
  ok(fs.exists(testenv.ROOT .. "/lib/lib.lua"), "lib is still there")
  out = pkgCmd("remove", "app", "-y")
  ok(not fs.exists(testenv.ROOT .. "/bin/app.lua"), out)
  out = pkgCmd("remove", "lib", "-y")
  ok(not fs.exists(testenv.ROOT .. "/lib/lib.lua"), out)
  out = pkgCmd("list")
  ok(not out:find("1.2.0", 1, true), out)
  eq(pkgCmd("remove"):find("usage: pkg remove", 1, true) ~= nil, true)
end)

test("verify reports damaged files", function()
  setup()
  pkgCmd("install", "lib", "-y")
  local out = pkgCmd("verify")
  ok(out:find("all files match", 1, true), out)
  local h = fs.open(testenv.ROOT .. "/lib/lib.lua", "w")
  h.write("return 'tampered'")
  h.close()
  out = pkgCmd("verify", "lib")
  ok(out:find("lib.lua", 1, true), out)
end)

test("source list shows the configured sources", function()
  setup()
  local out = pkgCmd("source", "list")
  ok(out:find("test", 1, true), out)
  out = pkgCmd("source", "add")
  ok(out:find("usage: pkg source add", 1, true), out)
  out = pkgCmd("source", "bogus")
  ok(out:find("usage: pkg source", 1, true), out)
end)

test("update reports the sources it refreshed", function()
  setup()
  local out = pkgCmd("update")
  ok(out:find("test", 1, true), out)
end)
