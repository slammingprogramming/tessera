-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Who may sign packages, and what to do about unsigned or wrongly signed registries.
--
--   Trusted keys:  the keys built into this release (set by the project's build), plus keys in /etc/tsr/trust.json that the
--                  administrator added (`pkg trust add`) or that a trusted key introduced through a signed trust update.
--                  Revoked key ids are listed in the same file and win over everything.
--   Policy:        config "pkg.signatures" = "require" (refuse anything not signed by a trusted key), "warn" (use it, say so),
--                  "off". Default: "require" when any trusted key exists, otherwise "off" (development trees).
--   Rollback:      the highest index "serial" seen per source is remembered; an older index is refused (an attacker replaying an
--                  old registry to keep you on a version with a known hole). Expired indexes only produce a warning.
local sig = require("tsr.pkg.sig")
local config = require("tsr.config")
local hash = require("tsr.hash")
local vfs = require("tsr.vfs")

local M = { sig = sig }

M.trustPath = "/etc/tsr/trust.json"
M.statePath = "/var/lib/tsr/pkg/trust-state.json"

-- Replaced at build time by the JSON list of the project's registry keys; stays as is in a development tree.
local BUILTIN = [==[@TRUSTED_KEYS@]==]

local function trustFile() return vfs.readJSON(M.trustPath) or {} end

--- All trusted keys: { [keyid] = { id, name, public, source } }.
function M.keys()
  local keys = {}
  if BUILTIN:sub(1, 1) == "[" then keys = sig.parseKeys(BUILTIN, "builtin") end
  local t = trustFile()
  for id, k in pairs(sig.parseKeys(t.keys, "local")) do keys[id] = k end
  for _, id in ipairs(t.revoked or {}) do keys[id] = nil end
  return keys
end

--- Sorted list of the trusted keys.
function M.list()
  local out = {}
  for _, k in pairs(M.keys()) do out[#out + 1] = k end
  table.sort(out, function(a, b) return a.name .. a.id < b.name .. b.id end)
  return out
end

--- "require", "warn" or "off".
function M.policy()
  local p = config.get("pkg.signatures", nil)
  if p == "require" or p == "warn" or p == "off" then return p end
  return next(M.keys()) and "require" or "off"
end

local function loadState()
  local s = vfs.readJSON(M.statePath)
  if type(s) ~= "table" then s = {} end
  s.sources = s.sources or {}
  return s
end

local function saveState(s) vfs.writeJSON(M.statePath, s) end

--- Check a source's index. Returns true plus a status word ("verified", "unchecked", "unsigned", "expired"),
--- or nil plus the reason it must not be used.
function M.verifyIndex(srcName, raw, sigRaw)
  local policy = M.policy()
  if policy == "off" then return true, "unchecked" end
  if not sigRaw then
    if policy == "require" then return nil, "the registry index is not signed (signatures are required; see `pkg trust`)" end
    return true, "unsigned"
  end
  local state = loadState()
  local digest = hash.sha256(raw .. "\0" .. sigRaw)
  local seen = state.sources[srcName]
  if seen and seen.digest == digest then return true, "verified" end
  local key, err = sig.verify(raw, sigRaw, M.keys(), sig.CONTEXT)
  if not key then
    if policy == "warn" then return true, "bad signature: " .. tostring(err) end
    return nil, err
  end
  local index = textutils.unserializeJSON(raw)
  local serial = type(index) == "table" and tonumber(index.serial) or 0
  if seen and seen.serial and serial < seen.serial then
    return nil, ("rollback refused: this index has serial %.0f but %.0f was already seen"):format(serial, seen.serial)
  end
  state.sources[srcName] = { digest = digest, serial = serial, keyid = key.id, key = key.name, time = os.epoch and os.epoch("utc") or 0 }
  saveState(state)
  local expires = type(index) == "table" and tonumber(index.expires)
  if expires and os.epoch and os.epoch("utc") / 1000 > expires then return true, "expired" end
  return true, "verified"
end

--- Check a package description against the (already verified) index entry. Returns true or nil + reason.
function M.verifyDoc(entry, raw)
  local policy = M.policy()
  if policy == "off" then return true end
  local ok, err = sig.checkDoc(raw, entry)
  if ok then return true end
  if policy == "warn" then return true end
  return nil, err
end

--- What was learnt about a source: { keyid, key, serial, time } or nil.
function M.sourceInfo(srcName)
  return loadState().sources[srcName]
end

--- Add a key to the local trust list. `public` is 64 hex characters.
function M.add(name, public)
  local keys = sig.parseKeys({ { name = name, public = public } }, "local")
  local id = next(keys)
  if not id then return nil, "a public key is 64 hexadecimal characters" end
  local t = trustFile()
  t.keys = t.keys or {}
  for _, k in ipairs(t.keys) do if k.public == public then return id, "already trusted" end end
  t.keys[#t.keys + 1] = { name = name, public = public }
  local revoked = {}
  for _, r in ipairs(t.revoked or {}) do if r ~= id then revoked[#revoked + 1] = r end end
  t.revoked = revoked
  vfs.writeJSON(M.trustPath, t)
  return id
end

--- Stop trusting a key id (also blocks a built-in key).
function M.revoke(id)
  local t = trustFile()
  t.revoked = t.revoked or {}
  for _, r in ipairs(t.revoked) do if r == id then return true end end
  t.revoked[#t.revoked + 1] = id
  local keep = {}
  for _, k in ipairs(t.keys or {}) do if sig.keyId(hash.fromHex(k.public)) ~= id then keep[#keep + 1] = k end end
  t.keys = keep
  vfs.writeJSON(M.trustPath, t)
  return true
end

--- Apply a signed trust update (registry/trust.json + signature): new keys are added, revoked ones removed. The update must be
--- signed by a key that is trusted already and carry a higher serial than the last one applied. Returns { added, revoked } or nil, err.
function M.applyUpdate(raw, sigRaw)
  local key, err = sig.verify(raw, sigRaw, M.keys(), sig.TRUST_CONTEXT)
  if not key then return nil, err end
  local doc = textutils.unserializeJSON(raw)
  if type(doc) ~= "table" then return nil, "unreadable trust update" end
  local state = loadState()
  local serial = tonumber(doc.serial) or 0
  if serial <= (state.trustSerial or 0) then return nil, "trust update is not newer than the one already applied" end
  local added, revoked = 0, 0
  for id, k in pairs(sig.parseKeys(doc.keys, "registry")) do
    if not M.keys()[id] then
      local t = trustFile()
      t.keys = t.keys or {}
      t.keys[#t.keys + 1] = { name = k.name, public = hash.toHex(k.public) }
      vfs.writeJSON(M.trustPath, t)
      added = added + 1
    end
  end
  for _, id in ipairs(doc.revoked or {}) do
    if M.keys()[id] and id ~= key.id then M.revoke(id) revoked = revoked + 1 end
  end
  state.trustSerial = serial
  saveState(state)
  return { added = added, revoked = revoked, by = key.name }
end

return M
