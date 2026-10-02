-- SPDX-License-Identifier: AGPL-3.0-or-later
-- A keyring: the keys a person knows (public keys, their certifications) and owns (secret keys), plus owner trust for the web of
-- trust. Files live in one directory (default ~/.pgp):
--   keys/<fingerprint>.pub    armored public key block      keys/<fingerprint>.sec   armored secret key block (own keys)
--   trust.json                { ownertrust = { [fingerprint] = "ultimate" | "full" | "marginal" | "none" } }
local pgp = require("tsr.pgp")
local armor = require("tsr.pgp.armor")
local vfs = require("tsr.vfs")

local M = {}
local Ring = {}
Ring.__index = Ring

--- The default keyring directory: ~/.pgp of the logged-in user, else /root/.pgp.
function M.defaultDir()
  local ok, auth = pcall(require, "tsr.auth")
  if ok and type(auth) == "table" and auth.current then
    local me = auth.current()
    local u = me and auth.get(me)
    if u and u.home then return u.home .. "/.pgp" end
  end
  return "/root/.pgp"
end

function M.open(dir)
  local self = setmetatable({ dir = dir or M.defaultDir(), cache = nil }, Ring)
  return self
end

function Ring:path(fp, ext) return self.dir .. "/keys/" .. fp .. "." .. ext end

local function readText(path) return vfs.readFile(path) end

--- All keys (public view), sorted by identity. Keys that have a secret file have `hasSecret = true`.
function Ring:keys()
  if self.cache then return self.cache end
  local list = {}
  local dir = self.dir .. "/keys"
  if fs.isDir(dir) then
    for _, name in ipairs(fs.list(dir)) do
      local fp = name:match("^(%x+)%.pub$")
      if fp then
        local text = readText(dir .. "/" .. name)
        local key = text and pgp.importText(text)
        if key and pgp.fpHex(key) == fp then
          key.hasSecret = fs.exists(self:path(fp, "sec"))
          list[#list + 1] = key
        end
      end
    end
  end
  table.sort(list, function(a, b) return a.uid:lower() .. pgp.fpHex(a) < b.uid:lower() .. pgp.fpHex(b) end)
  self.cache = list
  return list
end

function Ring:invalidate() self.cache = nil end

--- Find one key by fingerprint prefix, key id (last 16 digits) or part of the identity. Returns key or nil + reason.
function Ring:find(query)
  query = tostring(query or "")
  local hexq = query:gsub("%s", ""):lower()
  local found = {}
  for _, k in ipairs(self:keys()) do
    local fp = pgp.fpHex(k)
    if (#hexq >= 8 and hexq:match("^%x+$") and (fp:sub(1, #hexq) == hexq or fp:sub(-#hexq) == hexq)) or k.uid:lower():find(query:lower(), 1, true) then
      found[#found + 1] = k
    end
  end
  if #found == 1 then return found[1] end
  if #found == 0 then return nil, "no key matches '" .. query .. "'" end
  return nil, ("'%s' matches %d keys; be more specific"):format(query, #found)
end

local function saveCerts(self, key)
  vfs.writeFile(self:path(pgp.fpHex(key), "pub"), pgp.exportPublic(key))
  self:invalidate()
end

--- Merge an armored key block into the keyring. Returns key, "new" | "updated" | "unchanged" or nil + reason.
function Ring:add(text)
  local key, err = pgp.importText(text)
  if not key then return nil, err end
  local fp = pgp.fpHex(key)
  local existing
  for _, k in ipairs(self:keys()) do if pgp.fpHex(k) == fp then existing = k end end
  if not existing then
    saveCerts(self, key)
    return key, "new"
  end
  local changed = false
  local seen = {}
  for _, c in ipairs(existing.certs) do seen[c.signer .. c.created] = true end
  for _, c in ipairs(key.certs) do
    if not seen[c.signer .. c.created] then existing.certs[#existing.certs + 1] = c changed = true end
  end
  if key.revoked and not existing.revoked then existing.revoked, existing.revocation = true, key.revocation changed = true end
  if changed then saveCerts(self, existing) return existing, "updated" end
  return existing, "unchanged"
end

--- Store an own key (with its secret part, optionally sealed by a passphrase). Marks it ultimately trusted.
function Ring:addSecret(key, passphrase)
  local fp = pgp.fpHex(key)
  vfs.writeFile(self:path(fp, "sec"), pgp.exportSecret(key, passphrase))
  vfs.writeFile(self:path(fp, "pub"), pgp.exportPublic(key))
  self:setTrust(fp, "ultimate")
  self:invalidate()
end

--- Load the secret part of one of your keys. Returns the unlocked key, or nil + "passphrase" / reason.
function Ring:unlock(key, passphrase)
  local text = readText(self:path(pgp.fpHex(key), "sec"))
  if not text then return nil, "you do not have the secret key for " .. key.uid end
  local kind, bin = armor.dearmor(text, "SECRET KEY")
  if not kind then return nil, bin end
  local full, err = pgp.parseBlock(bin)
  if not full then return nil, err end
  local ok, uerr = pgp.unlock(full, passphrase)
  if not ok then return nil, uerr end
  return full
end

function Ring:needsPassphrase(key)
  local text = readText(self:path(pgp.fpHex(key), "sec"))
  local kind, bin = armor.dearmor(text or "", "SECRET KEY")
  local full = kind and pgp.parseBlock(bin)
  return full ~= nil and pgp.needsPassphrase(full)
end

--- Keys whose secret part is in this ring.
function Ring:secretKeys()
  local out = {}
  for _, k in ipairs(self:keys()) do if k.hasSecret then out[#out + 1] = k end end
  return out
end

function Ring:remove(key)
  local fp = pgp.fpHex(key)
  for _, ext in ipairs({ "pub", "sec" }) do if fs.exists(self:path(fp, ext)) then fs.delete(self:path(fp, ext)) end end
  local t = self:trustTable()
  t.ownertrust[fp] = nil
  vfs.writeJSON(self.dir .. "/trust.json", t)
  self:invalidate()
end

function Ring:trustTable()
  local t = vfs.readJSON(self.dir .. "/trust.json")
  if type(t) ~= "table" then t = {} end
  t.ownertrust = t.ownertrust or {}
  return t
end

function Ring:ownerTrust(fp) return self:trustTable().ownertrust[fp] or "none" end

function Ring:setTrust(fp, level)
  if level ~= "ultimate" and level ~= "full" and level ~= "marginal" and level ~= "none" then return nil, "trust is ultimate, full, marginal or none" end
  local t = self:trustTable()
  t.ownertrust[fp] = level
  vfs.writeJSON(self.dir .. "/trust.json", t)
  return true
end

--- Validity of every key by the web of trust: { [fingerprint] = { valid, reason } }.
function Ring:validity()
  return pgp.validity(self:keys(), self:trustTable().ownertrust)
end

--- Certify `target` (a key of this ring) with your unlocked key `signer`, and store the certification.
function Ring:certify(signer, target, level)
  pgp.certify(signer, target, level)
  saveCerts(self, target)
  return true
end

--- Persist a revocation made with pgp.revoke.
function Ring:saveRevocation(key) saveCerts(self, key) end

return M
