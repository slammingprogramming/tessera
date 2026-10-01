-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Tab completion for tsh. Returns the suffixes that complete the last word of `line` (the contract of CraftOS' `read`).
local M = {}

local function sortedUnique(list)
  local seen, out = {}, {}
  for _, s in ipairs(list) do
    if not seen[s] then seen[s] = true out[#out + 1] = s end
  end
  table.sort(out)
  return out
end

local function suffixes(candidates, partial)
  local out = {}
  for _, c in ipairs(candidates) do
    if c:sub(1, #partial) == partial and #c > #partial then out[#out + 1] = c:sub(#partial + 1) end
  end
  return sortedUnique(out)
end

--- Program names (and aliases and builtins) that start with `prefix`, as suffixes. A prefix containing "/" completes paths.
function M.programs(sh, prefix)
  prefix = prefix or ""
  if prefix:find("/", 1, true) then
    return fs.complete(prefix, sh.dir, true, true) or {}
  end
  local names = sh:programList(false)
  for alias in pairs(sh.aliases) do names[#names + 1] = alias end
  for b in pairs(require("tsr.shell.builtins")) do names[#names + 1] = b end
  return suffixes(names, prefix)
end

local function pathCompletions(sh, partial, dirsOnly)
  local ok, res = pcall(fs.complete, partial, sh.dir, not dirsOnly, true)
  if not ok or type(res) ~= "table" then return {} end
  return res
end

--- Split into words on spaces (no quote handling: this only has to be good enough for completion).
local function words(line)
  local out = {}
  for w in line:gmatch("%S+") do out[#out + 1] = w end
  return out
end

function M.complete(sh, line)
  local ws = words(line)
  local trailing = line:match("%s$") ~= nil
  if #ws == 0 or (#ws == 1 and not trailing) then
    return M.programs(sh, ws[1] or "")
  end
  local partial = trailing and "" or ws[#ws]
  local previous = {}
  for i = 1, #ws - (trailing and 0 or 1) do previous[i] = ws[i] end
  local name = ws[1]
  local alias = sh.aliases[name]
  if alias then name = alias:match("%S+") or name end

  local builtins = require("tsr.shell.builtins")
  local meta = builtins.completion and builtins.completion[name]
  if meta == "dirs" then return pathCompletions(sh, partial, true) end
  if meta == "vars" then
    local names = {}
    for k in pairs(sh.vars) do names[#names + 1] = k end
    return suffixes(names, partial)
  end
  if meta == "aliases" then
    local names = {}
    for k in pairs(sh.aliases) do names[#names + 1] = k end
    return suffixes(names, partial)
  end
  if meta == "programs" then return M.programs(sh, partial) end

  local path = sh:findProgram(name)
  local info = path and sh.completions[path]
  if info and info.fnComplete then
    local ok, res = pcall(info.fnComplete, sh.api, #previous, partial, previous)
    if ok and type(res) == "table" then return res end
    return {}
  end
  return pathCompletions(sh, partial, false)
end

return M
