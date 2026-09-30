-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Boot daemon: if `gpshost setup` was run and a wireless modem is attached, host the GPS beacon in the background.
local vfs = require("tsr.vfs")
local cfg = vfs.readTable("/etc/tsr/gps.cfg")
if not cfg or not cfg.x then return end
local has = false
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "modem" and peripheral.call(name, "isWireless") then has = true end
end
if not has then return end
require("tsr.kernel").spawn({
  name = "gps-host",
  fn = function() os.run({}, "/rom/programs/gps.lua", "host", tostring(cfg.x), tostring(cfg.y), tostring(cfg.z)) end,
})
