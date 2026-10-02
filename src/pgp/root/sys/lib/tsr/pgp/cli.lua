-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The pgp command (also available as gpg): keys, signatures, encryption and the web of trust, on a ring in ~/.pgp.
--
--   pgp --gen-key ["Name <note>"] [--passphrase text] [--expire days]    create a key pair
--   pgp --list-keys | --list-secret-keys | --fingerprint [key]            show keys (validity from the web of trust)
--   pgp --export [key] [-o file]      pgp --export-secret <key> [-o file]  pgp --import file
--   pgp --sign file [--detach] [-u key]   pgp --clearsign file   pgp --verify <sigfile> [file]
--   pgp --encrypt -r <key> [-r <key>...] [--sign] file | pgp --symmetric file | pgp --decrypt file
--   pgp --certify <key> [--level 1|2]     pgp --trust <key> ultimate|full|marginal|none
--   pgp --revoke <key> [-o file]          pgp --delete-key <key>
--   pgp --send-keys <server> [key] | --recv-keys <server> <query> | --search-keys <server> <query>
-- Output goes to -o <file> or next to the input (.asc); with no input file the command reads text from the terminal until a lone '.' line.
local pgp = require("tsr.pgp")
local ring = require("tsr.pgp.ring")
local armor = require("tsr.pgp.armor")
local vfs = require("tsr.vfs")

local M = {}

local function defaultIO()
  local io = {}
  local function color(c) if term.isColor() then term.setTextColor(c) end end
  function io.say(t) print(t) end
  function io.err(t) color(colors.red) print(t) color(colors.white) end
  function io.readLine(prompt) if prompt then write(prompt) end return read() end
  function io.readPassword(prompt) if prompt then write(prompt) end return read("*") end
  function io.collect(n) require("tsr.crypto").rand.collect(n, function(i, total) write("\r" .. i .. "/" .. total .. " ") end) print() end
  return io
end

local VALUE_FLAGS = { r = true, o = true, u = true, passphrase = true, expire = true, level = true }

local function parse(args)
  local flags, words, recipients = {}, {}, {}
  local i = 1
  while i <= #args do
    local a = args[i]
    local name = a:match("^%-%-(.+)$") or a:match("^%-(%a)$")
    if name and VALUE_FLAGS[name] then
      if name == "r" then recipients[#recipients + 1] = args[i + 1] else flags[name] = args[i + 1] end
      i = i + 1
    elseif name then flags[name] = true
    else words[#words + 1] = a end
    i = i + 1
  end
  return flags, words, recipients
end

local function readInput(path, io)
  if path then
    local data = vfs.readFile(path, true)
    if not data then return nil, "cannot read " .. path end
    return data
  end
  io.say("Enter the text; finish with a line containing only a dot.")
  local lines = {}
  while true do
    local line = io.readLine()
    if line == nil or line == "." then break end
    lines[#lines + 1] = line
  end
  return table.concat(lines, "\n") .. "\n"
end

local function output(flags, defaultPath, text, io)
  local target = flags.o or defaultPath
  if target and target ~= "-" then
    vfs.writeFile(target, text, true)
    io.say("wrote " .. target)
  else
    io.say(text)
  end
end

local function who(key) return ("%s  [%s]"):format(key.uid, pgp.keyId(key)) end

local function unlockOwn(r, key, flags, io)
  local passphrase = flags.passphrase
  if not passphrase and r:needsPassphrase(key) then passphrase = io.readPassword("Passphrase for " .. who(key) .. ": ") end
  local full, err = r:unlock(key, passphrase)
  if not full then io.err(err == "passphrase" and "wrong passphrase" or tostring(err)) return nil end
  return full
end

--- The signing key: -u <key> or the only secret key.
local function signingKey(r, flags, io)
  local key, err
  if flags.u then key, err = r:find(flags.u)
  else
    local own = r:secretKeys()
    if #own == 1 then key = own[1] elseif #own == 0 then err = "you have no secret key (pgp --gen-key)" else err = "several secret keys: choose one with -u" end
  end
  if not key then io.err(tostring(err)) return nil end
  return unlockOwn(r, key, flags, io)
end

local function show(r, key, validity)
  local v = validity[pgp.fpHex(key)]
  local status = key.revoked and "REVOKED" or (pgp.expired(key) and "EXPIRED") or (v and v.valid and "valid" or "unverified")
  return ("%s  %s  [%s]  %s%s"):format(key.hasSecret and "sec" or "pub", pgp.fingerprint(key), status, key.uid, #key.certs > 0 and ("  (" .. #key.certs .. " cert.)") or "")
end

function M.run(args, io, node, keyring)
  io = io or defaultIO()
  local r = keyring or ring.open()
  local flags, words, recipients = parse(args)

  if flags["gen-key"] then
    local uid = words[1] or io.readLine("Identity (Name <note>): ")
    if not uid or uid == "" then io.err("an identity is needed") return false end
    local passphrase = flags.passphrase
    if passphrase == nil then
      passphrase = io.readPassword("Passphrase (empty for none): ")
      if passphrase ~= "" and io.readPassword("Again: ") ~= passphrase then io.err("passphrases differ") return false end
    end
    if io.collect then io.say("Collecting randomness: press 16 keys...") io.collect(16) end
    local key = pgp.generate(uid, { expires = flags.expire and tonumber(flags.expire) * 86400 or nil })
    r:addSecret(key, passphrase)
    io.say("Key created: " .. pgp.fingerprint(key))
    io.say("Give people the fingerprint over a channel you trust, so they can check the key they receive.")
    return true

  elseif flags["list-keys"] or flags["list-secret-keys"] or flags.fingerprint then
    local validity = r:validity()
    local n = 0
    for _, k in ipairs(r:keys()) do
      if (not flags["list-secret-keys"] or k.hasSecret) and (#words == 0 or r:find(words[1]) == k) then
        io.say(show(r, k, validity))
        n = n + 1
      end
    end
    if n == 0 then io.say("no keys") end
    return true

  elseif flags.export or flags["export-secret"] then
    local key, err = r:find(words[1] or "")
    if not key then io.err(tostring(err)) return false end
    if flags["export-secret"] then
      local full = unlockOwn(r, key, flags, io)
      if not full then return false end
      local pass = flags.passphrase
      output(flags, nil, pgp.exportSecret(full, pass), io)
    else
      output(flags, nil, pgp.exportPublic(key), io)
    end
    return true

  elseif flags.import then
    local text, err = readInput(words[1], io)
    if not text then io.err(err) return false end
    local imported = 0
    local rest = text
    while true do
      local kind, bin, after = armor.dearmor(rest)
      if not kind then break end
      rest = after
      if kind == "PUBLIC KEY" or kind == "SECRET KEY" then
        local key, status = pgp.parseBlock(bin)
        if not key then io.err(tostring(status)) return false end
        local stored, st = r:add(pgp.exportPublic(key))      -- merges certifications and revocations with what we know
        if kind == "SECRET KEY" and key.sealedSecret then
          vfs.writeFile(r:path(pgp.fpHex(key), "sec"), armor.armor("SECRET KEY", bin))
          r:invalidate()
          r:setTrust(pgp.fpHex(key), "ultimate")
          st = "secret key imported"
        end
        io.say(("%s: %s"):format(st, who(stored or key)))
        imported = imported + 1
      end
    end
    if imported == 0 then io.err("no key found in the input") return false end
    return true

  elseif (flags.sign and not flags.encrypt and not flags.symmetric) or flags.clearsign then
    local path = words[1]
    local data, err = readInput(path, io)
    if not data then io.err(err) return false end
    local key = signingKey(r, flags, io)
    if not key then return false end
    if flags.clearsign then
      output(flags, path and (path .. ".asc"), pgp.clearsign(data, key), io)
    else
      output(flags, path and (path .. ".sig"), pgp.armorSignature(pgp.sign(data, key)), io)
    end
    return true

  elseif flags.verify then
    local sigText, err = readInput(words[1], io)
    if not sigText then io.err(err) return false end
    local data, info
    if sigText:find("BEGIN TESSERA SIGNED MESSAGE", 1, true) then
      data, info = pgp.parseClearsigned(sigText)
      if not data then io.err(tostring(info)) return false end
    else
      local kind, bin = armor.dearmor(sigText, "SIGNATURE")
      if not kind then io.err(tostring(bin)) return false end
      info, err = pgp.parseSignature(bin)
      if not info then io.err(tostring(err)) return false end
      data, err = readInput(words[2], io)
      if not data then io.err(tostring(err)) return false end
    end
    local signer
    for _, k in ipairs(r:keys()) do if k.fp20 == info.signer then signer = k end end
    if not signer then io.err("signed by an unknown key (" .. require("tsr.crypto").toHex(info.signer):upper():sub(-16) .. "); import it first") return false end
    local good, why = pgp.verify(data, info, signer)
    if not good then io.err("BAD signature: " .. tostring(why)) return false end
    local v = r:validity()[pgp.fpHex(signer)]
    io.say("Good signature from " .. who(signer))
    if signer.revoked then io.err("WARNING: this key has been revoked") end
    if pgp.expired(signer, info.created) then io.err("WARNING: this key had expired when the signature was made") end
    io.say(v and v.valid and ("The key is valid: " .. v.reason) or "WARNING: the key is not certified by anyone you trust; check its fingerprint: " .. pgp.fingerprint(signer))
    return true

  elseif flags.encrypt or flags.symmetric then
    local path = words[1]
    local data, err = readInput(path, io)
    if not data then io.err(err) return false end
    local keys = {}
    for _, q in ipairs(recipients) do
      local k, kerr = r:find(q)
      if not k then io.err(tostring(kerr)) return false end
      keys[#keys + 1] = k
    end
    local passphrase
    if flags.symmetric then passphrase = flags.passphrase or io.readPassword("Passphrase: ") end
    if #keys == 0 and not passphrase then io.err("name a recipient with -r <key>, or use --symmetric") return false end
    local signer
    if flags.sign then signer = signingKey(r, flags, io) if not signer then return false end end
    local ok, bin = pcall(pgp.encrypt, data, keys, { signer = signer, passphrase = passphrase })
    if not ok then io.err(tostring(bin)) return false end
    output(flags, path and (path .. ".asc"), pgp.armorMessage(bin), io)
    return true

  elseif flags.decrypt then
    local path = words[1]
    local text, err = readInput(path, io)
    if not text then io.err(err) return false end
    local kind, bin = armor.dearmor(text, "MESSAGE")
    if not kind then io.err(tostring(bin)) return false end
    local unlocked = {}
    for _, k in ipairs(r:secretKeys()) do
      local full = r:unlock(k, r:needsPassphrase(k) and flags.passphrase or nil)
      if not full and r:needsPassphrase(k) and not flags.passphrase then
        -- ask only when the message names this key
        full = unlockOwn(r, k, flags, io)
      end
      if full then unlocked[#unlocked + 1] = full end
    end
    local plain, info = pgp.decrypt(bin, unlocked, { passphrase = flags.passphrase })
    if not plain and not flags.passphrase then
      local pass = io.readPassword("Passphrase (if this message used one): ")
      if pass ~= "" then plain, info = pgp.decrypt(bin, unlocked, { passphrase = pass }) end
    end
    if not plain then io.err(tostring(info)) return false end
    if info.signature then
      local signer
      for _, k in ipairs(r:keys()) do if k.fp20 == info.signature.signer then signer = k end end
      if signer then
        local good, why = pgp.verify(info.signedData, info.signature, signer)
        io.say(good and ("Good signature from " .. who(signer)) or ("BAD signature: " .. tostring(why)))
      else
        io.say("The message is signed by a key you do not have.")
      end
    end
    output(flags, path and (path:match("^(.*)%.asc$") or (path .. ".out")), plain, io)
    return true

  elseif flags.certify then
    local key, err = r:find(words[1] or "")
    if not key then io.err(tostring(err)) return false end
    io.say("Key: " .. pgp.fingerprint(key) .. "\nIdentity: " .. key.uid)
    io.say("Only certify a key after checking the fingerprint with its owner over a channel you trust.")
    local signer = signingKey(r, flags, io)
    if not signer then return false end
    r:certify(signer, key, tonumber(flags.level) or 1)
    io.say("Certified. Share the updated key (pgp --export / --send-keys) so others can see it.")
    return true

  elseif flags.trust then
    local key, err = r:find(words[1] or "")
    if not key then io.err(tostring(err)) return false end
    local ok, terr = r:setTrust(pgp.fpHex(key), words[2] or "")
    if not ok then io.err(tostring(terr)) return false end
    io.say(who(key) .. ": owner trust " .. words[2])
    return true

  elseif flags.revoke then
    local key, err = r:find(words[1] or "")
    if not key then io.err(tostring(err)) return false end
    local full = unlockOwn(r, key, flags, io)
    if not full then return false end
    pgp.revoke(full, 1)
    key.revoked, key.revocation = true, full.revocation
    r:saveRevocation(key)
    io.say("Revoked. Publish the key again so others learn about it.")
    output(flags, nil, pgp.exportPublic(key), io)
    return true

  elseif flags["delete-key"] then
    local key, err = r:find(words[1] or "")
    if not key then io.err(tostring(err)) return false end
    r:remove(key)
    io.say("deleted " .. who(key))
    return true

  elseif flags["send-keys"] or flags["recv-keys"] or flags["search-keys"] then
    local ks = require("tsr.pgp.keyserver")
    node = node or require("tsr.net").default()
    local server = words[1]
    if not server then io.err("name the key server computer") return false end
    if flags["send-keys"] then
      local key, err = r:find(words[2] or "")
      if not key then io.err(tostring(err)) return false end
      local res, e = ks.send(node, server, key)
      if not res then io.err(tostring(e)) return false end
      io.say(("sent %s (%s)"):format(res.uid, res.status))
    elseif flags["recv-keys"] then
      local key, st = ks.receive(node, server, words[2] or "", r)
      if not key then io.err(tostring(st)) return false end
      io.say(("%s: %s"):format(st, who(key)))
    else
      local list, e = ks.search(node, server, words[2] or "")
      if not list then io.err(tostring(e)) return false end
      for _, k in ipairs(list) do io.say(k.fingerprint .. "  " .. k.uid .. (k.revoked and "  [REVOKED]" or "")) end
    end
    return true
  end

  io.err("usage: pgp --gen-key | --list-keys | --export | --import | --sign | --clearsign | --verify | --encrypt -r <key> | --symmetric | --decrypt | --certify | --trust | --revoke | --send-keys | --recv-keys")
  return false
end

function M.main(args) return M.run(args) end

return M
