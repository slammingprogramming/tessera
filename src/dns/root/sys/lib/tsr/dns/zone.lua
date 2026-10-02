-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Zone files for the in-game name service. A zone file is plain text, one record per line:
--
--     $origin base            names without a dot get this suffix:  "farm1" means "farm1.base"
--     $ttl 3600               default time to live of the records below, in seconds
--     farm1        A      14          the name points at computer 14
--     gate         A      9
--     www          CNAME  farm1       an alias for another name
--     ssh.farm1    TXT    "main entrance, key SHA256:..."
--     @            NS     3           the name server(s) for this zone: computer ids
--
-- Names are lower case letters, digits, '-' and '_' separated by dots. "@" is the origin itself.
local M = {}

M.TYPES = { A = true, CNAME = true, TXT = true, NS = true }

--- Normalise a name: lower case, only the allowed characters. With an `origin`, names are relative to it ("note.farm1" in zone "base" is
--- "note.farm1.base") unless they end with a dot (absolute) or already end with the origin. Returns the name or nil + reason.
function M.normalize(name, origin)
  name = tostring(name or ""):lower()
  local absolute = name:sub(-1) == "."
  name = name:gsub("%.$", "")
  if name == "@" then name = origin or "" end
  if name == "" then return nil, "empty name" end
  if origin and origin ~= "" and not absolute and name ~= origin and name:sub(-(#origin + 1)) ~= "." .. origin then name = name .. "." .. origin end
  if #name > 120 or not name:match("^[%w_%-%.]+$") or name:find("..", 1, true) or name:sub(1, 1) == "." then return nil, "bad name '" .. name .. "'" end
  return name
end

--- Parse a zone file. Returns { origin, ttl, records = { { name, type, value, ttl } } }, problems.
function M.parse(text)
  local zone, problems = { origin = "", ttl = 3600, records = {} }, {}
  local n = 0
  for line in ((text or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    n = n + 1
    local stripped = line:gsub(";.*$", ""):gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if stripped ~= "" then
      local directive, arg = stripped:match("^%$(%a+)%s+(%S+)$")
      if directive then
        directive = directive:lower()
        if directive == "origin" then zone.origin = arg:lower():gsub("%.$", "")
        elseif directive == "ttl" and tonumber(arg) then zone.ttl = tonumber(arg)
        else problems[#problems + 1] = ("line %d: unknown directive $%s"):format(n, directive) end
      else
        local name, kind, value = stripped:match("^(%S+)%s+(%a+)%s+(.+)$")
        kind = kind and kind:upper()
        if not (name and M.TYPES[kind]) then
          problems[#problems + 1] = ("line %d: expected <name> A|CNAME|TXT|NS <value>"):format(n)
        else
          local fullName, err = M.normalize(name, zone.origin)
          if not fullName then problems[#problems + 1] = ("line %d: %s"):format(n, err)
          else
            value = value:gsub("^\"(.*)\"$", "%1")
            local ttl = zone.ttl
            if kind == "A" or kind == "NS" then
              local id = tonumber(value:match("^(%d+)"))
              local extra = tonumber(value:match("^%d+%s+(%d+)$"))
              if not id then problems[#problems + 1] = ("line %d: %s needs a computer id"):format(n, kind) else
                zone.records[#zone.records + 1] = { name = fullName, type = kind, value = id, ttl = extra or ttl }
              end
            elseif kind == "CNAME" then
              local target, terr = M.normalize(value, zone.origin)
              if not target then problems[#problems + 1] = ("line %d: %s"):format(n, terr) else
                zone.records[#zone.records + 1] = { name = fullName, type = "CNAME", value = target, ttl = ttl }
              end
            else
              zone.records[#zone.records + 1] = { name = fullName, type = "TXT", value = value, ttl = ttl }
            end
          end
        end
      end
    end
  end
  return zone, problems
end

--- Render records back into text (without directives).
function M.format(records)
  local out = {}
  for _, r in ipairs(records) do
    out[#out + 1] = ("%s %s %s"):format(r.name, r.type, r.type == "TXT" and ('"' .. tostring(r.value) .. '"') or tostring(r.value))
  end
  return table.concat(out, "\n") .. (#out > 0 and "\n" or "")
end

return M
