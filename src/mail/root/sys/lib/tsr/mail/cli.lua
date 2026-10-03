-- SPDX-License-Identifier: AGPL-3.0-or-later
-- mail: a text mail program. It keeps a local copy of your mail in ~/.mail and talks to your mail server over the network (POP3 to fetch, SMTP to send).
--   mail account                         show the account;  mail account set address=you@example.lan server=10.0.0.1 user=you [name="Your Name"] [pass=...] [tls=none|opportunistic|starttls|pop3s]
--   mail                                 interactive: type "help" at the prompt
--   mail fetch | folders | list [folder] | read <n> [folder] | send <to> [-s subject] [-c cc] [-a file] [-m text] | reply <n> [folder] | forward <n> <to>
--   mail delete <n> [folder] | move <n> <to-folder> [folder] | spam <n> [folder] | save <n> <i> [file]
-- Without -m, "send" and "reply" ask for the text; a line with only a dot ends it.
local msg = require("tsr.mail.message")
local client = require("tsr.mail.client")
local vfs = require("tsr.vfs")

local M = {}

local function defaultCtx(ctx)
  ctx = ctx or {}
  ctx.say = ctx.say or function(t) print(t) end
  ctx.err = ctx.err or ctx.say
  ctx.readLine = ctx.readLine or function(prompt) io.write(prompt) return read() end
  ctx.readPassword = ctx.readPassword or function(prompt) io.write(prompt) return read("*") end
  if not ctx.home then
    local user
    local okA, auth = pcall(require, "tsr.auth")
    if okA and auth.current then user = auth.current() end
    ctx.home = (user and ("/home/" .. user) or "/home") .. "/.mail"
  end
  return ctx
end

local function words(line)
  local out = {}
  local i = 1
  while i <= #line do
    local c = line:sub(i, i)
    if c:match("%s") then i = i + 1
    elseif c == '"' then
      local j = line:find('"', i + 1, true) or (#line + 1)
      out[#out + 1] = line:sub(i + 1, j - 1)
      i = j + 1
    else
      local j = line:find("%s", i) or (#line + 1)
      out[#out + 1] = line:sub(i, j - 1)
      i = j
    end
  end
  return out
end

local function openClient(ctx)
  if ctx.client then return ctx.client end
  if not ctx.stack then
    local okS, s = pcall(function() return require("tsr.inet.socket").default() end)
    if okS then ctx.stack = s end
  end
  ctx.client = client.open({ home = ctx.home, stack = ctx.stack, account = ctx.account, readPassword = ctx.readPassword, tlsStore = ctx.tlsStore })
  return ctx.client
end

local function readBody(ctx)
  ctx.say("Type the message; end with a line holding only a dot.")
  local lines = {}
  while true do
    local l = ctx.readLine("")
    if l == nil or l == "." then break end
    lines[#lines + 1] = l
  end
  return table.concat(lines, "\n")
end

local function short(s, n)
  s = tostring(s):gsub("[%c]", " ")
  if #s > n then return s:sub(1, n - 1) .. "~" end
  return s
end

local function showList(ctx, c, folder)
  local items = c:list(folder)
  if #items == 0 then ctx.say(folder .. " is empty") return true end
  for _, m in ipairs(items) do
    local from = msg.parseAddress(msg.decodeWords(m.from or "")) or {}
    local who = (from.name and from.name ~= "") and from.name or from.addr or m.from
    ctx.say(("%3d %s %-20s %-34s %s"):format(m.n, m.flags:find("S", 1, true) and " " or "N", short(who or "?", 20), short(m.subject or "", 34), (m.date or ""):match("%d+ %a+ %d+") or ""))
  end
  return true
end

local function showMessage(ctx, raw)
  local m = msg.parse(raw)
  ctx.say("From:    " .. msg.decodeWords(m:header("from") or ""))
  ctx.say("To:      " .. msg.decodeWords(m:header("to") or ""))
  if m:header("cc") then ctx.say("Cc:      " .. msg.decodeWords(m:header("cc"))) end
  ctx.say("Date:    " .. (m:header("date") or ""))
  ctx.say("Subject: " .. m:subject())
  local spamStatus = m:header("x-spam-status")
  if spamStatus and spamStatus:lower():sub(1, 3) == "yes" then ctx.say("(the server marked this message as spam)") end
  local auth = m:header("authentication-results")
  if auth and auth:find("dkim=fail", 1, true) or auth and auth:find("spf=fail", 1, true) then ctx.say("(warning: the sender could not be verified)") end
  ctx.say("")
  ctx.say(m:text())
  local att = m:attachments()
  for i, a in ipairs(att) do ctx.say(("[attachment %d: %s, %d bytes, %s]"):format(i, a.name or "unnamed", #a.data, a.type or "?")) end
end

local function compose(ctx, c, args, preset)
  local m = preset or {}
  local files = {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "-s" then i = i + 1 m.subject = args[i]
    elseif a == "-c" then i = i + 1 m.cc = args[i]
    elseif a == "-m" then i = i + 1 m.body = args[i]
    elseif a == "-a" then i = i + 1 files[#files + 1] = args[i]
    elseif not m.to then m.to = args[i] end
    i = i + 1
  end
  if not m.to or m.to == "" then ctx.err("usage: mail send <to> [-s subject] [-c cc] [-a file] [-m text]") return false end
  if not m.subject then m.subject = ctx.readLine("Subject: ") or "" end
  if not m.body then
    local typed = readBody(ctx)
    m.body = (preset and preset.body or "") .. typed
  end
  for _, f in ipairs(files) do
    local path = vfs.normalize(f)
    local data = vfs.readFile(path, true)
    if not data then ctx.err("cannot read " .. f) return false end
    m.attachments = m.attachments or {}
    m.attachments[#m.attachments + 1] = { name = path:match("([^/]+)$"), data = data, type = "application/octet-stream" }
  end
  local ok, why = c:send(m)
  if not ok then ctx.err("not sent: " .. tostring(why)) return false end
  ctx.say(("sent to %d recipient(s)"):format(why or 1))
  return true
end

local COMMANDS

local function dispatch(cmd, args, ctx)
  local f = COMMANDS[cmd]
  if not f then ctx.err("unknown command: " .. tostring(cmd) .. " (try: help)") return false end
  return f(args, ctx)
end

COMMANDS = {
  help = function(_, ctx)
    ctx.say("fetch                 get new mail from the server")
    ctx.say("folders               list the folders")
    ctx.say("list [folder]         show the messages of a folder (default INBOX)")
    ctx.say("read <n> [folder]     show message n")
    ctx.say("send <to> [-s subject] [-c cc] [-a file] [-m text]")
    ctx.say("reply <n> [folder]    answer a message;  replyall <n> answers everybody")
    ctx.say("forward <n> <to>      send a message on")
    ctx.say("delete <n> [folder]   move to Trash (from Trash: delete for good)")
    ctx.say("move <n> <folder> [from-folder]      spam <n> [folder]  = move to Spam      ham <n> = move back to INBOX")
    ctx.say("save <n> <i> [file]   save attachment i of message n")
    ctx.say("account               show the account;  account set key=value ...")
    ctx.say("quit")
    return true
  end,
  account = function(args, ctx)
    local sub = args[1]
    local acc = ctx.account or client.loadAccount(ctx.home)
    if sub == "set" then
      for i = 2, #args do
        local k, v = args[i]:match("^([%w_]+)=(.*)$")
        if not k then ctx.err("use key=value") return false end
        local known = false
        for _, f in ipairs(client.ACCOUNT_FIELDS) do if f == k then known = true end end
        if not known then ctx.err("unknown setting " .. k .. " (" .. table.concat(client.ACCOUNT_FIELDS, ", ") .. ")") return false end
        if k == "leave" then acc[k] = v ~= "no" and v ~= "false"
        elseif k == "pop3port" or k == "smtpport" then acc[k] = tonumber(v)
        else acc[k] = v end
      end
      client.saveAccount(ctx.home, acc)
      ctx.account, ctx.client = acc, nil
      ctx.say("saved")
      return true
    end
    local keys = {}
    for k in pairs(acc) do keys[#keys + 1] = k end
    table.sort(keys)
    if #keys == 0 then ctx.say("no account yet: mail account set address=you@example.lan server=<mail server> user=<mailbox>") end
    for _, k in ipairs(keys) do ctx.say(("%-10s %s"):format(k, k == "pass" and "(saved)" or tostring(acc[k]))) end
    return true
  end,
  fetch = function(_, ctx)
    local c = openClient(ctx)
    local n, why = c:fetch()
    if not n then ctx.err("fetch failed: " .. tostring(why)) return false end
    ctx.say(n == 0 and "no new mail" or (n .. " new message(s)"))
    return true
  end,
  folders = function(_, ctx)
    local c = openClient(ctx)
    for _, f in ipairs(c:folders()) do
      local items = c.store:list("me", f)
      local unread = 0
      for _, m in ipairs(items) do if not m.flags:find("S", 1, true) then unread = unread + 1 end end
      ctx.say(("%-12s %3d message(s), %d unread"):format(f, #items, unread))
    end
    return true
  end,
  list = function(args, ctx) return showList(ctx, openClient(ctx), args[1] or "INBOX") end,
  read = function(args, ctx)
    local c = openClient(ctx)
    local raw, e = c:read(args[2] or "INBOX", args[1])
    if not raw then ctx.err(tostring(e)) return false end
    showMessage(ctx, raw)
    return true
  end,
  send = function(args, ctx) return compose(ctx, openClient(ctx), args) end,
  reply = function(args, ctx)
    local c = openClient(ctx)
    local raw, e = c:read(args[2] or "INBOX", args[1])
    if not raw then ctx.err(tostring(e)) return false end
    local preset = c:replyTo(raw, ctx.all)
    ctx.say("To: " .. preset.to .. "   Subject: " .. preset.subject)
    return compose(ctx, c, {}, preset)
  end,
  replyall = function(args, ctx)
    ctx.all = true
    local r = COMMANDS.reply(args, ctx)
    ctx.all = nil
    return r
  end,
  forward = function(args, ctx)
    local c = openClient(ctx)
    local raw, e = c:read("INBOX", args[1])
    if not raw or not args[2] then ctx.err(raw and "usage: forward <n> <to>" or tostring(e)) return false end
    local m = msg.parse(raw)
    local body = ("---------- Forwarded message ----------\nFrom: %s\nDate: %s\nSubject: %s\n\n%s"):format(m:header("from") or "", m:header("date") or "", m:subject(), m:text())
    return compose(ctx, c, { "-s", "Fwd: " .. m:subject(), "-m", body }, { to = args[2] })
  end,
  delete = function(args, ctx)
    local ok, why = openClient(ctx):delete(args[2] or "INBOX", args[1])
    if not ok then ctx.err(tostring(why)) return false end
    ctx.say("deleted")
    return true
  end,
  move = function(args, ctx)
    if not args[2] then ctx.err("usage: move <n> <folder> [from-folder]") return false end
    local ok, why = openClient(ctx):move(args[3] or "INBOX", args[1], args[2])
    if not ok then ctx.err(tostring(why)) return false end
    ctx.say("moved to " .. args[2])
    return true
  end,
  spam = function(args, ctx)
    local ok, why = openClient(ctx):move(args[2] or "INBOX", args[1], "Spam")
    if not ok then ctx.err(tostring(why)) return false end
    ctx.say("moved to Spam")
    return true
  end,
  ham = function(args, ctx)
    local ok, why = openClient(ctx):move(args[2] or "Spam", args[1], "INBOX")
    if not ok then ctx.err(tostring(why)) return false end
    ctx.say("moved to INBOX")
    return true
  end,
  save = function(args, ctx)
    local c = openClient(ctx)
    local raw, e = c:read("INBOX", args[1])
    if not raw then ctx.err(tostring(e)) return false end
    local att, why = c:saveAttachment(raw, args[2] or 1, args[3])
    if not att then ctx.err(tostring(why)) return false end
    ctx.say(("saved %s (%d bytes)"):format(args[3] or att.name or "attachment", #att.data))
    return true
  end,
}

function M.run(args, ctx)
  ctx = defaultCtx(ctx)
  local cmd = table.remove(args, 1)
  if cmd then return dispatch(cmd, args, ctx) end
  ctx.say("Tessera mail - type help for the commands, quit to leave.")
  while true do
    local line = ctx.readLine("mail> ")
    if line == nil then break end
    local w = words(line)
    local c = table.remove(w, 1)
    if c == "quit" or c == "exit" or c == "q" then break end
    if c then
      local ok, err = pcall(dispatch, c, w, ctx)
      if not ok then ctx.err("error: " .. tostring(err)) end
    end
  end
  return true
end

M.words = words

return M
