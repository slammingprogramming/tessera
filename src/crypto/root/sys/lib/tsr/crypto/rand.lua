-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Random bytes for keys, nonces and challenges.
--
-- HONEST LIMITS: ComputerCraft has no real random number source. This pool mixes everything a computer can observe
-- (millisecond clock, CPU clock, object addresses, timers, the world time, the computer's id, event timings you feed in with
-- `addEntropy`) and a seed file that survives reboots, and runs it through SHA-512. That is good enough to keep other players
-- from guessing keys, but a serious key (a registry signing key, a server's host key) should be generated on a real
-- computer with real randomness or with `collect`, which stirs in the timing of your own key presses.
local sha512 = require("tsr.crypto.sha512")

local M = {}

M.seedFile = "/var/lib/tsr/random.seed"

local pool = nil
local counter = 0

local function now() return os.epoch and os.epoch("utc") or 0 end

local function observe()
  return table.concat({
    tostring(now()), tostring(os.clock()), tostring(os.getComputerID()), tostring(os.time()), tostring(os.day and os.day() or 0),
    tostring({}), tostring(print), tostring(math.random()), tostring(math.random()), tostring(coroutine.running()),
  }, "|")
end

local function readSeed()
  if not (fs and fs.exists and fs.exists(M.seedFile)) then return "" end
  local f = fs.open(M.seedFile, "rb")
  if not f then return "" end
  local s = f.readAll() or ""
  f.close()
  return s
end

local function init()
  if pool then return end
  pool = sha512.digest("tessera-rand|" .. observe() .. "|" .. readSeed())
end

--- Mix more entropy into the pool (anything: event timings, text a person typed, a peer's nonce).
function M.addEntropy(...)
  init()
  local parts = { pool, observe() }
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  pool = sha512.digest(table.concat(parts, "|"))
end

--- n random bytes as a binary string.
function M.bytes(n)
  init()
  local out, have = {}, 0
  while have < n do
    counter = counter + 1
    local block = sha512.digest("out|" .. counter .. "|" .. pool .. "|" .. observe())
    pool = sha512.digest("next|" .. block .. pool)
    out[#out + 1] = block:sub(1, 32)
    have = have + 32
  end
  return table.concat(out):sub(1, n)
end

--- Write a fresh seed file so the next boot starts from a different pool state (best effort).
function M.saveSeed()
  if not (fs and fs.open) then return false end
  pcall(function()
    local dir = fs.getDir(M.seedFile)
    if not fs.exists(dir) then fs.makeDir(dir) end
    local f = fs.open(M.seedFile, "wb")
    if f then f.write(M.bytes(64)) f.close() end
  end)
  return true
end

--- Interactive collection for important keys: asks `count` times for a key press (via `wait`, default a keypress) and stirs in
--- the millisecond timing between the presses. `show(i, count)` may draw progress.
function M.collect(count, show, wait)
  count = count or 32
  wait = wait or function() return os.pullEvent("key") end
  local last = now()
  for i = 1, count do
    if show then show(i, count) end
    local ev, code = wait()
    local t = now()
    M.addEntropy(t - last, os.clock(), ev, code)
    last = t
  end
end

return M
