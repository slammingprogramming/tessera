-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Encrypted volumes ("vaults"), like BitLocker, FileVault or LUKS+ext4 on a game computer: a folder that holds only ciphertext, and a
-- mount point where, after the passphrase, you see ordinary files. Close it (or reboot) and nothing readable is left on disk.
--
-- On disk (folder <dir>):
--   vault.json   header: PBKDF2-SHA256 salt and iteration count, the 64-byte master key sealed (ChaCha20-Poly1305) under the key derived
--                from the passphrase, and optionally a second copy sealed under a random RECOVERY KEY shown once at creation
--   index.enc    the file tree (names, directories, which data file holds what), encrypted: names and structure are hidden
--   d/<id>       one file per vault file, 4 KB chunks each sealed with its own nonce; the chunk's AAD binds it to the file id, its position
--                and whether it is the last chunk, so chunks cannot be swapped between files, reordered or cut off
-- A changed file is written under a NEW id first and only then does the index point to it: a crash leaves the old content or the new one,
-- never half of each (orphaned data files are removed at the next open). Visible to an attacker with the disk: that a vault exists, how many
-- files it holds and their sizes. The decrypted tree lives in memory while mounted, so the vault should stay small (a few hundred KB).
--
--   local v = vault.create("/safe", "passphrase")      -> vault, recoveryKey
--   local v = vault.open("/safe", "passphrase")        -- or the recovery key
--   v:mount("/secret")   ...   v:unmount()
local crypto = require("tsr.crypto")
local vfs = require("tsr.vfs")

local M = {}

M.ITERATIONS = 4000
M.CHUNK = 4096
M.CAPACITY = 2 * 1024 * 1024

local floor = math.floor
local ZERO12 = string.rep("\0", 12)

local function u64(n)
  local b = {}
  for i = 8, 1, -1 do b[i] = n % 256 n = floor(n / 256) end
  return string.char(table.unpack(b))
end

local function randomId() return crypto.toHex(crypto.rand.bytes(12)) end

---------------------------------------------------------------------------------------------------------------------
-- Sealing
---------------------------------------------------------------------------------------------------------------------

local function sealRandom(key, plain, aad)
  local nonce = crypto.rand.bytes(12)
  return nonce .. crypto.chacha.seal(key, nonce, plain, aad)
end

local function openRandom(key, sealed, aad)
  if #sealed < 12 + 16 then return nil end
  return crypto.chacha.open(key, sealed:sub(1, 12), sealed:sub(13), aad)
end

local function fileKey(master, id) return crypto.kdf.hkdf(master:sub(1, 32), nil, "tessera-vault-file:" .. id, 32) end

local function chunkNonce(i) return "\0\0\0\0" .. u64(i) end

--- Encrypt file content into the stored form (a string of sealed chunks).
local function encryptFile(master, id, plain)
  local key = fileKey(master, id)
  local out = {}
  local chunks = math.max(1, math.ceil(#plain / M.CHUNK))
  for i = 1, chunks do
    local piece = plain:sub((i - 1) * M.CHUNK + 1, i * M.CHUNK)
    out[i] = crypto.chacha.seal(key, chunkNonce(i), piece, id .. (i == chunks and "F" or "M") .. u64(i))
  end
  return table.concat(out)
end

local function decryptFile(master, id, stored)
  local key = fileKey(master, id)
  local unit = M.CHUNK + 16
  local chunks = math.max(1, math.ceil(#stored / unit))
  local out = {}
  for i = 1, chunks do
    local piece = stored:sub((i - 1) * unit + 1, i * unit)
    local plain = crypto.chacha.open(key, chunkNonce(i), piece, id .. (i == chunks and "F" or "M") .. u64(i))
    if not plain then return nil end
    out[i] = plain
  end
  return table.concat(out)
end

---------------------------------------------------------------------------------------------------------------------
-- Header
---------------------------------------------------------------------------------------------------------------------

local function kek(secret, header)
  return crypto.kdf.pbkdf2(secret, crypto.fromHex(header.salt), header.iter, 32)
end

local function writeHeader(dir, header) return vfs.writeJSON(dir .. "/vault.json", header) end

--- Create a new vault in the (empty or new) folder `dir`. opts: iterations, recovery (default true). Returns the vault, and the recovery key text.
function M.create(dir, passphrase, opts)
  opts = opts or {}
  if type(passphrase) ~= "string" or #passphrase < 6 then return nil, "the passphrase must have at least 6 characters" end
  if fs.exists(dir .. "/vault.json") then return nil, dir .. " already holds a vault" end
  if fs.exists(dir) and not fs.isDir(dir) then return nil, dir .. " is a file" end
  local master = crypto.rand.bytes(64)
  local header = { format = 1, salt = crypto.toHex(crypto.rand.bytes(16)), iter = opts.iterations or M.ITERATIONS }
  header.wrapped = crypto.toHex(sealRandom(kek(passphrase, header), master, "tessera-vault-master"))
  local recoveryText
  if opts.recovery ~= false then
    local recovery = crypto.rand.bytes(32)
    recoveryText = crypto.base64Encode(recovery)
    header.recovery = crypto.toHex(sealRandom(recovery, master, "tessera-vault-recovery"))
  end
  fs.makeDir(dir)
  fs.makeDir(dir .. "/d")
  writeHeader(dir, header)
  local v = setmetatable({ dir = dir, master = master, header = header, files = {}, dirs = {}, version = 0 }, M.Vault)
  v:saveIndex()
  return v, recoveryText
end

--- Open an existing vault with its passphrase or recovery key. Returns the vault or nil + reason.
function M.open(dir, secret)
  local header = vfs.readJSON(dir .. "/vault.json")
  if type(header) ~= "table" or header.format ~= 1 then return nil, "no vault in " .. tostring(dir) end
  local master = openRandom(kek(secret, header), crypto.fromHex(header.wrapped), "tessera-vault-master")
  if not master and header.recovery then
    local raw = crypto.base64Decode(secret)
    if raw and #raw == 32 then master = openRandom(raw, crypto.fromHex(header.recovery), "tessera-vault-recovery") end
  end
  if not master then return nil, "wrong passphrase" end
  local v = setmetatable({ dir = dir, master = master, header = header, files = {}, dirs = {}, version = 0 }, M.Vault)
  local ok, err = v:loadIndex()
  if not ok then return nil, err end
  return v
end

---------------------------------------------------------------------------------------------------------------------
-- The vault object
---------------------------------------------------------------------------------------------------------------------

local Vault = {}
Vault.__index = Vault
M.Vault = Vault

function Vault:indexKey() return self.master:sub(33, 64) end

function Vault:saveIndex()
  self.version = self.version + 1
  local doc = textutils.serialize({ version = self.version, files = self.files, dirs = self.dirs })
  local sealed = sealRandom(self:indexKey(), doc, "tessera-vault-index")
  return vfs.writeFile(self.dir .. "/index.enc", sealed, true)
end

function Vault:loadIndex()
  local sealed = vfs.readFile(self.dir .. "/index.enc", true)
  if not sealed then return nil, "the vault's index is missing" end
  local doc = openRandom(self:indexKey(), sealed, "tessera-vault-index")
  if not doc then return nil, "the vault's index is damaged or was tampered with" end
  local t = textutils.unserialize(doc)
  if type(t) ~= "table" then return nil, "the vault's index is unreadable" end
  self.files, self.dirs, self.version = t.files or {}, t.dirs or {}, t.version or 0
  return true
end

--- Remove data files that the index does not know (left by a crash between writing data and updating the index).
function Vault:collectGarbage()
  local known = {}
  for _, f in pairs(self.files) do known[f.id] = true end
  local removed = 0
  if fs.isDir(self.dir .. "/d") then
    for _, name in ipairs(fs.list(self.dir .. "/d")) do
      if not known[name] then fs.delete(self.dir .. "/d/" .. name) removed = removed + 1 end
    end
  end
  return removed
end

--- Read one file's plaintext (nil + reason when it is missing or fails authentication).
function Vault:readPlain(path)
  local entry = self.files[path]
  if not entry then return nil, "no such file" end
  local stored = vfs.readFile(self.dir .. "/d/" .. entry.id, true)
  if not stored then return nil, "data file missing" end
  local plain = decryptFile(self.master, entry.id, stored)
  if not plain then return nil, "the file failed authentication (damaged or tampered)" end
  return plain
end

--- Store a file's plaintext under a fresh id, point the index at it, remove the old data file.
function Vault:writePlain(path, plain)
  local id = randomId()
  local ok, err = vfs.writeFile(self.dir .. "/d/" .. id, encryptFile(self.master, id, plain), true)
  if not ok then return nil, err end
  local old = self.files[path]
  self.files[path] = { id = id, size = #plain }
  self:saveIndex()
  if old and fs.exists(self.dir .. "/d/" .. old.id) then fs.delete(self.dir .. "/d/" .. old.id) end
  return true
end

function Vault:removeFile(path)
  local old = self.files[path]
  self.files[path] = nil
  self:saveIndex()
  if old and fs.exists(self.dir .. "/d/" .. old.id) then fs.delete(self.dir .. "/d/" .. old.id) end
end

--- Change the passphrase (the master key stays, so the data files need no re-encryption). Returns true or nil + reason.
function Vault:changePassphrase(newPassphrase)
  if type(newPassphrase) ~= "string" or #newPassphrase < 6 then return nil, "the passphrase must have at least 6 characters" end
  local header = self.header
  header.salt = crypto.toHex(crypto.rand.bytes(16))
  header.wrapped = crypto.toHex(sealRandom(kek(newPassphrase, header), self.master, "tessera-vault-master"))
  return writeHeader(self.dir, header)
end

--- The decrypted file system as a VFS provider: a RAM file system that writes every change through to the encrypted store.
function Vault:provider(capacity)
  local ram = vfs.ramfs(capacity or M.CAPACITY)
  local self_ = self
  -- load everything
  local dirs = {}
  for path in pairs(self.dirs) do dirs[#dirs + 1] = path end
  table.sort(dirs, function(a, b) return #a < #b end)
  for _, d in ipairs(dirs) do ram.makeDir(d) end
  local bad = {}
  for path, entry in pairs(self.files) do
    local plain, err = self:readPlain(path)
    if plain then
      local parent = path:match("^(.*)/[^/]+$")
      if parent and parent ~= "" then ram.makeDir(parent) end
      local h = ram.open(path, "wb")
      h.write(plain)
      h.close()
    else
      bad[#bad + 1] = path .. ": " .. tostring(err)
    end
  end
  self.problems = bad

  local P = setmetatable({}, { __index = ram })

  local function persist(path)
    if not ram.exists(path) or ram.isDir(path) then return end
    local h = ram.open(path, "rb")
    local plain = h.readAll() or ""
    h.close()
    local ok, err = self_:writePlain(path, plain)
    if not ok then error("vault: cannot save " .. path .. ": " .. tostring(err), 0) end
  end

  function P.open(path, mode)
    local h, err = ram.open(path, mode)
    if not h then return nil, err end
    local m = mode:sub(1, 1)
    if m == "w" or m == "a" then
      local close, flush = h.close, h.flush
      local function sync()
        local parent = path:match("^(.*)/[^/]+$")
        while parent and parent ~= "" and not self_.dirs[parent] do
          self_.dirs[parent] = true
          parent = parent:match("^(.*)/[^/]+$")
        end
        persist(path)
      end
      function h.close() close() sync() end
      if flush then function h.flush() flush() end end
    end
    return h
  end

  function P.makeDir(path)
    ram.makeDir(path)
    local p = path
    while p and p ~= "" do self_.dirs[p] = true p = p:match("^(.*)/[^/]+$") end
    self_:saveIndex()
  end

  function P.delete(path)
    local prefix = path .. "/"
    local doomed = {}
    for file in pairs(self_.files) do if file == path or file:sub(1, #prefix) == prefix then doomed[#doomed + 1] = file end end
    ram.delete(path)
    for _, file in ipairs(doomed) do self_.files[file] = nil end
    local olds = {}
    for _, file in ipairs(doomed) do olds[#olds + 1] = file end
    for d in pairs(self_.dirs) do if d == path or d:sub(1, #prefix) == prefix then self_.dirs[d] = nil end end
    self_:saveIndex()
    self_:collectGarbage()
  end

  function P.move(a, b)
    ram.move(a, b)
    local moved, prefix = {}, a .. "/"
    for file, entry in pairs(self_.files) do
      if file == a then moved[b] = entry self_.files[file] = nil
      elseif file:sub(1, #prefix) == prefix then moved[b .. file:sub(#a + 1)] = entry self_.files[file] = nil end
    end
    for file, entry in pairs(moved) do self_.files[file] = entry end
    local dmoved = {}
    for d in pairs(self_.dirs) do
      if d == a then dmoved[b] = true self_.dirs[d] = nil
      elseif d:sub(1, #prefix) == prefix then dmoved[b .. d:sub(#a + 1)] = true self_.dirs[d] = nil end
    end
    for d in pairs(dmoved) do self_.dirs[d] = true end
    local parent = b:match("^(.*)/[^/]+$")
    while parent and parent ~= "" do self_.dirs[parent] = true parent = parent:match("^(.*)/[^/]+$") end
    self_:saveIndex()
  end

  function P.getFreeSpace() return ram.getFreeSpace() end
  return P
end

--- Mount the decrypted file system at `path`.
function Vault:mount(path, capacity)
  self:collectGarbage()
  self.mountPoint = vfs.normalize(path)
  vfs.mount(self.mountPoint, self:provider(capacity))
  M.mounted[self.mountPoint] = self
  return true
end

function Vault:unmount()
  if self.mountPoint then
    vfs.unmount(self.mountPoint)
    M.mounted[self.mountPoint] = nil
    self.mountPoint = nil
  end
  self.master = string.rep("\0", 64)         -- forget the key (the table is dropped with the vault object)
  return true
end

--- Vaults that are mounted right now: { [mount point] = vault }.
M.mounted = {}

return M
