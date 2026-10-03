-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The avd service: scans a floppy or other disk when it is inserted (before anything on it runs automatically), scans the folders named in the settings every few
-- hours, and fetches new definitions from the configured sources. What it finds goes to /var/log/av.log and, with action = quarantine, into the quarantine.
local av = require("tsr.av")
local vfs = require("tsr.vfs")
local log = require("tsr.log").get("avd")

local M = {}

local function notify(text)
  local ok, n = pcall(require, "tsr.notify")
  if ok and n.send then pcall(n.send, "Anti-virus", text) end
end

--- Scan what is on a disk drive. Returns the summary.
function M.scanDisk(side, settings)
  local ok, path = pcall(peripheral.call, side, "getMountPath")
  if not ok or not path then return nil end
  local summary = av.scanTree(path, { settings = settings, skipKnown = false })
  if summary.malicious > 0 or summary.suspicious > 0 then
    local text = ("disk on %s: %d malicious, %d suspicious file(s)"):format(side, summary.malicious, summary.suspicious)
    log.warn("%s", text)
    av.log(text)
    notify(text)
  else
    log.info("%s", ("disk on %s is clean (%d files)"):format(side, summary.scanned))
  end
  return summary
end

function M.main()
  local lastUpdate, lastWatch = 0, 0
  log.info("%s", "anti-virus running, definitions: " .. av.loadDefs(true).sources)
  local timer
  local function schedule() timer = os.startTimer(60) end
  schedule()
  while true do
    local ev, a = os.pullEvent()
    local s = av.settings()
    if ev == "disk" and s.scan_disks then
      M.scanDisk(a, s)
    elseif ev == "timer" and a == timer then
      local now = os.epoch and os.epoch("utc") / 1000 or os.clock()
      if #s.sources > 0 and now - lastUpdate > (s.update_hours or 24) * 3600 then
        lastUpdate = now
        for _, src in ipairs(s.sources) do
          local version, why = av.defs.update(src, {})
          if version then log.info("%s", "new definitions v" .. version .. " from " .. src) av.loadDefs(true)
          elseif not tostring(why):find("not newer", 1, true) then log.warn("%s", src .. ": " .. tostring(why)) end
        end
      end
      if #s.watch > 0 and now - lastWatch > 6 * 3600 then
        lastWatch = now
        for _, dir in ipairs(s.watch) do
          local sum = av.scanTree(dir, { settings = s })
          if sum.malicious + sum.suspicious > 0 then
            local text = ("%s: %d malicious, %d suspicious file(s)"):format(dir, sum.malicious, sum.suspicious)
            log.warn("%s", text)
            notify(text)
          end
        end
      end
      schedule()
    end
  end
end

return M
