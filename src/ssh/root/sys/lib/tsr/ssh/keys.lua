-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Keys for the in-game secure shell: host keys, user keys (optionally protected by a passphrase), known_hosts and authorized_keys.
--
-- This is an in-game system: "hosts" are computers on the same Minecraft world's wired/wireless network, identified by their computer
-- id and name. Nothing here talks to the real Internet.
--
-- Formats (deliberately like OpenSSH's, so they are easy to read and edit):
--   public key line     tsr-ed25519 <base64 of the 32 byte key> [comment]
--   authorized_keys     one public key line per line ('#' comments)
--   known_hosts         <id:12>,<hostname> tsr-ed25519 <base64>
--   private key file    JSON; with a passphrase the seed is sealed with ChaCha20-Poly1305 under a PBKDF2-SHA256 key
local crypto = require("tsr.crypto")
local vfs = require("tsr.vfs")

local M = {}

M.ALG = "tsr-ed25519"
M.HOST_KEY = "/etc/tsr/ssh/host_ed25519"
M.KDF_ITERATIONS = 2000

---------------------------------------------------------------------------------------------------------------------
-- Public key lines and fingerprints
---------------------------------------------------------------------------------------------------------------------

--- "tsr-ed25519 <base64> comment" for a 32-byte public key.
function M.encode(public, comment)
  local line = M.ALG .. " " .. crypto.base64Encode(public)
  if comment and comment ~= "" then line = line .. " " .. comment end
  return line
end

--- Parse a public key line. Returns public (32 bytes), comment or nil + reason.
function M.decode(line)
  local alg, b64, comment = tostring(line):match("^%s*(%S+)%s+(%S+)%s*(.-)%s*$")
  if alg ~= M.ALG then return nil, "unsupported key type " .. tostring(alg) end
  local public = crypto.base64Decode(b64)
  if not public or #public ~= 32 then return nil, "malformed key" end
  return public, comment
end

function M.fingerprint(public) return crypto.fingerprint(public) end

local ART = " .o+=*BOX@%&#/^SE"

--- OpenSSH-style "randomart" picture of a key (the drunken bishop): easier to compare by eye than a fingerprint.
--- Returns a list of 11 lines (a box 17 wide).
function M.randomart(public, title)
  local digest = crypto.kdf.sha256(public)
  local W, H = 17, 9
  local field = {}
  for y = 1, H do field[y] = {} for x = 1, W do field[y][x] = 0 end end
  local x, y = 9, 5
  for i = 1, #digest do
    local byte = digest:byte(i)
    for _ = 1, 4 do
      x = math.max(1, math.min(W, x + ((byte % 2 == 1) and 1 or -1)))
      y = math.max(1, math.min(H, y + ((math.floor(byte / 2) % 2 == 1) and 1 or -1)))
      field[y][x] = field[y][x] + 1
      byte = math.floor(byte / 4)
    end
  end
  local last = { x, y }
  local top = "+" .. (("[" .. (title or M.ALG) .. "]"):sub(1, W) .. string.rep("-", W)):sub(1, W) .. "+"
  local lines = { top }
  for row = 1, H do
    local chars = {}
    for col = 1, W do
      local n = field[row][col]
      local c
      if col == 9 and row == 5 then c = "S"
      elseif col == last[1] and row == last[2] then c = "E"
      else c = ART:sub(math.min(n, 14) + 1, math.min(n, 14) + 1) end
      chars[col] = c
    end
    lines[#lines + 1] = "|" .. table.concat(chars) .. "|"
  end
  lines[#lines + 1] = "+" .. string.rep("-", W) .. "+"
  return lines
end

---------------------------------------------------------------------------------------------------------------------
-- Private key files
---------------------------------------------------------------------------------------------------------------------

--- Write a key ({ secret, public }) to `path` (and the public line to path .. ".pub"). A non-empty passphrase seals the secret.
function M.save(path, key, passphrase, comment)
  local doc = { format = 1, alg = M.ALG, comment = comment or "", public = crypto.toHex(key.public) }
  if passphrase and passphrase ~= "" then
    local salt = crypto.rand.bytes(16)
    local k = crypto.kdf.pbkdf2(passphrase, salt, M.KDF_ITERATIONS, 32)
    doc.kdf = { name = "pbkdf2-sha256", salt = crypto.toHex(salt), iter = M.KDF_ITERATIONS }
    doc.sealed = crypto.toHex(crypto.chacha.seal(k, string.rep("\0", 12), key.secret, doc.public))
  else
    doc.secret = crypto.toHex(key.secret)
  end
  vfs.writeJSON(path, doc)
  vfs.writeFile(path .. ".pub", M.encode(key.public, comment) .. "\n")
  return true
end

--- Does the private key file need a passphrase?
function M.needsPassphrase(path)
  local doc = vfs.readJSON(path)
  return doc ~= nil and doc.sealed ~= nil
end

--- Load a private key file. Returns { secret, public, comment } or nil + reason ("passphrase" when one is needed or wrong).
function M.load(path, passphrase)
  local doc = vfs.readJSON(path)
  if type(doc) ~= "table" or doc.alg ~= M.ALG then return nil, "no key at " .. path end
  local public = crypto.fromHex(doc.public or "")
  local secret
  if doc.secret then
    secret = crypto.fromHex(doc.secret)
  else
    if not passphrase then return nil, "passphrase" end
    local salt = crypto.fromHex(doc.kdf and doc.kdf.salt or "")
    local k = crypto.kdf.pbkdf2(passphrase, salt, tonumber(doc.kdf and doc.kdf.iter) or M.KDF_ITERATIONS, 32)
    secret = crypto.chacha.open(k, string.rep("\0", 12), crypto.fromHex(doc.sealed or ""), doc.public)
    if not secret then return nil, "passphrase" end
  end
  if #secret ~= 32 or crypto.ed25519.publicKey(secret) ~= public then return nil, "the key file is damaged" end
  return { secret = secret, public = public, comment = doc.comment }
end

--- Create a key pair and store it. Returns the key.
function M.generate(path, opts)
  opts = opts or {}
  local key = crypto.signingKey()
  M.save(path, key, opts.passphrase, opts.comment)
  return key
end

--- The host key of this computer, created on first use.
function M.hostKey()
  local key = M.load(M.HOST_KEY)
  if key then return key end
  return M.generate(M.HOST_KEY, { comment = "host " .. tostring(os.getComputerID()) })
end

---------------------------------------------------------------------------------------------------------------------
-- known_hosts
---------------------------------------------------------------------------------------------------------------------

local function lines(path)
  local text = vfs.readFile(path)
  local out = {}
  if text then for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do out[#out + 1] = line end end
  return out
end

local function writeLines(path, list)
  vfs.writeFile(path, table.concat(list, "\n") .. (#list > 0 and "\n" or ""))
end

local function names(id, hostname)
  local out = { "id:" .. tostring(id) }
  if hostname and hostname ~= "" then out[#out + 1] = hostname end
  return out
end

--- Compare a host's key with the file. Returns "known", "new" or "changed" (and the stored public key when changed).
function M.checkHost(path, id, hostname, public)
  local want = {}
  for _, n in ipairs(names(id, hostname)) do want[n] = true end
  local seen
  for _, line in ipairs(lines(path)) do
    if line:match("%S") and not line:match("^%s*#") then
      local who, rest = line:match("^(%S+)%s+(.*)$")
      local pub = rest and M.decode(rest)
      if pub then
        local hit = false
        for n in who:gmatch("[^,]+") do if want[n] then hit = true end end
        if hit then
          if pub == public then return "known" end
          seen = pub
        end
      end
    end
  end
  if seen then return "changed", seen end
  return "new"
end

function M.addHost(path, id, hostname, public)
  local list = lines(path)
  list[#list + 1] = table.concat(names(id, hostname), ",") .. " " .. M.encode(public)
  writeLines(path, list)
end

--- Forget a host (by id number, id:N or hostname). Returns how many entries were removed.
function M.removeHost(path, who)
  if tonumber(who) then who = "id:" .. who end
  local keep, removed = {}, 0
  for _, line in ipairs(lines(path)) do
    local first = line:match("^(%S+)")
    local hit = false
    if first and not first:match("^#") then for n in first:gmatch("[^,]+") do if n == who then hit = true end end end
    if hit then removed = removed + 1 else keep[#keep + 1] = line end
  end
  writeLines(path, keep)
  return removed
end

---------------------------------------------------------------------------------------------------------------------
-- authorized_keys
---------------------------------------------------------------------------------------------------------------------

--- Public keys allowed to log in: list of { public, comment }.
function M.authorized(path)
  local out = {}
  for _, line in ipairs(lines(path)) do
    if line:match("%S") and not line:match("^%s*#") then
      local pub, comment = M.decode(line)
      if pub then out[#out + 1] = { public = pub, comment = comment } end
    end
  end
  return out
end

function M.isAuthorized(path, public)
  for _, k in ipairs(M.authorized(path)) do if k.public == public then return true, k end end
  return false
end

--- Add a key to an authorized_keys file (no duplicates).
function M.addAuthorized(path, public, comment)
  if M.isAuthorized(path, public) then return false end
  local list = lines(path)
  list[#list + 1] = M.encode(public, comment)
  writeLines(path, list)
  return true
end

return M
