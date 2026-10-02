-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Probe for the boot recovery scenarios (tools/test/recovery.mjs). Installed on the test computer as /etc/tsr/init.d/99-probe.lua
-- ("daemon" mode: Tessera booted, this runs inside it) or as /startup/99-probe.lua ("startup" mode: runs after /startup.lua returned,
-- i.e. when Tessera stepped aside or failed). It reads /probe.json, runs the checks of its scenario from /probe-checks.lua, writes
-- /out/recovery-<scenario>-<boot>.json and powers the machine off.
local conf = {}
do
  local h = fs.open("/probe.json", "r")
  if h then conf = textutils.unserializeJSON(h.readAll()) or {} h.close() end
end

local results = {}
local function check(name, cond, info)
  results[#results + 1] = { name = name, ok = cond and true or false, err = (not cond) and tostring(info or "check failed") or nil }
end

local function readFile(path)
  local h = fs.open(path, "rb")
  if not h then return nil end
  local s = h.readAll()
  h.close()
  return s
end

local e = {
  check = check, conf = conf, readFile = readFile, exists = fs.exists,
  log = function() return readFile("/var/log/tsr.log") or "" end,
  bootCount = function() return tonumber(readFile("/var/lib/tsr/boot.count")) end,
}

local fatal
local okChecks, checks = pcall(function()
  local chunk, lerr = loadfile("/probe-checks.lua", "t", _ENV)     -- the checks use this program's environment (require, shell, tsr)
  if not chunk then error(lerr, 0) end
  return chunk()
end)
if not okChecks then fatal = "cannot load the checks: " .. tostring(checks)
elseif type(checks[conf.scenario]) ~= "function" then fatal = "no checks for scenario " .. tostring(conf.scenario)
else
  if conf.mode == "daemon" then sleep(conf.wait or 1.5) end
  local ok, err = pcall(checks[conf.scenario], e)
  if not ok then fatal = tostring(err) end
end

local out = fs.open(("/out/recovery-%s-%d.json"):format(tostring(conf.scenario), conf.boot or 1), "w")
out.write(textutils.serializeJSON({ scenario = conf.scenario, boot = conf.boot, results = results, fatal = fatal, bootCount = e.bootCount() }))
out.close()

if conf.mode == "daemon" and rawget(_G, "tsr") then tsr.shutdown() else os.shutdown() end
