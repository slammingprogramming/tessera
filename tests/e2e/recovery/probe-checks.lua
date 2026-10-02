-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The checks of each boot recovery scenario (see tools/test/recovery.mjs for how the computer is prepared). Each function gets
-- { check, conf, readFile, exists, log(), bootCount() } and runs after the boot it is about.
local function systemUp(e, label)
  e.check(label .. ": Tessera is running", rawget(_G, "tsr") ~= nil and type(tsr.version) == "table")
  local K = require("tsr.kernel")
  local shell
  for _, p in ipairs(K.list()) do if p.name == "shell" then shell = p end end
  e.check(label .. ": the interactive shell session is up", shell ~= nil)
end

local checks = {}

checks["interrupted-file-writes"] = function(e)
  systemUp(e, "boot")
  e.check("a partial write (.tsr-tmp) is discarded", not e.exists("/etc/tsr/e2e/a.cfg.tsr-tmp") and not e.exists("/etc/tsr/e2e/a.cfg"))
  e.check("a complete write (.tsr-new) is finished", e.readFile("/etc/tsr/e2e/b.cfg") == "new b" and not e.exists("/etc/tsr/e2e/b.cfg.tsr-new")
    and not e.exists("/etc/tsr/e2e/b.cfg.tsr-old"))
  e.check("a lost file (only .tsr-old left) is restored", e.readFile("/etc/tsr/e2e/c.cfg") == "old c" and not e.exists("/etc/tsr/e2e/c.cfg.tsr-old"))
  e.check("the repair was logged", e.log():find("recovered 3 interrupted file write", 1, true) ~= nil, e.log():sub(-600))
end

checks["interrupted-install-rolls-back"] = function(e)
  systemUp(e, "boot")
  e.check("a replaced file is back to its old version", e.readFile("/usr/e2e/x.lua") == "OLD X" and not e.exists("/usr/e2e/x.lua.tsr-old"))
  e.check("a newly installed file is removed again", not e.exists("/usr/e2e/y.lua"))
  e.check("the journal and the staging area are gone", not e.exists("/var/lib/tsr/pkg/txn.json") and not e.exists("/var/cache/tsr/stage"))
  e.check("the rollback was logged", e.log():find("rolled back", 1, true) ~= nil, e.log():sub(-600))
end

checks["finished-install-is-cleaned-up"] = function(e)
  systemUp(e, "boot")
  e.check("the new version stays", e.readFile("/usr/e2e/z.lua") == "NEW Z")
  e.check("the old version of a user-modified file is kept as a backup", e.readFile("/etc/tsr/backup/usr/e2e/z.lua") == "OLD Z" and not e.exists("/usr/e2e/z.lua.tsr-old"))
  e.check("files the new version no longer ships are removed", not e.exists("/usr/e2e/gone.lua"))
  e.check("the journal is gone", not e.exists("/var/lib/tsr/pkg/txn.json"))
end

checks["garbage-config"] = function(e)
  systemUp(e, "boot")
  e.check("the damaged file is reported in the log", e.log():find("is damaged and was ignored", 1, true) ~= nil, e.log():sub(1, 800))
  e.check("a copy of the damaged file was kept", e.readFile("/etc/tsr/system.cfg.damaged") == "this is { not lua (((")
end

checks["crashing-daemon"] = function(e)
  systemUp(e, "boot")
  e.check("a daemon started after the crashing one still ran", e.exists("/tmp/e2e-flag") or e.exists("/etc/tsr/e2e-flag"))
  e.check("the crash is in the log", e.log():find("boom", 1, true) ~= nil, e.log():sub(-800))
end

checks["broken-service-definition"] = function(e)
  systemUp(e, "boot")
  local svc = require("tsr.svc")
  local up = {}
  for _, st in ipairs(svc.list()) do up[st.name] = st.state end
  e.check("the healthy services are running", up.netd == "running" and up.crond == "running", textutils.serialize(up))
  e.check("the broken service is not running", up.brokensvc ~= "running", tostring(up.brokensvc))
end

checks["missing-front-end"] = function(e)
  e.check("Tessera is running", rawget(_G, "tsr") ~= nil)
  local K = require("tsr.kernel")
  local shell
  for _, p in ipairs(K.list()) do if p.name == "shell" then shell = p end end
  e.check("the configured desktop is not installed: the shell session starts instead", shell ~= nil)
end

checks["corrupt-package-database"] = function(e)
  systemUp(e, "boot")
  local ok, err = pcall(function() return require("tsr.pkg.db").names() end)
  e.check("the package database can be read (as empty) after being damaged", ok, tostring(err))
end

checks["stable-boot-resets-counter"] = function(e)
  systemUp(e, "boot")
  sleep(1.5)
  e.check("the boot counter was reset after the system stayed up", e.bootCount() == 0, tostring(e.bootCount()))
end

checks["crash-loop-guard"] = function(e)
  e.check("Tessera is not running (stage 0 failed or stepped aside)", rawget(_G, "tsr") == nil)
  e.check("the CraftOS shell environment is available", type(shell) == "table")
  -- the counter value is verified by the runner across the sequence of boots
end

checks["disabled-flag"] = function(e)
  e.check("Tessera is not running", rawget(_G, "tsr") == nil)
  e.check("the flag file is still there", e.exists("/etc/tsr/disabled"))
  e.check("a skipped boot is not counted", (e.bootCount() or 0) == 0, tostring(e.bootCount()))
end

checks["recovery-key"] = function(e)
  e.check("Tessera is not running after R was pressed", rawget(_G, "tsr") == nil)
  e.check("a skipped boot is not counted", (e.bootCount() or 0) == 0, tostring(e.bootCount()))
end

return checks
