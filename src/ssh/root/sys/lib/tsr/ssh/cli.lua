-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Commands of the in-game secure shell (they only reach computers of the same game world):
--   ssh [-i keyfile] [--accept-new] [user@]host [command...]     log in, or run one command
--   scp [-i keyfile] [-r] <source> <destination>                 copy files; remote side is  [user@]host:path
--   ssh-keygen [-f file] [-C comment] [-N passphrase]            make a key pair       (-l show fingerprint, -R host forget a host key, -A host key)
--   ssh-copy-id [-i pubfile] [user@]host                         put your public key on another computer (asks for the password once)
--   sshd status | fingerprint | password on|off | authorize [user] <public key line>
local crypto = require("tsr.crypto")
local keys = require("tsr.ssh.keys")
local client = require("tsr.ssh.client")
local server = require("tsr.ssh.server")
local vfs = require("tsr.vfs")

local M = {}

local function defaultIO()
  local io = {}
  local function color(c) if term.isColor() then term.setTextColor(c) end end
  function io.say(t) print(t) end
  function io.write(t) write(t) end
  function io.err(t) color(colors.red) print(t) color(colors.white) end
  function io.readLine(prompt) if prompt then write(prompt) end return read() end
  function io.readPassword(prompt) if prompt then write(prompt) end return read("*") end
  function io.collect(n) crypto.rand.collect(n, function(i, total) write("\r" .. i .. "/" .. total .. " ") end) print() end
  function io.confirm(question) write(question .. " ") local a = read() return a ~= nil and (a:lower() == "yes" or a:lower() == "y") end
  return io
end

local function split(args)
  local flags, words, i = {}, {}, 1
  while i <= #args do
    local a = args[i]
    if a == "-i" or a == "-f" or a == "-C" or a == "-N" or a == "-R" then flags[a:sub(2)] = args[i + 1] i = i + 1
    elseif a:sub(1, 2) == "--" then flags[a:sub(3)] = true
    elseif a:sub(1, 1) == "-" and #a == 2 then flags[a:sub(2)] = true
    else words[#words + 1] = a end
    i = i + 1
  end
  return flags, words
end

local function userHost(spec)
  local user, host = tostring(spec):match("^([^@]+)@(.+)$")
  if user then return user, host end
  return nil, spec
end

local function currentUser()
  local ok, auth = pcall(require, "tsr.auth")
  if ok and type(auth) == "table" and auth.current then return auth.current() end
  return nil
end

--- Load the identity key (asking for a passphrase when it has one). Returns key or nil.
local function loadIdentity(path, io)
  path = path or client.defaultIdentity()
  if not fs.exists(path) then return nil end
  local passphrase
  if keys.needsPassphrase(path) then passphrase = io.readPassword("Enter passphrase for " .. path .. ": ") end
  local key, err = keys.load(path, passphrase)
  if not key then io.err(err == "passphrase" and "wrong passphrase" or tostring(err)) return nil end
  return key
end

local function confirmHost(io)
  return function(info)
    io.say(("The authenticity of computer %d (%s) can't be established."):format(info.id, tostring(info.host)))
    io.say("Its key fingerprint is " .. info.fingerprint .. ".")
    for _, line in ipairs(info.art) do io.say(line) end
    return io.confirm("Are you sure you want to continue connecting (yes/no)?")
  end
end

local function connect(node, flags, target, io)
  local user, host = userHost(target)
  user = user or currentUser() or "root"
  local identity = loadIdentity(flags.i, io)
  local conn, err = client.connect(node, host, {
    user = user, identity = identity, acceptNew = flags["accept-new"], confirm = confirmHost(io),
    onWarning = function(t) io.say("Warning: " .. t) end,
    password = function() return io.readPassword(user .. "@" .. host .. "'s password: ") end,
  })
  return conn, err
end

---------------------------------------------------------------------------------------------------------------------
-- ssh
---------------------------------------------------------------------------------------------------------------------

function M.ssh(args, io, node)
  io = io or defaultIO()
  node = node or require("tsr.net").default()
  local flags, words = split(args)
  local target = table.remove(words, 1)
  if not target then io.err("usage: ssh [-i keyfile] [--accept-new] [user@]host [command...]") return false end
  local conn, err = connect(node, flags, target, io)
  if not conn then io.err(tostring(err)) return false end
  local ok = true
  if #words > 0 then
    local res, e = conn:call("exec", { line = table.concat(words, " "), timeout = 60 }, 70)
    if not res then io.err(tostring(e)) ok = false
    else
      if res.output ~= "" then io.write(res.output) if res.output:sub(-1) ~= "\n" then io.say("") end end
      if res.truncated then io.err("[output truncated]") end
      if res.timedOut then io.err("[stopped: the command took too long]") end
      ok = res.status == 0
    end
  else
    local hello = conn:call("hello", {}) or {}
    io.say(("Logged in to %s as %s. Type exit to leave."):format(tostring(conn.host), tostring(conn.user)))
    local cwd = hello.cwd or "/"
    while true do
      local line = io.readLine(("%s@%s:%s$ "):format(conn.user, tostring(conn.host), cwd))
      if line == nil or line == "exit" or line == "logout" then break end
      if line:match("%S") then
        local res, e = conn:call("exec", { line = line, timeout = 60 }, 70)
        if not res then io.err(tostring(e)) if conn.closed then break end
        else
          cwd = res.cwd or cwd
          if res.output ~= "" then io.write(res.output) if res.output:sub(-1) ~= "\n" then io.say("") end end
          if res.timedOut then io.err("[stopped: the command took too long]") end
        end
      end
    end
  end
  conn:close()
  return ok
end

---------------------------------------------------------------------------------------------------------------------
-- scp
---------------------------------------------------------------------------------------------------------------------

local function parseRemote(spec)
  local who, path = tostring(spec):match("^([^/:]+):(.*)$")
  if not who then return nil end
  return who, path
end

local function upload(conn, localPath, remotePath, io)
  local h = fs.open(localPath, "rb")
  if not h then return nil, "cannot read " .. localPath end
  local data = h.readAll() or ""
  h.close()
  local offset = 0
  repeat
    local piece = data:sub(offset + 1, offset + server.CHUNK)
    local finish = offset + #piece >= #data
    local res, err = conn:call("put", { path = remotePath, offset = offset, data = crypto.base64Encode(piece), finish = finish }, 10)
    if not res then return nil, err end
    offset = offset + #piece
  until finish
  io.say(("%s  %d bytes"):format(localPath, #data))
  return true
end

local function download(conn, remotePath, localPath, io)
  local out, offset = {}, 0
  while true do
    local res, err = conn:call("get", { path = remotePath, offset = offset }, 10)
    if not res then return nil, err end
    local piece = crypto.base64Decode(res.data) or ""
    out[#out + 1] = piece
    offset = offset + #piece
    if res.eof then break end
  end
  local h = fs.open(localPath, "wb")
  if not h then return nil, "cannot write " .. localPath end
  h.write(table.concat(out))
  h.close()
  io.say(("%s  %d bytes"):format(remotePath, offset))
  return true
end

local function uploadTree(conn, localPath, remotePath, io)
  if fs.isDir(localPath) then
    local _, err = conn:call("mkdir", { path = remotePath })
    if err then return nil, err end
    for _, name in ipairs(fs.list(localPath)) do
      local ok, e = uploadTree(conn, localPath .. "/" .. name, remotePath .. "/" .. name, io)
      if not ok then return nil, e end
    end
    return true
  end
  return upload(conn, localPath, remotePath, io)
end

local function downloadTree(conn, remotePath, localPath, io)
  local st, err = conn:call("stat", { path = remotePath })
  if not st then return nil, err end
  if not st.exists then return nil, "no such file: " .. remotePath end
  if st.isDir then
    fs.makeDir(localPath)
    local list, lerr = conn:call("list", { path = remotePath })
    if not list then return nil, lerr end
    for _, e in ipairs(list) do
      local ok, derr = downloadTree(conn, remotePath .. "/" .. e.name, localPath .. "/" .. e.name, io)
      if not ok then return nil, derr end
    end
    return true
  end
  return download(conn, remotePath, localPath, io)
end

function M.scp(args, io, node)
  io = io or defaultIO()
  node = node or require("tsr.net").default()
  local flags, words = split(args)
  local src, dst = words[1], words[2]
  if not (src and dst) then io.err("usage: scp [-i keyfile] [-r] <source> <destination>   (remote: [user@]host:path)") return false end
  local srcRemote, srcPath = parseRemote(src)
  local dstRemote, dstPath = parseRemote(dst)
  if (srcRemote and dstRemote) or not (srcRemote or dstRemote) then io.err("exactly one side must be remote (host:path)") return false end
  local conn, err = connect(node, flags, srcRemote or dstRemote, io)
  if not conn then io.err(tostring(err)) return false end
  local ok, e
  if dstRemote then
    if fs.isDir(src) and not flags.r then io.err(src .. " is a directory (use -r)") conn:close() return false end
    local st = conn:call("stat", { path = dstPath })
    local target = dstPath
    if st and st.exists and st.isDir then target = dstPath .. "/" .. fs.getName(src) end
    ok, e = uploadTree(conn, "/" .. fs.combine(src, ""), target, io)
  else
    local target = dst
    if fs.isDir(dst) then target = dst .. "/" .. fs.getName(srcPath) end
    local st = conn:call("stat", { path = srcPath })
    if st and st.exists and st.isDir and not flags.r then io.err(srcPath .. " is a directory (use -r)") conn:close() return false end
    ok, e = downloadTree(conn, srcPath, target, io)
  end
  conn:close()
  if not ok then io.err(tostring(e)) return false end
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- ssh-keygen, ssh-copy-id
---------------------------------------------------------------------------------------------------------------------

function M.keygen(args, io)
  io = io or defaultIO()
  local flags, words = split(args)
  if flags.A then
    local key = keys.hostKey()
    io.say("Host key: " .. crypto.fingerprint(key.public))
    return true
  end
  if flags.R then
    local n = keys.removeHost(client.defaultKnownHosts(), flags.R)
    io.say(n > 0 and ("Removed " .. n .. " entr" .. (n == 1 and "y" or "ies") .. " for " .. flags.R) or ("No entry for " .. flags.R))
    return true
  end
  local path = flags.f or client.defaultIdentity()
  if flags.l then
    local line = vfs.readFile(path .. ".pub") or vfs.readFile(path)
    local public = line and keys.decode(line)
    if not public then io.err("no key at " .. path) return false end
    io.say(crypto.fingerprint(public) .. "  " .. path)
    for _, l in ipairs(keys.randomart(public)) do io.say(l) end
    return true
  end
  if fs.exists(path) then io.err(path .. " already exists; not overwriting") return false end
  local passphrase = flags.N
  if passphrase == nil then
    passphrase = io.readPassword("Enter passphrase (empty for none): ")
    if passphrase ~= "" then
      if io.readPassword("Enter same passphrase again: ") ~= passphrase then io.err("passphrases do not match") return false end
    end
  end
  io.say("Collecting randomness: press 16 keys at random...")
  if io.collect then io.collect(16) end
  local key = keys.generate(path, { passphrase = passphrase, comment = flags.C or (tostring(currentUser() or "root") .. "@" .. tostring(os.getComputerLabel() or ("cc-" .. os.getComputerID()))) })
  io.say("Your identification has been saved in " .. path)
  io.say("Your public key has been saved in " .. path .. ".pub")
  io.say("The key fingerprint is " .. crypto.fingerprint(key.public))
  for _, l in ipairs(keys.randomart(key.public)) do io.say(l) end
  return true
end

function M.copyId(args, io, node)
  io = io or defaultIO()
  node = node or require("tsr.net").default()
  local flags, words = split(args)
  local target = words[1]
  if not target then io.err("usage: ssh-copy-id [-i pubfile] [user@]host") return false end
  local identity = flags.i or client.defaultIdentity() .. ".pub"
  local line = vfs.readFile(identity)
  if not (line and keys.decode(line)) then io.err("no public key at " .. identity .. " (make one with ssh-keygen)") return false end
  local f2 = {}
  for k, v in pairs(flags) do f2[k] = v end
  f2.i = "/nonexistent"                    -- log in with the password: the key is what we are about to install
  local conn, err = connect(node, f2, target, io)
  if not conn then io.err(tostring(err)) return false end
  local res, e = conn:call("authorize", { line = line })
  conn:close()
  if not res then io.err(tostring(e)) return false end
  io.say(res.added and "Key added. You can now log in without a password." or "That key was already authorized.")
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- sshd administration
---------------------------------------------------------------------------------------------------------------------

function M.sshd(args, io)
  io = io or defaultIO()
  local sub = args[1] or "status"
  local cfg = server.config()
  if sub == "status" then
    io.say("password login: " .. (cfg.password and "ON" or "off (keys only)"))
    io.say("host key: " .. crypto.fingerprint(keys.hostKey().public))
    io.say("open sessions: " .. server.sessionCount())
    io.say("service: `svc status sshd`")
    return true
  elseif sub == "fingerprint" then
    local public = keys.hostKey().public
    io.say(crypto.fingerprint(public))
    for _, l in ipairs(keys.randomart(public)) do io.say(l) end
    return true
  elseif sub == "password" then
    local on = args[2] == "on"
    if args[2] ~= "on" and args[2] ~= "off" then io.err("usage: sshd password on|off") return false end
    cfg.password = on
    vfs.writeTable(server.CONFIG, cfg)
    io.say(on and "Password login is ON: anyone who knows an account password and can reach this computer may log in." or "Password login is off.")
    return true
  elseif sub == "authorize" then
    local user, rest = nil, {}
    for i = 2, #args do rest[#rest + 1] = args[i] end
    local okA, auth = pcall(require, "tsr.auth")
    local multi = okA and type(auth) == "table" and auth.hasUsers and auth.hasUsers()
    if multi then user = table.remove(rest, 1) end
    local public, comment = keys.decode(table.concat(rest, " "))
    if not public then io.err("usage: sshd authorize " .. (multi and "<user> " or "") .. "<public key line>") return false end
    local path = multi and (((auth.get(user) or {}).home or ("/home/" .. tostring(user))) .. "/.ssh/authorized_keys") or server.SYSTEM_AUTHORIZED
    io.say(keys.addAuthorized(path, public, comment) and ("Authorized in " .. path) or "Already authorized.")
    return true
  end
  io.err("usage: sshd status | fingerprint | password on|off | authorize [user] <public key line>")
  return false
end

return M
