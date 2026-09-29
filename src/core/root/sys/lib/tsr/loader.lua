-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Shared module loader. All Tessera code (kernel, services, apps) shares ONE module cache so singletons such as the
-- kernel, config and log really are singletons across processes. CraftOS' own `require` gives every program a private
-- cache, which is why processes started by the kernel get this loader's `require` instead.
local M = {}

M.loaded = {}
M.loading = {}

local function buildPath()
  local p = {
    "/sys/lib/?.lua", "/sys/lib/?/init.lua",
    "/usr/lib/?.lua", "/usr/lib/?/init.lua",
    "/rom/modules/main/?.lua", "/rom/modules/main/?/init.lua",
  }
  if rawget(_G, "turtle") then
    p[#p + 1] = "/rom/modules/turtle/?.lua"
    p[#p + 1] = "/rom/modules/turtle/?/init.lua"
  end
  if rawget(_G, "commands") then
    p[#p + 1] = "/rom/modules/command/?.lua"
    p[#p + 1] = "/rom/modules/command/?/init.lua"
  end
  return p
end

M.path = buildPath()

--- Find the file that provides module `name`. Returns path or nil, tried-paths.
function M.search(name)
  local rel = name:gsub("%.", "/")
  local tried = {}
  for _, pat in ipairs(M.path) do
    local file = pat:gsub("%?", rel)
    if fs.exists(file) and not fs.isDir(file) then return file end
    tried[#tried + 1] = file
  end
  return nil, tried
end

--- Environment every module is loaded with: real globals, plus this loader's `require`. Accidental global writes in a
--- module land in its own table instead of polluting _G.
M.env = setmetatable({}, { __index = _G })

function M.require(name)
  if type(name) ~= "string" then error("module name must be a string", 2) end
  local cached = M.loaded[name]
  if cached ~= nil then return cached end
  if M.loading[name] then error("loop or previous error loading module '" .. name .. "'", 2) end
  local file, tried = M.search(name)
  if not file then
    error("module '" .. name .. "' not found:\n  " .. table.concat(tried, "\n  "), 2)
  end
  local chunk, err = loadfile(file, "t", M.env)
  if not chunk then error("error loading module '" .. name .. "': " .. tostring(err), 2) end
  M.loading[name] = true
  local ok, result = pcall(chunk, name, file)
  M.loading[name] = nil
  if not ok then error(result, 0) end
  if result == nil then result = true end
  M.loaded[name] = result
  return result
end

--- Forget a module so the next require() reloads it (used by tests and package upgrades).
function M.unload(name) M.loaded[name] = nil end

--- Register an already-built module under `name` (e.g. the loader itself).
function M.preload(name, value) M.loaded[name] = value end

M.env.require = M.require
M.env.package = { loaded = M.loaded, path = table.concat(M.path, ";") }
M.loaded["tsr.loader"] = M

return M
