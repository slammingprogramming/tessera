-- SPDX-License-Identifier: AGPL-3.0-or-later
-- sandbox <program> [args...]   run a program with restricted access (no network, peripherals or real files)
local req = (rawget(_G, "tsr") and tsr.require) or dofile("/sys/lib/tsr/loader.lua").require
local sandbox = req("tsr.sandbox")
local args = { ... }
if not args[1] then print("usage: sandbox <program> [args...]") return false end
local path = shell and shell.resolve(args[1]) or args[1]
local name = fs.getName(path):gsub("%.lua$", "")
local ok, err = sandbox.run(path, { root = "/var/sandbox/" .. name, args = { table.unpack(args, 2) } })
if not ok then printError(tostring(err)) end
return ok
