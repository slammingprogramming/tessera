-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The tlsctl command: run your own certificate authority and manage trust.
--   tlsctl ca init <name>                          make a CA here (key in /etc/tsr/inet/tls/ca.key: keep it safe) and trust it on this computer
--   tlsctl ca show                                 print the CA certificate: copy it to every computer that should trust this CA (`tlsctl trust add <file>`)
--   tlsctl cert issue <name> [other names...] [--days n]    a key and a certificate for a server, signed by the CA: <name>.crt and <name>.key
--   tlsctl cert selfsign <name>                    a certificate that vouches only for itself (clients pin it the first time they see it)
--   tlsctl cert show <name|file>                   details of a certificate
--   tlsctl trust add <file> | list | remove <name>        which CAs this computer believes
--   tlsctl known [forget <host>]                   the server certificates pinned on first use
--   tlsctl revoke <serial|fingerprint>             refuse a certificate from now on
local tls = require("tsr.inet.tls")
local cert = require("tsr.inet.tls.cert")
local crypto = require("tsr.crypto")
local vfs = require("tsr.vfs")

local M = {}

local function defaultCtx(ctx)
  ctx = ctx or {}
  ctx.say = ctx.say or print
  ctx.err = ctx.err or print
  ctx.dir = ctx.dir or tls.DIR
  return ctx
end

local function isAdmin(ctx)
  local okAuth, auth = pcall(require, "tsr.auth")
  if not okAuth or not auth.hasUsers() then return true end
  local me = auth.current()
  if me == nil or auth.can(me, "auth.manage") then return true end
  ctx.err("only administrators can manage certificates")
  return false
end

local function fmtTime(ms) return os.date and os.date("%Y-%m-%d", math.floor(ms / 1000)) or tostring(ms) end

local function describe(c, ctx)
  ctx.say("subject:     " .. c.subject .. ((c.names and #c.names > 0) and ("   also: " .. table.concat(c.names, ", ")) or ""))
  ctx.say("issuer:      " .. c.issuer .. (cert.isSelfSigned(c) and "  (self-signed)" or ""))
  ctx.say("valid:       " .. fmtTime(c.from) .. " to " .. fmtTime(c.until_) .. (cert.expired(c) and "   EXPIRED" or ""))
  ctx.say("fingerprint: " .. cert.fingerprint(c))
  ctx.say("serial:      " .. c.serial .. (c.ca and "   (certificate authority)" or ""))
  ctx.say("signature:   " .. (cert.signatureOk(c) and "ok" or "BAD"))
end

function M.run(args, ctx)
  ctx = defaultCtx(ctx)
  local dir = ctx.dir
  local sub = args[1]
  if sub == "ca" then
    if args[2] == "show" then
      local text = vfs.readFile(dir .. "/ca.crt")
      if not text then ctx.err("no CA here (tlsctl ca init <name>)") return false end
      ctx.say(text)
      return true
    elseif args[2] == "init" then
      if not isAdmin(ctx) then return false end
      local name = args[3]
      if not name then ctx.err("usage: tlsctl ca init <name>") return false end
      if vfs.fs.exists(dir .. "/ca.key") then ctx.err("this computer already has a CA") return false end
      local pair = crypto.signingKey()
      local c = cert.selfSigned(name, pair, { ca = true, days = 3650 })
      tls.saveKey(dir .. "/ca.key", pair)
      vfs.writeFile(dir .. "/ca.crt", cert.encode(c))
      tls.store({ dir = dir }):addCa(c)
      ctx.say("CA " .. name .. " created. Its key is in " .. dir .. "/ca.key: protect that file.")
      ctx.say("Fingerprint: " .. cert.fingerprint(c))
      return true
    end
  elseif sub == "cert" then
    if args[2] == "issue" or args[2] == "selfsign" then
      if not isAdmin(ctx) then return false end
      local name = args[3]
      if not name then ctx.err("usage: tlsctl cert " .. args[2] .. " <name> [other names] [--days n]") return false end
      local names, days = {}, 365
      local i = 4
      while args[i] do
        if args[i] == "--days" then days = tonumber(args[i + 1]) or 365 i = i + 2 else names[#names + 1] = args[i] i = i + 1 end
      end
      local pair = crypto.signingKey()
      local c
      if args[2] == "issue" then
        local caKey = crypto.base64Decode((vfs.readFile(dir .. "/ca.key") or ""):gsub("%s+", ""))
        local caCert = cert.decode(vfs.readFile(dir .. "/ca.crt"))
        if not caKey or not caCert then ctx.err("no CA here: run tlsctl ca init <name> first") return false end
        c = cert.issue({ subject = name, names = names, key = pair.public, issuerName = caCert.subject, issuerKey = crypto.signingKey(caKey), days = days })
      else
        c = cert.selfSigned(name, pair, { names = names, days = days })
      end
      vfs.writeFile(dir .. "/" .. name .. ".crt", cert.encode(c))
      tls.saveKey(dir .. "/" .. name .. ".key", pair)
      ctx.say("certificate for " .. name .. " written to " .. dir .. "/" .. name .. ".crt (key: " .. name .. ".key)")
      return true
    elseif args[2] == "show" then
      local target = args[3]
      local text = target and (vfs.readFile(target) or vfs.readFile(dir .. "/" .. target .. ".crt"))
      local c, err = cert.decode(text)
      if not c then ctx.err(tostring(err or "no such certificate")) return false end
      describe(c, ctx)
      return true
    end
  elseif sub == "trust" then
    local store = tls.store({ dir = dir })
    if args[2] == "list" then
      for _, c in ipairs(store.cas) do ctx.say(("%s  %s"):format(c.subject, cert.fingerprint(c))) end
      if #store.cas == 0 then ctx.say("no CA is trusted") end
      return true
    elseif args[2] == "add" then
      if not isAdmin(ctx) then return false end
      local c, err = cert.decode(vfs.readFile(args[3] or "") or "")
      if not c then ctx.err("cannot read the certificate: " .. tostring(err)) return false end
      if not c.ca then ctx.err("that certificate is not a certificate authority") return false end
      if not cert.signatureOk(c) then ctx.err("the signature is wrong") return false end
      store:addCa(c)
      ctx.say("now trusting " .. c.subject .. " (" .. cert.fingerprint(c) .. ")")
      return true
    elseif args[2] == "remove" then
      if not isAdmin(ctx) then return false end
      local name = tostring(args[3] or ""):gsub("[^%w%-_.]", "_")
      local path = dir .. "/ca/" .. name .. ".crt"
      if not vfs.fs.exists(path) then ctx.err("no such CA") return false end
      vfs.fs.delete(path)
      return true
    end
  elseif sub == "known" then
    local store = tls.store({ dir = dir })
    if args[2] == "forget" then
      if not isAdmin(ctx) then return false end
      store:forget(args[3] or "")
      return true
    end
    local hosts = {}
    for h in pairs(store.pinned) do hosts[#hosts + 1] = h end
    table.sort(hosts)
    for _, h in ipairs(hosts) do ctx.say(h .. "  " .. store.pinned[h]) end
    if #hosts == 0 then ctx.say("nothing pinned yet") end
    return true
  elseif sub == "revoke" then
    if not isAdmin(ctx) then return false end
    if not args[2] then ctx.err("usage: tlsctl revoke <serial|fingerprint>") return false end
    tls.store({ dir = dir }):revoke(args[2])
    ctx.say("revoked")
    return true
  end
  ctx.err("usage: tlsctl ca init|show | cert issue|selfsign|show | trust add|list|remove | known [forget host] | revoke id")
  return false
end

return M
