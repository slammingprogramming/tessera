-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Minimal semantic versions: "MAJOR.MINOR.PATCH" (missing parts are 0; a "-suffix" is ignored).
-- Ranges: "*", exact "1.2.3", ">=1.2", ">1", "<=2", "<2", "=1.2.3", "^1.2.3", "~1.2.3", and space/comma-joined
-- combinations meaning AND, e.g. ">=1.2 <2".
local M = {}

function M.parse(v)
  if type(v) ~= "string" then return nil end
  local a, b, c = v:match("^v?(%d+)%.?(%d*)%.?(%d*)")
  if not a then return nil end
  return { tonumber(a), tonumber(b) or 0, tonumber(c) or 0 }
end

function M.compare(x, y)
  local a, b = M.parse(x), M.parse(y)
  if not a or not b then error("bad version: " .. tostring(x) .. " / " .. tostring(y), 2) end
  for i = 1, 3 do
    if a[i] ~= b[i] then return a[i] < b[i] and -1 or 1 end
  end
  return 0
end

local function fmt(t) return t[1] .. "." .. t[2] .. "." .. t[3] end

local function checkOne(version, op, target)
  local c = M.compare(version, target)
  if op == ">=" then return c >= 0 end
  if op == ">" then return c > 0 end
  if op == "<=" then return c <= 0 end
  if op == "<" then return c < 0 end
  return c == 0 -- "=" or ""
end

--- true when `version` satisfies `range`.
function M.satisfies(version, range)
  if range == nil or range == "" or range == "*" then return true end
  for term in range:gmatch("[^%s,]+") do
    local op, rest = term:match("^([<>=]*)(.+)$")
    local ok
    if term == "*" then
      ok = true
    elseif term:sub(1, 1) == "^" then
      local t = M.parse(term:sub(2))
      if not t then error("bad range: " .. range, 2) end
      local upper
      if t[1] > 0 then upper = { t[1] + 1, 0, 0 }
      elseif t[2] > 0 then upper = { 0, t[2] + 1, 0 }
      else upper = { 0, 0, t[3] + 1 } end
      ok = checkOne(version, ">=", fmt(t)) and checkOne(version, "<", fmt(upper))
    elseif term:sub(1, 1) == "~" then
      local t = M.parse(term:sub(2))
      if not t then error("bad range: " .. range, 2) end
      ok = checkOne(version, ">=", fmt(t)) and checkOne(version, "<", fmt({ t[1], t[2] + 1, 0 }))
    else
      if not M.parse(rest) then error("bad range: " .. range, 2) end
      ok = checkOne(version, op, rest)
    end
    if not ok then return false end
  end
  return true
end

--- Highest version in `versions` (array of strings) satisfying `range`, or nil.
function M.best(versions, range)
  local best
  for _, v in ipairs(versions) do
    if M.satisfies(v, range) and (not best or M.compare(v, best) > 0) then best = v end
  end
  return best
end

return M
