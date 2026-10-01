-- SPDX-License-Identifier: AGPL-3.0-or-later
-- tsh: the Tessera shell.
--   tsh                 interactive shell
--   tsh script.tsh ...  run a script (arguments become $1, $2, ...)
--   tsh -c "command"    run one command line
local req = (rawget(_G, "tsr") and tsr.require) or dofile("/sys/lib/tsr/loader.lua").require
local exec = req("tsr.shell.exec")
local repl = req("tsr.shell.repl")

local args = { ... }
local sh = exec.new({ parentShell = rawget(_G, "shell") })

if args[1] == "-c" then
  if not args[2] then printError("usage: tsh -c \"command\"") return false end
  local st = sh:runLine(args[2])
  return st == 0
elseif args[1] == "-h" or args[1] == "--help" then
  print("usage: tsh [script [args...]] | tsh -c \"command\"")
  return true
elseif args[1] then
  return sh:runScriptFile(args[1], { table.unpack(args, 2) }) == 0
end
repl.run(sh)
return true
