-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The application-facing system API (also exposed as the global `tsr` once booted). Apps should depend on this
-- module rather than on kernel internals.
local kernel = require("tsr.kernel")
local power = require("tsr.power")

local S = {}

S.version = require("tsr.version")
S.config = require("tsr.config")
S.vfs = require("tsr.vfs")
S.require = require("tsr.loader").require

function S.log(name) return require("tsr.log").get(name) end
function S.profile() return require("tsr.profile").get() end
function S.capabilities() return require("tsr.profile").capabilities() end

function S.hostname()
  return S.config.get("net.hostname") or os.getComputerLabel() or ("cc-" .. os.getComputerID())
end

--- Start a process (see kernel.spawn for the spec fields).
function S.spawn(spec) return kernel.spawn(spec) end

--- Run a Lua program as a child process and wait for it. Returns ok, err.
function S.exec(path, ...)
  local pid, err = kernel.spawn({ name = path, path = path, args = { ... }, window = false })
  if not pid then return false, err end
  return kernel.wait(pid)
end

function S.pid() return kernel.current() end
function S.processes() return kernel.list() end

--- Leave Tessera and return to the plain CraftOS shell.
function S.exit() kernel.stop("craftos") end
function S.shutdown()
  if kernel.isRunning() then kernel.stop("shutdown") else power.shutdown() end
end
function S.reboot()
  if kernel.isRunning() then kernel.stop("reboot") else power.reboot() end
end

--- AGPL-3.0 section 13: where the corresponding source of this system can be obtained.
function S.sourceInfo()
  return { license = S.version.license, source = S.version.source, version = S.version.version }
end

return S
