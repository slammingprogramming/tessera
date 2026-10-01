-- SPDX-License-Identifier: AGPL-3.0-or-later
local roles = require("tsr.roles")
local svc = require("tsr.svc")
local K = require("tsr.kernel")
local config = require("tsr.config")
local testenv = dofile("/tests/lib/testenv.lua")

local DIR = "/tmp-roles"

local function setup()
  K.reset()
  K.init({ term = window.create(term.current(), 1, 1, 20, 5, false) })
  testenv.reset()
  if fs.exists(DIR) then fs.delete(DIR) end
  fs.makeDir(DIR .. "/roles")
  roles.dir = DIR .. "/roles"
  roles.statePath = DIR .. "/roles.state"
  svc.reset()
  svc.dir = DIR .. "/services"
  svc.statePath = DIR .. "/services.state"
  fs.makeDir(svc.dir)
end

local function put(path, text)
  local h = fs.open(path, "w")
  h.write(text)
  h.close()
end

local function forever() while true do os.pullEvent("roles_test_never") end end

test("roles load from files and bad ones are reported", function()
  setup()
  put(roles.dir .. "/web.lua", [[return { description = "A web box", packages = { "webpkg" }, services = { "web" } }]])
  put(roles.dir .. "/broken.lua", [[return { oops ]])
  put(roles.dir .. "/nodesc.lua", [[return { packages = {} }]])
  local all, problems = roles.load()
  eq(roles.names(), { "web" })
  eq(#problems, 2)
  eq(all.web.services, { "web" })
  local plan = roles.plan("web")
  eq(plan.missing, { "webpkg" })
  local none, err = roles.plan("ghost")
  ok(none == nil and err:find("no such role"))
end)

test("applying a role installs packages and enables and starts services", function()
  setup()
  testenv.publish({
    webpkg = { version = "1.0.0", files = {
      [testenv.ROOT .. "/web.lua"] = "return 1",
    } },
  })
  put(roles.dir .. "/web.lua", [[return {
    description = "A web box", packages = { "webpkg" }, services = { "web" },
    config = { ["roles_test.flag"] = "on" }, notes = "Visit the box.",
  }]])
  -- the package brings the service definition along: simulate by writing it where the package would
  put(svc.dir .. "/web.lua", [[return { description = "web", run = function() while true do os.pullEvent("never_ever") end end }]])
  local res, err = roles.apply("web")
  ok(res, tostring(err))
  eq(res.installed, { "webpkg" })
  eq(res.enabled, { "web" })
  eq(res.started, { "web" })
  eq(res.problems, {})
  eq(res.notes, "Visit the box.")
  eq(svc.status("web").state, "running")
  eq(svc.enabled("web"), true)
  eq(config.get("roles_test.flag"), "on")
  ok(roles.isApplied("web"))
  -- applying again does not reinstall
  local res2 = roles.apply("web")
  eq(res2.installed, {})
  -- remove turns the services off
  ok(roles.remove("web"))
  eq(svc.status("web").state, "stopped")
  eq(svc.enabled("web"), false)
  ok(not roles.isApplied("web"))
end)

test("problems are reported and the role is not marked applied", function()
  setup()
  put(roles.dir .. "/r.lua", [[return { description = "d", packages = {}, services = { "missing-svc" } }]])
  local res = roles.apply("r")
  ok(res)
  eq(#res.problems, 1)
  ok(res.problems[1]:find("missing%-svc"))
  ok(not roles.isApplied("r"))
  -- missing packages with install disabled
  put(roles.dir .. "/p.lua", [[return { description = "d", packages = { "nothere" }, services = {} }]])
  res = roles.apply("p", { install = false })
  ok(res.problems[1]:find("missing packages"))
  -- an install that cannot succeed is an error, not a half-applied role
  local bad, err = roles.apply("p")
  ok(bad == nil and err:find("nothere"), tostring(err))
end)

test("the role command", function()
  setup()
  put(roles.dir .. "/a.lua", [[return { description = "Alpha role", packages = {}, services = { "s1" }, notes = "note" }]])
  svc.define({ name = "s1", run = forever })
  local function run(...)
    local io = { said = {}, errs = {} }
    function io.say(t) io.said[#io.said + 1] = t end
    function io.err(t) io.errs[#io.errs + 1] = t end
    local r = roles.run({ ... }, io)
    return r, table.concat(io.said, " / "), table.concat(io.errs, " / ")
  end
  local r, text = run("list")
  ok(r and text:find("Alpha role", 1, true), text)
  r, text = run("show", "a")
  ok(r and text:find("services: s1", 1, true), text)
  eq(run("show", "ghost"), false)
  r, text = run("apply", "a")
  ok(r and text:find("services on: s1", 1, true), text)
  r, text = run("list")
  ok(text:find("* a", 1, true), text)
  ok(run("remove", "a"))
  eq(run("apply"), false)
  eq(run("nonsense"), false)
end)

test("shipped roles are well-formed", function()
  -- the real definitions installed by the package must load (the build checks that the names they use exist)
  roles.dir = "/etc/tsr/roles.d"
  local all, problems = roles.load()
  eq(problems, {})
  ok(all.mirror and all["shell-host"] and all["file-server"] and all.monitor and all["log-collector"])
  for name, def in pairs(all) do
    ok(def.description ~= "", name)
    ok(#def.services > 0, name .. " has no services")
  end
end)
