-- SPDX-License-Identifier: AGPL-3.0-or-later
local sandbox = require("tsr.sandbox")
local vm = require("tsr.vm")

local DIR = "/tmp-sandbox"

local function fresh()
  if fs.exists(DIR) then fs.delete(DIR) end
  fs.makeDir(DIR)
  vm.DIR = DIR .. "/vms"
end

local function run(source, opts)
  opts = opts or {}
  opts.source = source
  opts.root = opts.root or (DIR .. "/jail")
  return sandbox.run(nil, opts)
end

local function read(path)
  local h = fs.open(path, "r")
  if not h then return nil end
  local s = h.readAll()
  h.close()
  return s
end

test("a program runs and returns its results and arguments", function()
  fresh()
  local ok1, a, b = run("return 1 + 2, 'x'")
  eq({ ok1, a, b }, { true, 3, "x" })
  ok1, a = run("return select('#', ...), ...", { args = { "p", "q" } })
  eq({ ok1, a }, { true, 2 })
  local bad, err = run("error('it failed', 0)")
  eq({ bad, err }, { false, "it failed" })
  bad, err = run("this is not lua")
  ok(bad == false and err ~= "")
  bad, err = sandbox.run("/does/not/exist.lua", { root = DIR .. "/jail" })
  ok(bad == false and err:find("cannot open"))
end)

test("the real system is out of reach", function()
  fresh()
  _G.SANDBOX_HOST_SECRET = "hunter2"
  local _, secret = run("return SANDBOX_HOST_SECRET")
  eq(secret, nil)
  for _, name in ipairs({ "io", "shell", "multishell", "http", "peripheral", "rednet", "redstone", "rs", "turtle", "commands",
                          "package", "loadstring", "dofile_real", "tsr", "kernel", "disk", "gps", "bit", "setfenv", "getfenv" }) do
    local _, v = run("return " .. name)
    eq(v, nil, name .. " must not be visible")
  end
  local _, shutdown = run("return os.shutdown")
  eq(shutdown, nil)
  _, shutdown = run("return os.reboot, os.run, os.loadAPI")
  eq(shutdown, nil)
  -- _G is the sandbox's own table
  local _, same = run("_G.planted = 1 return planted")
  eq(same, 1)
  eq(rawget(_G, "planted"), nil, "nothing leaks into the real globals")
  _G.SANDBOX_HOST_SECRET = nil
end)

test("sandboxed code cannot damage the shared libraries", function()
  fresh()
  local realFormat = string.format
  run("string.format = function() return 'hacked' end")
  eq(string.format("%d", 5), "5")
  run("local mt = getmetatable('') mt.__index.format = nil")
  eq(string.format("%d", 5), "5")
  eq(select(2, run("return type(getmetatable(''))")), "table")
  run("table.insert = nil math.floor = nil")
  ok(table.insert and math.floor)
  eq(select(2, run("return string.dump")), nil)
  local ok1, err = run("return string.rep('x', 1e9)")
  ok(ok1 == false and err:find("too large"), tostring(err))
  eq(select(2, run("return string.rep('ab', 3)")), "ababab")
  string.format = realFormat
end)

test("load only reads text and uses the sandbox environment", function()
  fresh()
  _G.SANDBOX_HOST_SECRET = "x"
  local ok1, v = run("return load('return SANDBOX_HOST_SECRET')()")
  eq({ ok1, v }, { true, nil })
  local _, f, err = run("return load('x', 'n', 'b')")
  eq(f, nil)
  local _, viaString = run("local f = load(string.dump or function() end) return f")
  ok(true)
  _G.SANDBOX_HOST_SECRET = nil
end)

test("the file system is a jail", function()
  fresh()
  fs.makeDir(DIR .. "/outside")
  local h = fs.open(DIR .. "/outside/secret.txt", "w")
  h.write("top secret")
  h.close()
  local ok1 = run([[
    local h = fs.open("note.txt", "w") h.write("inside") h.close()
    fs.makeDir("sub/dir")
    return fs.exists("note.txt"), fs.isDir("sub/dir"), fs.list("/")
  ]])
  ok(ok1)
  eq(read(DIR .. "/jail/note.txt"), "inside")
  -- ".." cannot climb out of the jail: it resolves inside it
  run([[local h = fs.open("../../escape.txt", "w") h.write("x") h.close()]])
  ok(not fs.exists(DIR .. "/escape.txt"))
  ok(fs.exists(DIR .. "/jail/escape.txt"))
  local _, seen = run([[return fs.exists("/../outside/secret.txt")]])
  eq(seen, false)
  -- absolute paths are inside the jail too
  local _, absolute = run([[return fs.exists("/tmp-sandbox/outside/secret.txt")]])
  eq(absolute, false)
  -- /rom is readable but not writable
  local _, hasRom = run([[return fs.exists("/rom/programs/shell.lua"), fs.isReadOnly("rom")]])
  eq(hasRom, true)
  local bad, err = run([[fs.open("/rom/hack.lua", "w")]])
  ok(bad == false and err:find("Access denied"), tostring(err))
  bad, err = run([[fs.delete("rom/programs")]])
  ok(bad == false and err:find("Access denied"), tostring(err))
  bad, err = run([[fs.delete("/")]])
  ok(bad == false and err:find("Access denied"), tostring(err))
  -- listing the top shows rom as well
  local _, listing = run([[local names = fs.list("") for _, n in ipairs(names) do if n == "rom" then return true end end return false]])
  eq(listing, true)
end)

test("the disk quota is enforced", function()
  fresh()
  local bad, err = run([[
    local h = fs.open("big.txt", "w")
    for i = 1, 100 do h.write(string.rep("x", 100)) end
    h.close()
  ]], { quota = 2000 })
  ok(bad == false and err:find("Out of space"), tostring(err))
  eq(select(2, run([[return fs.getFreeSpace("/")]], { quota = 2000 })) <= 2000, true)
  fs.delete(DIR .. "/jail")
  ok(run([[local h = fs.open("small", "w") h.write("ok") h.close()]], { quota = 2000 }))
end)

test("require loads modules from the jail and from the rom", function()
  fresh()
  fs.makeDir(DIR .. "/jail")
  local h = fs.open(DIR .. "/jail/mymod.lua", "w")
  h.write("return { answer = 42, name = ... }")
  h.close()
  local ok1, answer, name = run("local m = require('mymod') return m.answer, m.name")
  eq({ ok1, answer, name }, { true, 42, "mymod" })
  local _, pretty = run("return type(require('cc.pretty').pretty)")
  eq(pretty, "function")
  local bad, err = run("require('nothing.here')")
  ok(bad == false and err:find("not found"))
  local _, same = run("return require('mymod') == require('mymod')")
  eq(same, true, "modules are cached")
end)

test("endless loops are stopped, even inside pcall and inside coroutines", function()
  fresh()
  local t0 = os.clock()
  local bad, err = run("while true do end", { timeout = 0.3 })
  ok(bad == false and err:find("time limit"), tostring(err))
  ok(os.clock() - t0 < 5, "stopped promptly")
  bad, err = run("while true do pcall(function() while true do end end) end", { timeout = 0.3 })
  ok(bad == false and err:find("time limit"), "pcall cannot swallow the limit: " .. tostring(err))
  bad, err = run("local co = coroutine.create(function() while true do end end) coroutine.resume(co)", { timeout = 0.3 })
  ok(bad == false and err:find("time limit"), "coroutines are watched: " .. tostring(err))
  bad, err = run("local f = coroutine.wrap(function() while true do end end) f()", { timeout = 0.3 })
  ok(bad == false and err:find("time limit"), tostring(err))
  bad, err = run("local ok2, e = xpcall(function() while true do end end, function(m) return m end) while true do end", { timeout = 0.3 })
  ok(bad == false and err:find("time limit"), tostring(err))
end)

test("waiting for events does not use up the CPU budget", function()
  fresh()
  local result
  parallel.waitForAll(
    function() result = { run("local e = os.pullEvent('sb_go') return 'got ' .. e", { timeout = 0.2 }) } end,
    function() sleep(0.5) os.queueEvent("sb_go") end)
  eq(result, { true, "got sb_go" })
  -- sleep() works inside, and events for other filters are skipped
  parallel.waitForAll(
    function() result = { run("sleep(0.3) return 'slept'", { timeout = 0.2 }) } end,
    function() end)
  eq(result, { true, "slept" })
end)

test("memory hogs are stopped", function()
  fresh()
  local bad, err = run("local t = {} for i = 1, 1e7 do t[i] = {i} end", { memory = 300, timeout = 20 })
  ok(bad == false and err:find("memory limit"), tostring(err))
end)

test("queueing events is limited to sb_ events", function()
  fresh()
  local bad, err = run("os.queueEvent('key', 1)")
  ok(bad == false and err:find("sb_"), tostring(err))
  ok(run("os.queueEvent('sb_hello')"))
  os.pullEvent("sb_hello")
end)

test("hardware and network are opt-in", function()
  fresh()
  local _, p = run("return peripheral ~= nil", { allow = { peripheral = true } })
  eq(p, true)
  local _, r = run("return redstone ~= nil and rs ~= nil", { allow = { redstone = true } })
  eq(r, true)
  local _, s = run("return os.shutdown ~= nil", { allow = { os = true } })
  eq(s, true)
  local _, extra = run("return custom", { env = { custom = "given" } })
  eq(extra, "given")
  local _, native = run("return term.native")
  eq(native, nil)
  -- redirecting is only possible to windows the program made itself, and is undone afterwards
  local before = term.current()
  local bad, err = run("term.redirect(rawget(_G, 'nothing') or {})")
  ok(bad == false and err:find("Access denied"), tostring(err))
  local good = run("local w = window.create(term.current(), 1, 1, 5, 2, false) term.redirect(w) print('hi')")
  ok(good)
  ok(term.current() == before, "the real terminal was restored")
end)

test("virtual computers: create, list, run programs, copy files", function()
  fresh()
  ok(vm.create("box", 50))
  local bad, err = vm.create("box")
  ok(bad == nil and err:find("already exists"))
  eq(vm.create("bad name"), nil)
  eq(vm.list(), { { name = "box", quota = 50 * 1024 } })
  -- put a program on the virtual disk and run it
  local h = fs.open(DIR .. "/hello.lua", "w")
  h.write("local h = fs.open('out.txt', 'w') h.write('from the vm ' .. tostring(...)) h.close() return 'done'")
  h.close()
  ok(vm.put("box", DIR .. "/hello.lua"))
  ok(fs.exists(vm.DIR .. "/box/disk/hello.lua"))
  local ok1, res = vm.run("box", "hello.lua", { args = { "arg1" } })
  eq({ ok1, res }, { true, "done" })
  eq(read(vm.DIR .. "/box/disk/out.txt"), "from the vm arg1")
  ok(vm.get("box", "out.txt", DIR .. "/copied.txt"))
  eq(read(DIR .. "/copied.txt"), "from the vm arg1")
  bad, err = vm.run("box", "missing.lua")
  ok(bad == false and err:find("no such file"))
  bad, err = vm.run("ghost", "x")
  ok(bad == false and err:find("no such virtual computer"))
  bad = vm.get("box", "missing", DIR .. "/x")
  eq(bad, nil)
  -- a full disk refuses more files
  local big = fs.open(DIR .. "/big.bin", "wb")
  big.write(string.rep("x", 60 * 1024))
  big.close()
  bad, err = vm.put("box", DIR .. "/big.bin")
  ok(bad == nil and err:find("full"), tostring(err))
  ok(vm.delete("box"))
  eq(#vm.list(), 0)
  eq(vm.delete("box"), nil)
end)

test("a virtual computer boots the CraftOS shell and runs a startup file", function()
  fresh()
  ok(vm.create("os"))
  local h = fs.open(vm.DIR .. "/os/disk/startup.lua", "w")
  h.write("local f = fs.open('booted', 'w') f.write('yes') f.close()")
  h.close()
  -- feed the shell an `exit` command so start() returns
  parallel.waitForAll(
    function()
      local okStart, err = vm.start("os", { timeout = 20 })
      ok(okStart, tostring(err))
    end,
    function()
      sleep(1)
      for c in ("exit"):gmatch(".") do os.queueEvent("char", c) end
      os.queueEvent("key", keys.enter, false)
      os.queueEvent("key_up", keys.enter)
    end)
  eq(read(vm.DIR .. "/os/disk/booted"), "yes")
end)

test("the vm command", function()
  fresh()
  local function cli(...)
    local io = { said = {}, errs = {} }
    function io.say(t) io.said[#io.said + 1] = t end
    function io.err(t) io.errs[#io.errs + 1] = t end
    local r = vm.cli({ ... }, io)
    return r, table.concat(io.said, "\n"), table.concat(io.errs, "\n")
  end
  local r, text = cli("list")
  ok(r and text:find("No virtual computers", 1, true))
  ok(cli("create", "a"))
  r, text = cli("list")
  ok(text:find("a ", 1, true) and text:find("200 KB", 1, true), text)
  eq(cli("create", "a"), false)
  eq(cli("run", "a"), false)
  eq(cli("run", "a", "none.lua"), false)
  eq(cli("start", "ghost"), false)
  ok(cli("delete", "a"))
  eq(cli("bogus"), false)
end)
