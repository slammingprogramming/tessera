-- SPDX-License-Identifier: AGPL-3.0-or-later
-- MQTT topic names ("home/kitchen/light") and filters ("home/+/light", "home/#").
local M = {}

local function levels(s)
  local out = {}
  for part in (s .. "/"):gmatch("([^/]*)/") do out[#out + 1] = part end
  return out
end

--- A topic name to publish to: no wildcards, not empty.
function M.validTopic(t)
  return type(t) == "string" and #t > 0 and #t <= 1024 and not t:find("[#+]") and not t:find("\0", 1, true)
end

--- A filter to subscribe with: + for exactly one level, # (last, whole level) for all the rest.
function M.validFilter(f)
  if type(f) ~= "string" or #f == 0 or #f > 1024 or f:find("\0", 1, true) then return false end
  local parts = levels(f)
  for i, p in ipairs(parts) do
    if p:find("#", 1, true) then
      if p ~= "#" or i ~= #parts then return false end
    elseif p:find("+", 1, true) and p ~= "+" then return false end
  end
  return true
end

--- Does the filter match the topic? (Filters that start with a wildcard do not match topics starting with $, the broker's own.)
function M.match(filter, topic)
  local f, t = levels(filter), levels(topic)
  if t[1]:sub(1, 1) == "$" and (f[1] == "#" or f[1] == "+") then return false end
  for i, part in ipairs(f) do
    if part == "#" then return true end
    if t[i] == nil then return false end
    if part ~= "+" and part ~= t[i] then return false end
  end
  return #f == #t
end

--- Does the rule filter allow subscribing with this filter? (everything the requested filter can match is also matched by the rule)
function M.covers(rule, filter)
  local r, q = levels(rule), levels(filter)
  for i, part in ipairs(r) do
    if part == "#" then return true end
    local want = q[i]
    if want == nil then return false end
    if part == "+" then
      if want == "#" then return false end
    elseif part ~= want then return false end
  end
  return #r == #q
end

return M
