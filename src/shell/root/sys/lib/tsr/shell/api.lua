-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The `shell` API that programs see, compatible with the stock CraftOS shell (shell.run, shell.resolve, shell.dir, ...)
-- plus a few extensions (getenv/setenv, which stay out of the way of programs that don't use them).
local M = {}

local unpack = table.unpack or unpack

function M.build(sh)
  local api = {}

  function api.exit() sh.exiting = true end
  function api.dir() return sh.dir end
  function api.setDir(d)
    if type(d) ~= "string" then error("bad argument #1 (expected string, got " .. type(d) .. ")", 2) end
    sh.dir = sh:resolve(d)
  end
  function api.path() return sh.pathString end
  function api.setPath(p)
    if type(p) ~= "string" then error("bad argument #1 (expected string, got " .. type(p) .. ")", 2) end
    sh.pathString = p
  end
  function api.resolve(p)
    if type(p) ~= "string" then error("bad argument #1 (expected string, got " .. type(p) .. ")", 2) end
    return sh:resolve(p)
  end
  function api.resolveProgram(name)
    local alias = sh.aliases[name]
    return sh:findProgram(alias or name)
  end
  function api.aliases()
    local copy = {}
    for k, v in pairs(sh.aliases) do copy[k] = v end
    return copy
  end
  function api.setAlias(alias, program) sh.aliases[alias] = program end
  function api.clearAlias(alias) sh.aliases[alias] = nil end
  function api.programs(includeHidden)
    local list = sh:programList(includeHidden)
    return list
  end
  function api.getRunningProgram() return sh.running[#sh.running] end

  --- shell.run("edit", "a b") : the arguments are joined into one command line and run through the interpreter.
  function api.run(...)
    local line = table.concat({ ... }, " ")
    return sh:runLine(line) == 0
  end
  --- shell.execute("edit", "a.txt") : exact words, no parsing.
  function api.execute(command, ...)
    return sh:dispatch({ command, ... }) == 0
  end

  function api.complete(line) return require("tsr.shell.complete").complete(sh, line) end
  function api.completeProgram(prefix) return require("tsr.shell.complete").programs(sh, prefix) end
  function api.setCompletionFunction(program, fn)
    sh.completions[program] = { fnComplete = fn }
  end
  function api.getCompletionInfo()
    local copy = {}
    for k, v in pairs(sh.completions) do copy[k] = v end
    return copy
  end

  function api.openTab(...)
    local ms = rawget(_G, "multishell")
    if ms and ms.launch then
      local words = { ... }
      return ms.launch({ shell = api }, "/rom/programs/shell.lua", unpack(words))
    end
    error("shell.openTab needs multishell", 2)
  end
  function api.switchTab(id)
    local ms = rawget(_G, "multishell")
    if ms and ms.setFocus then return ms.setFocus(id) end
    error("shell.switchTab needs multishell", 2)
  end

  function api.version() return "CraftOS 1.8" end

  -- extensions
  function api.getenv(name) return sh:getVar(name) end
  function api.setenv(name, value) sh:setVar(name, value) end
  function api.status() return sh.status end
  api.tsh = true

  return api
end

return M
