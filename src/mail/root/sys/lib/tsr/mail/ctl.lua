-- SPDX-License-Identifier: AGPL-3.0-or-later
-- mailctl: administration of the mail server on this computer. Works on the files (accounts, mailboxes, queue, settings), so the server need not be stopped.
--   mailctl init [host [domain]] [--force]            write a commented settings file
--   mailctl status
--   mailctl user list | add <name> [password] [--quota BYTES] | del <name> [--keep-mail] | passwd <name> [password] | quota <name> <BYTES>
--   mailctl domain list | add <domain> | del <domain>
--   mailctl relay list | add <cidr> | del <cidr>       client networks that may send mail anywhere without logging in
--   mailctl alias list | add <alias> <target...> | del <alias>       alias: "postmaster" or "team@example.lan"; targets: mailboxes or full addresses
--   mailctl queue [list] | show <id> | flush | delete <id>
--   mailctl spam stats | learn spam|ham <file...> | test <file> [ip] | allow|deny list|add|del <address, domain or ip>
--   mailctl dkim key <selector> [domain] | record <selector>      make a signing key / show the DNS record to publish
--   mailctl dns [domain]                                          the DNS records this server needs
local config = require("tsr.mail.config")
local storeMod = require("tsr.mail.store")
local msg = require("tsr.mail.message")
local vfs = require("tsr.vfs")
local B = require("tsr.inet.bytes")

local M = {}

local function defaultCtx(ctx)
  ctx = ctx or {}
  ctx.say = ctx.say or function(t) print(t) end
  ctx.err = ctx.err or ctx.say
  ctx.readPassword = ctx.readPassword or function(prompt)
    io.write(prompt)
    local p = read("*")
    return p
  end
  return ctx
end

local function openStore(ctx)
  local cfg = ctx.config or config.load() or {}
  return ctx.store or storeMod.new({ root = cfg.root, users = cfg.users, iterations = cfg.passwordIterations }), cfg
end

local function flags(args)
  local pos, opt = {}, {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--quota" then i = i + 1 opt.quota = tonumber(args[i])
    elseif a == "--admin" then opt.admin = true
    elseif a == "--keep-mail" then opt.keep = true
    elseif a == "--force" then opt.force = true
    else pos[#pos + 1] = a end
    i = i + 1
  end
  return pos, opt
end

local function size(n)
  if n >= 1048576 then return ("%.1f MB"):format(n / 1048576) end
  if n >= 1024 then return ("%.1f KB"):format(n / 1024) end
  return n .. " B"
end

local function password(ctx, given, who)
  if given and given ~= "" then return given end
  local a = ctx.readPassword("Password for " .. who .. ": ")
  local b = ctx.readPassword("Again: ")
  if a ~= b then return nil, "the passwords differ" end
  return a
end

---------------------------------------------------------------------------------------------------------------------

local function cmdUser(args, ctx)
  local store = openStore(ctx)
  local sub = table.remove(args, 1) or "list"
  local pos, opt = flags(args)
  if sub == "list" then
    local users = store:users()
    local names = {}
    for n in pairs(users) do names[#names + 1] = n end
    table.sort(names)
    if #names == 0 then ctx.say("no mailboxes yet (mailctl user add <name>)") return true end
    for _, n in ipairs(names) do
      ctx.say(("%-16s %9s used of %9s%s"):format(n, size(store:usage(n)), size(users[n].quota or 0), users[n].admin and "   admin" or ""))
    end
    return true
  elseif sub == "add" then
    if not pos[1] then ctx.err("usage: mailctl user add <name> [password] [--quota BYTES]") return false end
    local pw, why = password(ctx, pos[2], pos[1])
    if not pw then ctx.err(why) return false end
    local ok, err = store:addUser(pos[1], pw, { quota = opt.quota, admin = opt.admin })
    if not ok then ctx.err(tostring(err)) return false end
    ctx.say("mailbox " .. pos[1]:lower() .. " created")
    return true
  elseif sub == "del" then
    if not pos[1] then ctx.err("usage: mailctl user del <name> [--keep-mail]") return false end
    if not store:exists(pos[1]) then ctx.err("no such mailbox") return false end
    store:removeUser(pos[1], opt.keep)
    ctx.say("mailbox " .. pos[1] .. (opt.keep and " removed (the mail was kept)" or " and its mail removed"))
    return true
  elseif sub == "passwd" then
    if not pos[1] or not store:exists(pos[1]) then ctx.err("usage: mailctl user passwd <name> [password]") return false end
    local pw, why = password(ctx, pos[2], pos[1])
    if not pw then ctx.err(why) return false end
    local ok, err = store:setPassword(pos[1], pw)
    if not ok then ctx.err(tostring(err)) return false end
    ctx.say("password changed")
    return true
  elseif sub == "quota" then
    local n = tonumber(pos[2])
    if not pos[1] or not n then ctx.err("usage: mailctl user quota <name> <bytes>") return false end
    local ok, err = store:setQuota(pos[1], n)
    if not ok then ctx.err(tostring(err)) return false end
    ctx.say(("quota of %s is now %s"):format(pos[1], size(n)))
    return true
  end
  ctx.err("usage: mailctl user list | add | del | passwd | quota")
  return false
end

local function listCmd(field, label, normalize, check)
  return function(args, ctx)
    local r = config.routing()
    local sub = table.remove(args, 1) or "list"
    local list = r[field]
    if sub == "list" then
      if #list == 0 then ctx.say("no " .. label .. " configured here (the settings file may hold some)") end
      for _, v in ipairs(list) do ctx.say(v) end
      return true
    end
    local value = args[1] and normalize(args[1])
    if not value then ctx.err("usage: mailctl " .. label .. " list | add <value> | del <value>") return false end
    if check then
      local okC, why = check(value)
      if not okC then ctx.err(why) return false end
    end
    if sub == "add" then
      for _, v in ipairs(list) do if v == value then ctx.say(value .. " is in the list already") return true end end
      list[#list + 1] = value
      config.saveRouting(r)
      ctx.say("added " .. value .. " (the server picks it up within a few seconds)")
      return true
    elseif sub == "del" then
      for i, v in ipairs(list) do
        if v == value then table.remove(list, i) config.saveRouting(r) ctx.say("removed " .. value) return true end
      end
      ctx.err(value .. " is not in the list")
      return false
    end
    ctx.err("usage: mailctl " .. label .. " list | add <value> | del <value>")
    return false
  end
end

local cmdDomain = listCmd("domains", "domain", function(s) return s:lower() end, function(d)
  if not d:match("^[%w][%w.%-]*$") then return false, "that is not a domain name" end
  return true
end)
local cmdRelay = listCmd("relay", "relay", function(s) return s end, function(c)
  if not B.cidr(c) then return false, "that is not a network (example: 10.0.0.0/24)" end
  return true
end)

local function cmdAlias(args, ctx)
  local r = config.routing()
  local sub = table.remove(args, 1) or "list"
  if sub == "list" then
    local names = {}
    for k in pairs(r.aliases) do names[#names + 1] = k end
    table.sort(names)
    if #names == 0 then ctx.say("no aliases configured here") end
    for _, k in ipairs(names) do ctx.say(("%-28s -> %s"):format(k, table.concat(r.aliases[k], ", "))) end
    return true
  elseif sub == "add" then
    local name = args[1] and args[1]:lower()
    if not name or #args < 2 then ctx.err("usage: mailctl alias add <alias> <target...>") return false end
    local targets = {}
    for i = 2, #args do targets[#targets + 1] = args[i]:lower() end
    r.aliases[name] = targets
    config.saveRouting(r)
    ctx.say(("%s -> %s"):format(name, table.concat(targets, ", ")))
    return true
  elseif sub == "del" then
    local name = args[1] and args[1]:lower()
    if not name or not r.aliases[name] then ctx.err("no such alias") return false end
    r.aliases[name] = nil
    config.saveRouting(r)
    ctx.say("removed " .. name)
    return true
  end
  ctx.err("usage: mailctl alias list | add <alias> <target...> | del <alias>")
  return false
end

local function queueDir(ctx)
  local cfg = ctx.config or config.load() or {}
  return cfg.queueDir or require("tsr.mail").QUEUE
end

local function cmdQueue(args, ctx)
  local sub = table.remove(args, 1) or "list"
  local mailMod = require("tsr.mail")
  local dir = queueDir(ctx)
  local items = mailMod.queueList(dir)
  if sub == "list" then
    if #items == 0 then ctx.say("the queue is empty") return true end
    for _, m in ipairs(items) do
      local rc = {}
      for _, r in ipairs(m.rcpts) do rc[#rc + 1] = r.addr end
      ctx.say(("%-12s from <%s> to %s   tries %d%s"):format(m.id, m.sender, table.concat(rc, ", "), m.tries or 0, m.last and ("   last: " .. m.last) or ""))
    end
    return true
  elseif sub == "show" then
    local id = args[1]
    local raw = id and vfs.readFile(dir .. "/" .. id .. ".eml", true)
    if not raw then ctx.err("no such queue entry") return false end
    ctx.say(raw:sub(1, 3000))
    return true
  elseif sub == "flush" then
    vfs.mkdirp("/var/spool/mail")
    vfs.writeFile(config.FLUSH, "1")
    ctx.say("asked the server to try everything in the queue now")
    return true
  elseif sub == "delete" then
    local id = args[1]
    if not id or not vfs.fs.exists(dir .. "/" .. id .. ".meta") then ctx.err("no such queue entry") return false end
    vfs.fs.delete(dir .. "/" .. id .. ".meta")
    if vfs.fs.exists(dir .. "/" .. id .. ".eml") then vfs.fs.delete(dir .. "/" .. id .. ".eml") end
    ctx.say("removed " .. id .. " from the queue")
    return true
  end
  ctx.err("usage: mailctl queue [list] | show <id> | flush | delete <id>")
  return false
end

local function bayesPath(cfg)
  local spam = type(cfg.spam) == "table" and cfg.spam or {}
  if spam.bayes == false then return nil end
  return type(spam.bayes) == "string" and spam.bayes or "/var/lib/tsr/mail/bayes.lua"
end

local function cmdSpam(args, ctx)
  local sub = table.remove(args, 1) or "stats"
  local _, cfg = openStore(ctx)
  local okB, bayes = pcall(require, "tsr.mail.spam.bayes")
  if not okB then ctx.err("anti-spam is a separate package: pkg install mail-spam") return false end
  if sub == "stats" then
    local path = bayesPath(cfg)
    if not path then ctx.say("the learning filter is switched off") return true end
    local b = bayes.new(path)
    local s, h = b:learned()
    local n = 0
    for _ in pairs(b.tokens) do n = n + 1 end
    ctx.say(("learned from %d spam and %d good messages (%d words); it %s"):format(s, h, n, (s >= bayes.MIN_LEARNED and h >= bayes.MIN_LEARNED) and "is judging mail" or "needs at least 3 of each before it judges"))
    return true
  elseif sub == "learn" then
    local kind = args[1]
    if kind ~= "spam" and kind ~= "ham" or #args < 2 then ctx.err("usage: mailctl spam learn spam|ham <file...>") return false end
    local path = bayesPath(cfg)
    if not path then ctx.err("the learning filter is switched off in mail.lua") return false end
    local b = bayes.new(path)
    local n = 0
    for i = 2, #args do
      local raw = vfs.readFile(vfs.normalize(args[i]), true)
      if raw then b:train(msg.normalize(raw), kind == "spam") n = n + 1 else ctx.err("cannot read " .. args[i]) end
    end
    b:save()
    ctx.say(("learned %d message(s) as %s"):format(n, kind))
    return n > 0
  elseif sub == "test" then
    local raw = args[1] and vfs.readFile(vfs.normalize(args[1]), true)
    if not raw then ctx.err("usage: mailctl spam test <file> [ip]") return false end
    local mailMod = require("tsr.mail")
    local spam = require("tsr.mail.spam")
    local stack = ctx.stack
    if not stack then
      local okS, s = pcall(function() return require("tsr.inet.socket").default() end)
      if not okS then ctx.err(tostring(s)) return false end
      stack = s
    end
    local mail = mailMod.new(stack, cfg, ctx.store)
    local S = spam.install(mail, type(cfg.spam) == "table" and cfg.spam or {})
    local verdict, c = S:test(raw, { ip = args[2] })
    ctx.say("verdict: " .. verdict[1] .. (verdict[3] and (" (score " .. verdict[3] .. ")") or "") .. (verdict[2] and (" " .. tostring(verdict[2])) or ""))
    for _, l in ipairs(c.add) do ctx.say(l) end
    return true
  elseif sub == "allow" or sub == "deny" then
    local r = config.routing()
    local list = r[sub]
    local action = args[1] or "list"
    if action == "list" then for _, v in ipairs(list) do ctx.say(v) end if #list == 0 then ctx.say("empty") end return true end
    local value = args[2] and args[2]:lower()
    if not value then ctx.err("usage: mailctl spam " .. sub .. " add|del <address, domain or ip>") return false end
    if action == "add" then
      for _, v in ipairs(list) do if v == value then return true end end
      list[#list + 1] = value
    elseif action == "del" then
      local found = false
      for i, v in ipairs(list) do if v == value then table.remove(list, i) found = true break end end
      if not found then ctx.err(value .. " is not in the list") return false end
    else ctx.err("usage: mailctl spam " .. sub .. " list|add|del <value>") return false end
    config.saveRouting(r)
    ctx.say(sub .. " list updated")
    return true
  end
  ctx.err("usage: mailctl spam stats | learn spam|ham <file...> | test <file> [ip] | allow|deny list|add|del <value>")
  return false
end

local function cmdDkim(args, ctx)
  local sub = table.remove(args, 1)
  local okS, spam = pcall(require, "tsr.mail.spam")
  if not okS then ctx.err("DKIM belongs to the anti-spam package: pkg install mail-spam") return false end
  local cfg = ctx.config or config.load() or {}
  local selector = args[1]
  if sub == "key" and selector then
    local path = config.DKIM_DIR .. "/" .. selector .. ".key"
    if vfs.fs.exists(path) then ctx.err(path .. " exists already; use `mailctl dkim record " .. selector .. "` to see its DNS record") return false end
    local record = spam.makeDkimKey(path)
    local domain = args[2] or (cfg.domains and cfg.domains[1]) or "example.lan"
    ctx.say("secret key saved in " .. path .. " (administrators only; keep it private)")
    ctx.say("publish this TXT record in DNS:")
    ctx.say(("  %s._domainkey.%s  TXT  \"%s\""):format(selector, domain, record))
    ctx.say("then enable signing in /etc/tsr/mail/mail.lua, inside spam = { ... }:")
    ctx.say(("  dkim = { [\"%s\"] = { selector = \"%s\", keyFile = \"%s\" } },"):format(domain, selector, path))
    return true
  elseif sub == "record" and selector then
    local seed, why = spam.loadDkimKey(config.DKIM_DIR .. "/" .. selector .. ".key")
    if not seed then ctx.err(tostring(why)) return false end
    ctx.say(spam.dkim.dnsRecord(seed))
    return true
  end
  ctx.err("usage: mailctl dkim key <selector> [domain] | record <selector>")
  return false
end

local function cmdDns(args, ctx)
  local cfg = ctx.config or config.load() or {}
  local domain = args[1] or (cfg.domains and cfg.domains[1]) or "example.lan"
  local host = cfg.hostname or ("mail." .. domain)
  local ip = "<this server's address>"
  if ctx.stack and ctx.stack.interfaces then
    for _, i in pairs(ctx.stack.interfaces) do if i.ip and i.name ~= "lo" then ip = B.ipStr(i.ip) break end end
  end
  ctx.say("Records to publish for " .. domain .. " (dnsctl add <zone> <name> <type> <data>):")
  ctx.say(("  %s.  A     %s"):format(host, ip))
  ctx.say(("  %s.  MX    10 %s."):format(domain, host))
  ctx.say(("  %s.  TXT   \"v=spf1 mx -all\"                      (only this server sends mail for the domain)"):format(domain))
  ctx.say(("  _dmarc.%s.  TXT  \"v=DMARC1; p=quarantine\"        (what others do with forged mail; use p=none first)"):format(domain))
  ctx.say("  and, if you sign mail:  <selector>._domainkey." .. domain .. ".  TXT  (see: mailctl dkim key <selector>)")
  return true
end

local function cmdStatus(ctx)
  local store, cfg = openStore(ctx)
  local users = store:users()
  local n = 0
  for _ in pairs(users) do n = n + 1 end
  local items = require("tsr.mail").queueList(queueDir(ctx))
  ctx.say("host name:   " .. tostring(cfg.hostname or "(not set)"))
  ctx.say("domains:     " .. (#(cfg.domains or {}) > 0 and table.concat(cfg.domains, ", ") or "(none: mailctl domain add <domain>)"))
  ctx.say("relay nets:  " .. (#(cfg.relayNetworks or {}) > 0 and table.concat(cfg.relayNetworks, ", ") or "(none: only logged-in users may send to other domains)"))
  ctx.say("mailboxes:   " .. n)
  ctx.say("queue:       " .. #items .. " message(s) waiting")
  ctx.say("anti-spam:   " .. (cfg.spam == false and "off" or "on"))
  ctx.say("TLS:         " .. (cfg.tls and "on" or "off (passwords only over trusted LANs: allowPlainAuth)"))
  return true
end

function M.run(args, ctx)
  ctx = defaultCtx(ctx)
  local sub = table.remove(args, 1)
  if sub == "init" then
    local pos, opt = flags(args)
    local ok, err = config.writeTemplate(pos[1], pos[2], opt.force)
    if not ok then ctx.err(tostring(err)) return false end
    ctx.say("wrote " .. config.STATIC .. " - edit it, then: svc start maild")
    return true
  elseif sub == "status" then return cmdStatus(ctx)
  elseif sub == "user" then return cmdUser(args, ctx)
  elseif sub == "domain" then return cmdDomain(args, ctx)
  elseif sub == "relay" then return cmdRelay(args, ctx)
  elseif sub == "alias" then return cmdAlias(args, ctx)
  elseif sub == "queue" then return cmdQueue(args, ctx)
  elseif sub == "spam" then return cmdSpam(args, ctx)
  elseif sub == "dkim" then return cmdDkim(args, ctx)
  elseif sub == "dns" then return cmdDns(args, ctx)
  end
  ctx.err("usage: mailctl init | status | user | domain | relay | alias | queue | spam | dkim | dns   (see: help mail)")
  return false
end

return M
