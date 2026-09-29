-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Tessera test harness. Runs inside CraftOS-PC (started by tools/test/run.mjs); results go to /out/results.json.
--
-- Every /tests/**/*_test.lua file is loaded in a fresh environment that provides:
--   test(name, fn)            register a test case (fn runs on the harness coroutine, so it may yield/sleep)
--   eq(a, b [, msg])          deep equality
--   ok(v [, msg])             truthiness
--   throws(fn [, pattern])    fn must raise an error (optionally matching a Lua pattern)
--   fail(msg)                 explicit failure
--   skip(reason)              mark the current test skipped
-- Anything else is the normal CC environment (require paths already include /sys/lib).

local OUT = "/out"

local function readAll(path)
  local f = fs.open(path, "r")
  if not f then return nil end
  local s = f.readAll()
  f.close()
  return s
end

local cfg = {}
do
  local raw = readAll(OUT .. "/config.json")
  if raw then cfg = textutils.unserializeJSON(raw) or {} end
end

local function deepEq(a, b, seen)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  seen = seen or {}
  if seen[a] == b then return true end
  seen[a] = b
  for k, v in pairs(a) do
    if not deepEq(v, b[k], seen) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local function show(v)
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) == "table" then
    local ok, s = pcall(textutils.serialize, v, { compact = true })
    return ok and s or tostring(v)
  end
  return tostring(v)
end

-- Tessera's shared loader (present once the core package is installed on the emulated computer).
local loader
if fs.exists("/sys/lib/tsr/loader.lua") then loader = dofile("/sys/lib/tsr/loader.lua") end

local function makeEnv()
  local env = setmetatable({}, { __index = _G })
  local cases = {}
  env.loader = loader
  if loader then env.require = loader.require end
  -- helpers loaded from tests run in the test environment, so they see `require`, test/eq/ok...
  env.dofile = function(path, ...)
    local chunk, err = loadfile(path, nil, env)
    if not chunk then error(err, 2) end
    return chunk(...)
  end
  env.test = function(name, fn) cases[#cases + 1] = { name = name, fn = fn } end
  env.eq = function(a, b, msg)
    if not deepEq(a, b) then
      error((msg and (msg .. ": ") or "") .. "expected " .. show(b) .. ", got " .. show(a), 2)
    end
  end
  env.ok = function(v, msg)
    if not v then error(msg or "expected a truthy value", 2) end
  end
  env.fail = function(msg) error(msg or "failed", 2) end
  env.skip = function(reason) error({ skip = reason or "skipped" }, 0) end
  env.throws = function(fn, pattern)
    local good, err = pcall(fn)
    if good then error("expected an error, but none was raised", 2) end
    if pattern and not tostring(err):find(pattern) then
      error("error " .. show(err) .. " does not match " .. show(pattern), 2)
    end
    return err
  end
  return env, cases
end

local function findTests(dir, acc)
  for _, name in ipairs(fs.list(dir)) do
    local p = fs.combine(dir, name)
    if fs.isDir(p) then
      findTests(p, acc)
    elseif name:match("_test%.lua$") then
      acc[#acc + 1] = "/" .. p
    end
  end
  return acc
end

local results = { files = {}, passed = 0, failed = 0, skipped = 0 }

local function runAll()
  local files = findTests("/tests", {})
  table.sort(files)
  for _, path in ipairs(files) do
    if not cfg.filter or path:find(cfg.filter, 1, true) then
      local rec = { file = path, tests = {} }
      results.files[#results.files + 1] = rec
      local env, cases = makeEnv()
      local chunk, lerr = loadfile(path, nil, env)
      if not chunk then
        rec.tests[1] = { name = "(load)", ok = false, err = tostring(lerr) }
        results.failed = results.failed + 1
      else
        local rok, rerr = pcall(chunk)
        if not rok then
          rec.tests[1] = { name = "(run)", ok = false, err = tostring(rerr) }
          results.failed = results.failed + 1
        end
        for _, c in ipairs(cases) do
          local t0 = os.epoch and os.epoch("utc") or 0
          local good, err = xpcall(c.fn, function(e)
            if type(e) == "table" then return e end
            return tostring(e) .. (debug and debug.traceback and ("\n" .. debug.traceback("", 2)) or "")
          end)
          local entry = { name = c.name, ms = (os.epoch and os.epoch("utc") or 0) - t0 }
          if good then
            entry.ok = true
            results.passed = results.passed + 1
          elseif type(err) == "table" and err.skip then
            entry.ok, entry.skipped, entry.err = true, true, err.skip
            results.skipped = results.skipped + 1
          else
            entry.ok, entry.err = false, tostring(err)
            results.failed = results.failed + 1
          end
          rec.tests[#rec.tests + 1] = entry
        end
      end
    end
  end
end

local good, err = pcall(runAll)
if not good then
  results.fatal = tostring(err)
  results.failed = results.failed + 1
end

local f = fs.open(OUT .. "/results.json", "w")
f.write(textutils.serializeJSON(results))
f.close()
os.shutdown()
