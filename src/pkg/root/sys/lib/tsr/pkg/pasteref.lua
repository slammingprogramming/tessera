-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Reading the Pastebin mirror. Every file of the registry is its own paste (so a program can be fetched with `pastebin get`), and a "snapshot" paste says which
-- paste holds what. A file that is too long for one paste (or is not text) is stored in several pastes; a *reference* names them:
--     "abc123"            one paste, the text itself
--     "abc123+def456"     several pastes, joined in this order
--     "b64:abc123+def456" the joined text is base64 of the file (binary files, or very long ones)
-- Snapshot (format 2):  { format = 2, index = ref, indexSig = ref, trust = ref, trustSig = ref, docs = { [package] = ref }, blobs = { [sha256] = ref }, installer = ref }
-- Snapshot (format 1, older):  { indexJson, indexSig, pastes = { ["packages/<name>"] = id, [sha256] = id } }
-- `getter(id)` fetches the raw text of one paste (nil + reason on failure). The package manager and the bootstrap installer share this code.
local hash = require("tsr.hash")

local M = {}

--- Split a reference string into { ids = {...}, b64 = bool } (nil for anything that is not a reference).
function M.parse(ref)
  if type(ref) ~= "string" or ref == "" then return nil end
  local b64 = false
  if ref:sub(1, 4) == "b64:" then b64 = true ref = ref:sub(5) end
  local ids = {}
  for id in ref:gmatch("[^+]+") do
    if not id:match("^%w+$") then return nil end
    ids[#ids + 1] = id
  end
  if #ids == 0 then return nil end
  return { ids = ids, b64 = b64 }
end

--- The content a reference points to. Returns the data, or nil + reason.
function M.fetch(ref, getter)
  local r = M.parse(ref)
  if not r then return nil, "bad paste reference" end
  local parts = {}
  for i, id in ipairs(r.ids) do
    local text, err = getter(id)
    if not text then return nil, ("paste %s (part %d of %d): %s"):format(id, i, #r.ids, tostring(err)) end
    parts[i] = text
  end
  local data = table.concat(parts)
  if r.b64 then
    local raw = hash.base64Decode((data:gsub("%s+", "")))
    if not raw then return nil, "damaged base64 in " .. ref end
    return raw
  end
  return data
end

--- A registry file ("registry/index.json", "registry/packages/x.json", "blobs/<sha>" ...) from a snapshot table.
function M.read(snap, rel, getter)
  local ref
  if snap.format == 2 then
    if rel == "registry/index.json" then ref = snap.index
    elseif rel == "registry/index.json.sig" then ref = snap.indexSig
    elseif rel == "registry/trust.json" then ref = snap.trust
    elseif rel == "registry/trust.json.sig" then ref = snap.trustSig
    else
      local name = rel:match("^registry/packages/(.+)%.json$")
      if name then ref = snap.docs and snap.docs[name]
      else
        local sha = rel:match("^blobs/(%x+)$")
        ref = sha and snap.blobs and snap.blobs[sha]
      end
    end
    if not ref then return nil, "not in the pastebin snapshot: " .. rel end
    return M.fetch(ref, getter)
  end
  -- format 1
  if rel == "registry/index.json" then return snap.indexJson or textutils.serializeJSON(snap.index or {}) end
  if rel == "registry/index.json.sig" then return snap.indexSig end
  if rel == "registry/trust.json" then return snap.trustJson end
  if rel == "registry/trust.json.sig" then return snap.trustSig end
  local key = rel:match("^registry/packages/(.+)%.json$")
  key = key and ("packages/" .. key) or rel:match("^blobs/(%x+)$")
  local id = key and snap.pastes and snap.pastes[key]
  if not id then return nil, "not in pastebin snapshot: " .. rel end
  return getter(id)
end

--- Load and parse the snapshot named by `ref` (an id, or several joined with +). Returns the table, or nil + reason.
function M.loadSnapshot(ref, getter)
  local body, err = M.fetch(ref, getter)
  if not body then return nil, err end
  local snap = textutils.unserializeJSON(body)
  if type(snap) ~= "table" then return nil, "bad pastebin snapshot" end
  return snap
end

return M
