-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Definitions: the lists the scanner knows besides its built-in rules.
--   hashes   SHA-256 of whole files that are known to be bad          { ["<sha256>"] = "Name" }
--   patterns extra signatures (Lua patterns or plain text) with a score { { id, name, pattern, plain, score } }
--   allow    SHA-256 of files that are known to be good (never reported) { ["<sha256>"] = "why" }
-- They come in two places: the file that ships with the package (/usr/share/av/defs.json), and an updated file (/var/lib/tsr/av/defs.json) that anyone can publish but
-- that is only accepted when its signature is valid for a key the administrator trusts (av trust add <key>). The version number must go up, so an old list cannot be
-- played back. Whoever publishes lists (a server operator, a community) makes a key with `av defs keygen`, signs with `av defs sign` and shares the public key.
local hash = require("tsr.hash")
local vfs = require("tsr.vfs")
local crypto = require("tsr.crypto")

local M = {}

M.BUILTIN = "/usr/share/av/defs.json"
M.UPDATED = "/var/lib/tsr/av/defs.json"
M.STATE = "/var/lib/tsr/av/defs.state"
M.TRUST = "/etc/tsr/av/trust.json"
M.CONTEXT = "av-definitions"
M.MAX_SIZE = 200000

local function readJSON(path)
  local text = vfs.readFile(path)
  if not text then return nil end
  local ok, value = pcall(textutils.unserializeJSON, text)
  if ok and type(value) == "table" then return value end
  return nil
end

--- Trusted publisher keys: { { name, key (base64 of the 32-byte public key) } }.
function M.keys()
  local t = readJSON(M.TRUST)
  return t and t.keys or {}
end

local function saveKeys(keys)
  vfs.mkdirp("/etc/tsr/av")
  return vfs.writeFile(M.TRUST, textutils.serializeJSON({ keys = keys }))
end

function M.trust(name, keyB64)
  local raw = crypto.base64Decode(keyB64 or "")
  if not raw or #raw ~= 32 then return nil, "a public key is 44 characters of base64" end
  local keys = M.keys()
  for _, k in ipairs(keys) do if k.key == keyB64 then return nil, "that key is trusted already" end end
  keys[#keys + 1] = { name = name or "publisher", key = keyB64 }
  return saveKeys(keys)
end

function M.untrust(nameOrKey)
  local keys, out, removed = M.keys(), {}, false
  for _, k in ipairs(keys) do
    if k.name == nameOrKey or k.key == nameOrKey then removed = true else out[#out + 1] = k end
  end
  if not removed then return nil, "no such key" end
  return saveKeys(out)
end

--- Make a publisher key pair. Returns the secret seed (keep it private) and the public key (base64).
function M.keygen()
  local pair = crypto.signingKey(crypto.rand.bytes(32))
  return pair.secret, crypto.base64Encode(pair.public)
end

--- Signature (base64) of a definitions text under a 32-byte secret seed.
function M.sign(text, secret)
  return crypto.base64Encode(crypto.signData(secret, text, M.CONTEXT))
end

local function normalize(d)
  d.hashes = type(d.hashes) == "table" and d.hashes or {}
  d.patterns = type(d.patterns) == "table" and d.patterns or {}
  d.allow = type(d.allow) == "table" and d.allow or {}
  d.version = tonumber(d.version) or 0
  return d
end

local function checkShape(d)
  if type(d) ~= "table" then return false, "not a definitions file" end
  for k, v in pairs(d.hashes or {}) do
    if type(k) ~= "string" or #k ~= 64 or type(v) ~= "string" then return false, "bad hash entry" end
  end
  for _, p in ipairs(d.patterns or {}) do
    if type(p.id) ~= "string" or type(p.pattern) ~= "string" or (p.score ~= nil and type(p.score) ~= "number") then return false, "bad pattern entry" end
    if not p.plain then
      local ok = pcall(string.find, "", p.pattern)
      if not ok then return false, "pattern " .. p.id .. " is not valid" end
    end
  end
  return true
end

--- The version and publisher of the updated definitions that are installed (nil without any).
function M.state()
  return readJSON(M.STATE)
end

--- Everything the scanner uses: the built-in lists plus the updated ones when they are intact. Returns the merged table and a description of where it came from.
function M.load()
  local merged = normalize({ hashes = {}, patterns = {}, allow = {} })
  local built = readJSON(M.BUILTIN)
  local sources = {}
  if built then
    normalize(built)
    for k, v in pairs(built.hashes) do merged.hashes[k] = v end
    for _, p in ipairs(built.patterns) do merged.patterns[#merged.patterns + 1] = p end
    for k, v in pairs(built.allow) do merged.allow[k] = v end
    merged.version = built.version
    sources[#sources + 1] = "built-in v" .. built.version
  end
  local text = vfs.readFile(M.UPDATED)
  local state = M.state()
  if text and state and state.sha256 == hash.sha256(text) then
    local ok, d = pcall(textutils.unserializeJSON, text)
    if ok and type(d) == "table" and checkShape(d) then
      normalize(d)
      for k, v in pairs(d.hashes) do merged.hashes[k] = v end
      for _, p in ipairs(d.patterns) do merged.patterns[#merged.patterns + 1] = p end
      for k, v in pairs(d.allow) do merged.allow[k] = v end
      merged.version = math.max(merged.version, d.version)
      sources[#sources + 1] = ("updated v%d (%s)"):format(d.version, tostring(state.publisher))
    end
  end
  merged.sources = table.concat(sources, ", ")
  return merged
end

--- Accept new definitions. text: the JSON file, sig: base64 signature. Returns the version, or nil + reason.
function M.install(text, sig, opts)
  opts = opts or {}
  if #text > M.MAX_SIZE then return nil, "the definitions file is too large" end
  local rawSig = crypto.base64Decode((((sig or ""):gsub("%s+", ""))))
  if not rawSig or #rawSig ~= 64 then return nil, "the signature is missing or damaged" end
  local publisher
  for _, k in ipairs(M.keys()) do
    local pub = crypto.base64Decode(k.key)
    if pub and crypto.verifyData(pub, text, rawSig, M.CONTEXT) then publisher = k.name break end
  end
  if not publisher then return nil, "the signature is not from a publisher you trust (av trust add <name> <key>)" end
  local ok, d = pcall(textutils.unserializeJSON, text)
  if not ok or type(d) ~= "table" then return nil, "the file is not valid JSON" end
  local shapeOk, why = checkShape(d)
  if not shapeOk then return nil, why end
  local version = tonumber(d.version)
  if not version then return nil, "the file has no version" end
  local now = opts.now or (os.epoch and os.epoch("utc") / 1000) or 0
  if d.issued and tonumber(d.issued) and now > 0 and tonumber(d.issued) > now + 86400 * 2 then return nil, "the file claims to be from the future" end
  local current = M.state()
  local have = current and current.version or 0
  if version <= have and not opts.force then return nil, ("these definitions (v%d) are not newer than the installed ones (v%d)"):format(version, have) end
  local builtin = readJSON(M.BUILTIN)
  if builtin and tonumber(builtin.version) and version <= tonumber(builtin.version) and not opts.force then
    return nil, ("these definitions (v%d) are older than the ones that came with the package (v%d)"):format(version, tonumber(builtin.version))
  end
  vfs.mkdirp("/var/lib/tsr/av")
  local w1, e1 = vfs.writeFile(M.UPDATED, text)
  if not w1 then return nil, tostring(e1) end
  vfs.writeFile(M.UPDATED .. ".sig", sig)
  vfs.writeFile(M.STATE, textutils.serializeJSON({ version = version, sha256 = hash.sha256(text), publisher = publisher, installed = now }))
  return version, publisher
end

--- Fetch definitions from a place: a path, or an http(s) URL (the signature is at <source>.sig). Returns text, sig.
function M.fetch(source, opts)
  opts = opts or {}
  if source:match("^https?://") then
    local getter = opts.get
    if not getter then
      local okC, client = pcall(require, "tsr.inet.http.client")
      if okC and (opts.stack or not http) then
        getter = function(url)
          local r, err = client.get(url, { stack = opts.stack })
          if not r then return nil, err end
          if r.status ~= 200 then return nil, "HTTP " .. r.status end
          return r.body
        end
      elseif http then
        getter = function(url)
          local h, err = http.get(url, nil, true)
          if not h then return nil, tostring(err) end
          local body = h.readAll()
          h.close()
          return body
        end
      end
    end
    if not getter then return nil, "no way to reach the web from here" end
    local text, err = getter(source)
    if not text then return nil, "cannot fetch " .. source .. ": " .. tostring(err) end
    local sig, serr = getter(source .. ".sig")
    if not sig then return nil, "cannot fetch the signature: " .. tostring(serr) end
    return text, sig
  end
  local path = vfs.normalize(source)
  local text = vfs.readFile(path)
  if not text then return nil, "cannot read " .. source end
  local sig = vfs.readFile(path .. ".sig")
  if not sig then return nil, "no signature file " .. source .. ".sig" end
  return text, sig
end

--- Fetch and install from a source.
function M.update(source, opts)
  local text, sig = M.fetch(source, opts)
  if not text then return nil, sig end
  return M.install(text, sig, opts)
end

return M
