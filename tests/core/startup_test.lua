-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Stage 0 (/startup.lua): the escape hatches that keep a broken Tessera from locking a computer out. The script is run as a
-- chunk with a fake `os` (scripted events, recorded shutdown/reboot), a fake boot function and a fake `loadfile`.
local COUNT = "/var/lib/tsr/boot.count"
local DISABLED = "/etc/tsr/disabled"

local function readCount()
  local h = fs.open(COUNT, "r")
  if not h then return nil end
  local s = h.readAll()
  h.close()
  return tonumber(s)
end

local function writeCount(n)
  if not fs.isDir("/var/lib/tsr") then fs.makeDir("/var/lib/tsr") end
  local h = fs.open(COUNT, "w")
  h.write(tostring(n))
  h.close()
end

local function clean()
  if fs.exists(COUNT) then fs.delete(COUNT) end
  if fs.exists(DISABLED) then fs.delete(DISABLED) end
end

--- Run stage 0. `opts`: events (list of {name, ...} the fake os.pullEventRaw returns, in order), boot (function), bootExists.
--- Returns a record of what happened.
local function runStage0(opts)
  opts = opts or {}
  local rec = { booted = false, shutdown = false, rebooted = false, output = {}, errors = {} }
  local events = opts.events or {}
  local timerId = 0
  local fakeOs = setmetatable({
    startTimer = function() timerId = timerId + 1 return timerId end,
    pullEventRaw = function()
      local e = table.remove(events, 1)
      if e then return table.unpack(e) end
      return "timer", timerId                  -- nothing pressed: the banner time runs out
    end,
    shutdown = function() rec.shutdown = true end,
    reboot = function() rec.rebooted = true end,
  }, { __index = os })
  local fakeFs = setmetatable({
    exists = function(p)
      if p == "/sys/boot.lua" then return opts.bootExists ~= false end
      return fs.exists(p)
    end,
  }, { __index = fs })
  local env = setmetatable({
    os = fakeOs, fs = fakeFs,
    print = function(...) rec.output[#rec.output + 1] = table.concat({ ... }, " ") end,
    printError = function(...) rec.errors[#rec.errors + 1] = table.concat({ ... }, " ") end,
    loadfile = function(path)
      if path == "/sys/boot.lua" then
        return function()
          rec.booted = true
          if opts.boot then return opts.boot() end
          return "craftos"
        end
      end
      return loadfile(path)
    end,
  }, { __index = _G })
  local chunk = assert(loadfile("/startup.lua", "t", env))
  chunk()
  return rec
end

test("a normal boot counts itself, runs the system and leaves to CraftOS", function()
  clean()
  local rec = runStage0()
  ok(rec.booted)
  eq(readCount(), 1, "the count stays until the system proves it is stable")
  ok(not rec.shutdown and not rec.rebooted)
  ok(rec.output[1] and rec.output[1]:find("hold R", 1, true))
  clean()
end)

test("the system can ask for shutdown or reboot", function()
  clean()
  local rec = runStage0({ boot = function() return "shutdown" end })
  ok(rec.shutdown and not rec.rebooted)
  clean()
  rec = runStage0({ boot = function() return "reboot" end })
  ok(rec.rebooted and not rec.shutdown)
  clean()
end)

test("holding R skips Tessera and does not count as a boot", function()
  clean()
  local rec = runStage0({ events = { { "key", keys.r } } })
  ok(not rec.booted)
  eq(readCount(), nil)
  ok(rec.output[#rec.output]:find("Skipping", 1, true))
  -- other keys do not skip it
  rec = runStage0({ events = { { "key", keys.a }, { "char", "x" } } })
  ok(rec.booted)
  clean()
end)

test("the disabled flag keeps Tessera off until the file is removed", function()
  clean()
  fs.makeDir("/etc/tsr")
  local h = fs.open(DISABLED, "w")
  h.write("x")
  h.close()
  local rec = runStage0()
  ok(not rec.booted)
  eq(#rec.output, 0, "it does not even show the banner")
  fs.delete(DISABLED)
  rec = runStage0()
  ok(rec.booted)
  clean()
end)

test("three unfinished boots in a row make Tessera step aside once", function()
  clean()
  -- each boot that never reaches "stable" leaves the count one higher
  for expected = 1, 3 do
    local rec = runStage0()
    ok(rec.booted)
    eq(readCount(), expected)
  end
  local rec = runStage0()
  ok(not rec.booted, "the fourth start refuses to boot")
  ok(rec.errors[1] and rec.errors[1]:find("failed to start 3 times", 1, true), tostring(rec.errors[1]))
  eq(readCount(), 0, "the counter is reset so the next start tries again")
  rec = runStage0()
  ok(rec.booted)
  clean()
end)

test("a boot marked stable resets the counter so it never reaches the limit", function()
  clean()
  for _ = 1, 10 do
    runStage0()
    writeCount(0)          -- what the boot-watch service does after a few quiet seconds
  end
  local rec = runStage0()
  ok(rec.booted)
  clean()
end)

test("a crashing boot is reported and leaves the computer usable", function()
  clean()
  local rec = runStage0({ boot = function() error("kaboom", 0) end })
  ok(rec.booted)
  ok(rec.errors[1] and rec.errors[1]:find("Tessera boot error: kaboom", 1, true), tostring(rec.errors[1]))
  ok(not rec.shutdown and not rec.rebooted)
  eq(readCount(), 1)
  clean()
end)

test("without the system files stage 0 does nothing", function()
  clean()
  local rec = runStage0({ bootExists = false })
  ok(not rec.booted)
  eq(#rec.output, 0)
  eq(readCount(), nil)
end)
