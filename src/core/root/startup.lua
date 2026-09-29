-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Tessera stage 0: tiny on purpose. Everything else lives in /sys. Escape hatches, in order:
--   * hold R while the banner shows       -> skip Tessera this boot
--   * create /etc/tsr/disabled            -> skip Tessera until the file is deleted
--   * 3 unfinished boots in a row         -> step aside automatically (crash-loop guard)
local COUNT = "/var/lib/tsr/boot.count"
local MAX = 3

if fs.exists("/etc/tsr/disabled") or not fs.exists("/sys/boot.lua") then return end

local function readCount()
  local h = fs.open(COUNT, "r")
  if not h then return 0 end
  local n = tonumber(h.readAll()) or 0
  h.close()
  return n
end

local function writeCount(n)
  if not fs.isDir("/var/lib/tsr") then fs.makeDir("/var/lib/tsr") end
  local h = fs.open(COUNT, "w")
  if h then h.write(tostring(n)) h.close() end
end

local failed = readCount()
if failed >= MAX then
  writeCount(0)
  printError("Tessera failed to start " .. failed .. " times; staying in CraftOS. See /var/log/tsr.log")
  return
end

term.setTextColor(colors.lightGray)
print("Tessera - hold R to skip")
term.setTextColor(colors.white)
local t = os.startTimer(0.4)
while true do
  local e, a = os.pullEventRaw()
  if e == "timer" and a == t then break end
  if e == "key" and a == keys.r then
    print("Skipping Tessera (recovery).")
    return
  end
end

writeCount(failed + 1)
local boot, err = loadfile("/sys/boot.lua", "t", _ENV)
local ok, action
if boot then ok, action = pcall(boot) else ok, action = false, err end
if not ok then
  printError("Tessera boot error: " .. tostring(action))
  return
end

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
if action == "shutdown" then os.shutdown()
elseif action == "reboot" then os.reboot() end
-- "craftos": fall through to the stock shell
