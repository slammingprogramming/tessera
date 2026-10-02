-- SPDX-License-Identifier: AGPL-3.0-or-later
-- End-to-end boot test. Installed as /etc/tsr/init.d/boot_e2e.lua on a computer that boots Tessera for real.
-- Runs as a kernel daemon: drives the shell session by injecting keystrokes, inspects its window, writes
-- /out/results.json, then powers the machine off through Tessera.
local K = require("tsr.kernel")

local tests = {}
local passed, failed = 0, 0
local function check(name, cond, info)
  tests[#tests + 1] = { name = name, ok = cond and true or false, err = (not cond) and tostring(info or "check failed") or nil }
  if cond then passed = passed + 1 else failed = failed + 1 end
end

local function windowText(win)
  local w, h = win.getSize()
  local lines = {}
  for y = 1, h do lines[#lines + 1] = win.getLine(y) end
  return table.concat(lines, "\n")
end

local function typeLine(s)
  for c in s:gmatch(".") do os.queueEvent("char", c) end
  os.queueEvent("key", keys.enter, false)
  os.queueEvent("key_up", keys.enter)
end

local function finish(extra)
  local out = fs.open("/out/results.json", "w")
  out.write(textutils.serializeJSON({
    files = { { file = "e2e/boot", tests = tests } },
    passed = passed, failed = failed, skipped = 0, fatal = extra,
  }))
  out.close()
  tsr.shutdown()
end

local ok, err = pcall(function()
  sleep(1.0)
  local shellProc
  for _, p in ipairs(K.list()) do if p.name == "shell" then shellProc = p end end
  check("shell session exists and is focused", shellProc and shellProc.focused, "no focused shell process")
  check("global tsr API is exposed", type(rawget(_G, "tsr")) == "table" and tsr.version.name == "Tessera")
  check("profile is detected", tsr.profile() == "client" or tsr.profile() == "client-lite", tostring(tsr.profile()))
  check("/tmp RAM disk is mounted", fs.isDir("/tmp"))

  typeLine("echo tessera-ok")
  sleep(0.6)
  local text = windowText(K.get(shellProc.pid).win)
  check("shell runs commands inside a Tessera process", text:find("tessera%-ok") ~= nil, text)

  typeLine("lua")
  sleep(0.6)
  typeLine("return 'A' .. require('tsr.util').trim('  hi  ') .. 'B'")
  sleep(0.6)
  text = windowText(K.get(shellProc.pid).win)
  check("CraftOS programs can require Tessera modules", text:find("AhiB", 1, true) ~= nil, text)
  typeLine("exit()")
  sleep(0.4)

  -- write into /tmp through the patched fs, read back with a stock program
  local h = fs.open("/tmp/e2e.txt", "w") h.write("ram") h.close()
  typeLine("list /tmp")
  sleep(0.6)
  text = windowText(K.get(shellProc.pid).win)
  check("stock programs see the /tmp mount", text:find("e2e.txt", 1, true) ~= nil, text)

  -- the service manager brought up the autostart services of the installed packages
  local svc = require("tsr.svc")
  local up = {}
  for _, st in ipairs(svc.list()) do up[st.name] = st.state end
  check("services start at boot (netd, crond, rulesd)", up.netd == "running" and up.crond == "running" and up.rulesd == "running",
    textutils.serialize(up))
  check("services that must be switched on deliberately stay off", up.pkgmirrord == "stopped" and up.kioskd == "stopped" and up.webgwd == "stopped"
    and up.shopd == "stopped" and up.rscreend == "stopped" and up.fleetd == "stopped", textutils.serialize(up))
  check("tsh is the session shell", rawget(_G, "tsr") ~= nil and fs.exists("/sys/lib/tsr/shell/repl.lua"))

  local src = tsr.sourceInfo()
  check("AGPL source info is available", src.license == "AGPL-3.0-or-later" and type(src.source) == "string")
end)
finish(not ok and tostring(err) or nil)
