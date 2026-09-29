-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Built-in configuration defaults (lowest-priority config layer). Override in /etc/tsr/system.cfg or profile.cfg.
return {
  log = {
    level = "info",
    file = "/var/log/tsr.log",
    max_size = 32768,
  },
  boot = {
    recovery_window = 0.4,   -- seconds the boot banner waits for the recovery key (R)
    max_failed_boots = 3,    -- after this many unfinished boots in a row Tessera steps aside for plain CraftOS
    stable_after = 5,        -- seconds a boot must survive to count as successful
  },
  fs = {
    tmp_size = 65536,        -- bytes of RAM disk mounted at /tmp (0 = no /tmp)
  },
}
