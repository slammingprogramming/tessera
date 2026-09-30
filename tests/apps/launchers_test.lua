-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Integrity checks over every installed command and app module: each command launcher points at a module that exists,
-- and every module compiles and loads (so a typo in any app is caught even without a dedicated test).

local function listLua(dir)
  local out = {}
  if not fs.isDir(dir) then return out end
  for _, name in ipairs(fs.list(dir)) do
    if name:match("%.lua$") then out[#out + 1] = dir .. "/" .. name end
  end
  table.sort(out)
  return out
end

local function read(path)
  local h = fs.open(path, "r")
  local s = h.readAll()
  h.close()
  return s
end

test("every command launcher names an existing module and calls a real function", function()
  local checked = 0
  for _, dir in ipairs({ "/usr/bin", "/sys/bin" }) do
    for _, path in ipairs(listLua(dir)) do
      local text = read(path)
      local modName, fn = text:match('req%("([%w%._%-]+)"%)%.(%w+)')
      if modName then
        checked = checked + 1
        ok(loader.search(modName), path .. " -> module " .. modName .. " not found")
        local mod = require(modName)
        ok(type(mod[fn]) == "function", path .. " -> " .. modName .. "." .. fn .. " is not a function")
      end
    end
  end
  ok(checked >= 20, "expected many launchers, found " .. checked)
end)

test("every app module compiles and loads", function()
  local count = 0
  for _, path in ipairs(listLua("/usr/lib/tsrapps")) do
    local name = "tsrapps." .. fs.getName(path):gsub("%.lua$", "")
    local chunk, err = loadfile(path, "t", loader.env)
    ok(chunk, tostring(err))
    local good, mod = pcall(require, name)
    ok(good, name .. ": " .. tostring(mod))
    count = count + 1
  end
  ok(count >= 20, "expected many app modules, found " .. count)
end)

test("commands do not shadow stock CraftOS programs", function()
  local stock = {}
  for _, name in ipairs(fs.list("/rom/programs")) do stock[name:gsub("%.lua$", "")] = true end
  for _, sub in ipairs({ "advanced", "http", "rednet", "turtle", "fun", "command", "pocket" }) do
    if fs.isDir("/rom/programs/" .. sub) then
      for _, name in ipairs(fs.list("/rom/programs/" .. sub)) do stock[name:gsub("%.lua$", "")] = true end
    end
  end
  for _, dir in ipairs({ "/usr/bin", "/sys/bin" }) do
    for _, path in ipairs(listLua(dir)) do
      local cmd = fs.getName(path):gsub("%.lua$", "")
      ok(not stock[cmd], "the command '" .. cmd .. "' hides a stock CraftOS program")
    end
  end
end)

test("every command file has an SPDX header", function()
  for _, dir in ipairs({ "/usr/bin", "/sys/bin", "/usr/lib/tsrapps", "/sys/lib/tsr" }) do
    for _, path in ipairs(listLua(dir)) do
      ok(read(path):find("SPDX-License-Identifier: AGPL-3.0-or-later", 1, true), path .. " has no SPDX header")
    end
  end
end)
