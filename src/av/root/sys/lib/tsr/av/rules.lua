-- SPDX-License-Identifier: AGPL-3.0-or-later
-- What the scanner looks for in a Lua program: behaviours that harm other players' computers or servers. Each rule has an id, a score and a test; a program's score
-- is the sum of the rules that fire (each counted once). Rules are about *what the code does* (wipes the disk, downloads and runs unknown code, copies itself to
-- floppies, disables Ctrl+T, sends passwords out ...), not about names, so they also catch new variants. Scores: 5 and above = suspicious, 10 and above = malicious.
--
-- These are heuristics: they find the usual mischief written by players and by copy-pasted "free op" scripts. They cannot find everything and a determined author
-- can hide from them; the sandbox package is the protection for code you do not trust.
local M = {}

---------------------------------------------------------------------------------------------------------------------
-- Source preparation
---------------------------------------------------------------------------------------------------------------------

--- Remove comments (keeps strings, keeps line breaks so that line numbers stay right).
function M.strip(src)
  local out, n = {}, 0
  local i, len = 1, #src
  local function emit(s) n = n + 1 out[n] = s end
  while i <= len do
    local c = src:sub(i, i)
    if c == "-" and src:sub(i + 1, i + 1) == "-" then
      local eq = src:match("^%-%-%[(=*)%[", i)
      if eq then
        local close = "]" .. eq .. "]"
        local j = src:find(close, i, true)
        local stop = j and (j + #close - 1) or len
        emit((src:sub(i, stop):gsub("[^\n]", " ")))
        i = stop + 1
      else
        local j = src:find("\n", i, true) or (len + 1)
        i = j
      end
    elseif c == '"' or c == "'" then
      local j = i + 1
      while j <= len do
        local d = src:sub(j, j)
        if d == "\\" then j = j + 2
        elseif d == c or d == "\n" then break
        else j = j + 1 end
      end
      emit(src:sub(i, j))
      i = j + 1
    elseif c == "[" then
      local eq = src:match("^%[(=*)%[", i)
      if eq then
        local close = "]" .. eq .. "]"
        local j = src:find(close, i, true)
        local stop = j and (j + #close - 1) or len
        emit(src:sub(i, stop))
        i = stop + 1
      else emit(c) i = i + 1 end
    else
      local j = src:find("[%-\"'%[]", i + 1) or (len + 1)
      emit(src:sub(i, j - 1))
      i = j
    end
  end
  return table.concat(out)
end

--- Shannon entropy (bits per character) of a string.
function M.entropy(s)
  if #s == 0 then return 0 end
  local counts, n = {}, #s
  for i = 1, n do
    local b = s:byte(i)
    counts[b] = (counts[b] or 0) + 1
  end
  local h = 0
  for _, c in pairs(counts) do
    local p = c / n
    h = h - p * math.log(p) / math.log(2)
  end
  return h
end

--- All string literals longer than min characters.
local function longStrings(code, min)
  local out = {}
  for body in code:gmatch('"([^"\n]*)"') do if #body >= min then out[#out + 1] = body end end
  for body in code:gmatch("'([^'\n]*)'") do if #body >= min then out[#out + 1] = body end end
  for body in code:gmatch("%[=*%[(.-)%]=*%]") do if #body >= min then out[#out + 1] = body end end
  return out
end

--- Does the text look like Lua source (so the behaviour rules make sense)?
function M.looksLikeLua(data)
  -- it must have the look of code (a call like os.time() or a local) and several Lua words, so that ordinary prose is not taken for a program
  if not (data:find("[%w_]%.[%w_]+%s*%(") or data:find("%f[%w]local%f[%W]")) then return false end
  local hits = 0
  for _, w in ipairs({ "%f[%w]local%f[%W]", "%f[%w]function%f[%W]", "%f[%w]then%f[%W]", "%f[%w]end%f[%W]", "%f[%w]do%f[%W]", "%f[%w]while%f[%W]", "%f[%w]return%f[%W]", "os%.", "fs%.", "shell%.", "peripheral%.", "turtle%.", "http%.", "rednet%.", "term%.", "require", "print%(" }) do
    if data:find(w) then hits = hits + 1 end
  end
  return hits >= 3
end

---------------------------------------------------------------------------------------------------------------------
-- Context for rule tests
---------------------------------------------------------------------------------------------------------------------

local function context(code, path)
  code = " " .. code   -- so that a pattern can ask for "a character before load("
  local ctx = { code = code, path = path or "", lower = nil }
  local function lineOf(pos)
    local _, n = code:sub(1, pos):gsub("\n", "")
    return n + 1
  end
  --- Does the Lua pattern occur? Returns the line of the first occurrence.
  function ctx.has(pattern, plain)
    local s = code:find(pattern, 1, plain)
    if s then return lineOf(s) end
    return nil
  end
  function ctx.count(pattern)
    local n = 0
    for _ in code:gmatch(pattern) do n = n + 1 end
    return n
  end
  --- Does `second` occur within `span` characters after `first`?
  function ctx.near(first, second, span)
    local from = 1
    while true do
      local s, e = code:find(first, from)
      if not s then return nil end
      local window = code:sub(e + 1, e + span)
      if window:find(second) then return lineOf(s) end
      from = e + 1
    end
  end
  function ctx.isStartup()
    local name = ctx.path:match("([^/]+)$") or ""
    return name == "startup" or name == "startup.lua" or ctx.path:match("^/?startup/") ~= nil
  end
  return ctx
end

---------------------------------------------------------------------------------------------------------------------
-- The rules
---------------------------------------------------------------------------------------------------------------------

local function sends(c)
  return c.has("http%.post") or c.has("http%.request") or c.has("rednet%.send") or c.has("rednet%.broadcast") or c.has("modem%.transmit") or c.has("%.transmit%(")
end

local function sleeps(c)
  return c.has("sleep%s*%(") or c.has("os%.sleep") or c.has("os%.pullEvent") or c.has("os%.pullEventRaw") or c.has("coroutine%.yield") or c.has("os%.startTimer") or c.has("rednet%.receive")
end

--- { id, score, description, test(ctx) -> line number (or true) or nil }
M.RULES = {
  { "WIPE_FLOPPY", 4, "erases a floppy disk", function(c)
      return c.has("fs%.delete%s*%(%s*[\"']/?disk[%w]*[\"']%s*%)")
    end },
  { "WIPE_DISK", 10, "deletes the whole disk or the system folders", function(c)
      return c.has("fs%.delete%s*%(%s*[\"']/?[\"']%s*%)") or c.has("fs%.delete%s*%(%s*[\"']/?rom") or c.has("fs%.delete%s*%(%s*[\"']/?sys[\"'/]")
        or c.has("shell%.run%s*%(%s*[\"']%s*rm%s+/?%*") or c.has("shell%.run%s*%(%s*[\"']%s*delete%s+/?%*")
        or c.near("fs%.list%s*%(%s*[\"']/?[\"']%s*%)", "fs%.delete", 400)
        or c.near("fs%.list%s*%(%s*[\"']/?[\"']%s*%)", "shell%.run%s*%(%s*[\"']%s*rm", 400)
    end },
  { "DOWNLOAD_AND_RUN", 5, "downloads code from the web and runs it", function(c)
      if c.has("shell%.run%s*%(%s*[\"']wget%s+run") or c.has("shell%.run%s*%(%s*[\"']pastebin%s+run") then return c.has("wget") or c.has("pastebin") end
      if not (c.has("http%.get") or c.has("http%.request")) then return nil end
      if c.has("[^%w_%.:]load%s*%(%s*http%.get") or c.has("[^%w_%.:]loadstring%s*%(%s*http%.get") or c.has("[^%w_%.:]load%s*%([%w_%.]-readAll") then return c.has("http%.get") or c.has("http%.request") end
      -- the answer of the web request is read, and soon afterwards something is loaded
      local fetched = c.near("http%.get", "readAll", 300) or c.near("http%.request", "readAll", 300)
      if fetched and (c.near("readAll%s*%(%s*%)", "[^%w_%.:]load%s*%(", 250) or c.near("readAll%s*%(%s*%)", "[^%w_%.:]loadstring%s*%(", 250) or c.near("readAll%s*%(%s*%)", "dofile%s*%(", 250)) then return fetched end
      return nil
    end },
  { "RUNS_RECEIVED_CODE", 7, "runs code that arrived over the network (a backdoor)", function(c)
      return c.near("rednet%.receive", "[^%w_%.:]load%s*%(", 250) or c.near("modem_message", "[^%w_%.:]load%s*%(", 300) or c.near("rednet_message", "[^%w_%.:]load%s*%(", 300)
        or c.near("rednet%.receive", "[^%w_%.:]loadstring%s*%(", 250)
    end },
  { "WRITES_STARTUP", 3, "writes a startup file (runs again at every boot)", function(c)
      return c.has("fs%.open%s*%(%s*[\"']/?startup") or c.has("fs%.open%s*%(%s*[\"']/?disk[%w]*/startup") or c.has("fs%.copy%s*%([^)]-[\"']/?startup[%.%w]*[\"']%s*%)") or c.has("fs%.move%s*%([^)]-[\"']/?startup[%.%w]*[\"']%s*%)")
    end },
  { "COPIES_ITSELF", 7, "copies itself to other disks", function(c)
      return c.has("fs%.copy%s*%(%s*shell%.getRunningProgram%s*%(%s*%)") or c.near("shell%.getRunningProgram%s*%(%s*%)", "fs%.copy", 200)
        or (c.has("peripheral%.find%s*%(%s*[\"']drive[\"']") and c.has("fs%.copy") and c.has("startup") and c.has("getMountPath"))
    end },
  { "BLOCKS_CTRL_T", 3, "switches off Ctrl+T so the program cannot be stopped", function(c)
      return c.has("os%.pullEvent%s*=%s*os%.pullEventRaw") or c.has("os%.pullEventRaw%s*=") or c.has("os%.pullEvent%s*=%s*function")
    end },
  { "REBOOT_LOOP", 6, "restarts or shuts down the computer on its own", function(c)
      if c.isStartup() and (c.has("os%.reboot%s*%(") or c.has("os%.shutdown%s*%(")) then return c.has("os%.reboot%s*%(") or c.has("os%.shutdown%s*%(") end
      return c.near("while%s+true%s+do", "os%.reboot%s*%(", 300) or c.near("while%s+true%s+do", "os%.shutdown%s*%(", 300)
    end },
  { "SENDS_SECRETS", 5, "reads password or key files and sends something out", function(c)
      local reads = c.has("/etc/tsr/ssh") or c.has("/etc/tsr/net") or c.has("%.key[\"']") or c.has("auth%.db") or c.has("passwd") or c.has("random%.seed") or c.has("/etc/tsr/inet") or c.has("/etc/tsr/mail")
      if reads and sends(c) and c.has("fs%.open") then return reads end
      return nil
    end },
  { "KEYLOGGER", 4, "records key presses and sends them out", function(c)
      if (c.has("[\"']char[\"']") or c.has("[\"']key[\"']")) and c.has("pullEvent") and sends(c) and not c.has("term%.") and not c.has("read%s*%(") then return c.has("pullEvent") end
      return nil
    end },
  { "FAKE_PASSWORD_PROMPT", 4, "asks for a password and passes it on", function(c)
      if c.has("read%s*%(%s*[\"']%*[\"']") and sends(c) and (c.has("[Pp]assword") or c.has("[Ll]ogin")) then return c.has("read%s*%(%s*[\"']%*[\"']") end
      return nil
    end },
  { "PROCESS_FLOOD", 5, "starts programs in an endless loop without waiting", function(c)
      if (c.has("shell%.openTab") or c.has("multishell%.launch") or c.has("shell%.run")) and c.has("while%s+true%s+do") and not sleeps(c) then return c.has("while%s+true%s+do") end
      return nil
    end },
  { "NETWORK_FLOOD", 3, "sends messages in an endless loop without waiting", function(c)
      if (c.has("rednet%.broadcast") or c.has("modem%.transmit")) and c.has("while%s+true%s+do") and not sleeps(c) then return c.has("while%s+true%s+do") end
      return nil
    end },
  { "OBFUSCATED_LOAD", 6, "builds code from encoded text and runs it", function(c)
      local hit = c.has("[^%w_%.:]load%s*%([^)]-string%.char") or c.has("[^%w_%.:]loadstring%s*%([^)]-string%.char") or c.has("[^%w_%.:]load%s*%([^)]-[Dd]ecode") or c.has("[^%w_%.:]load%s*%([^)]-base64") or c.has("[^%w_%.:]load%s*%([^)]-%f[%w]unhex")
        or c.has("[^%w_%.:]load%s*%([^)]-tonumber%s*%([^)]-16")
      if hit then return hit end
      -- text assembled from character codes, then loaded
      if (c.has("[^%w_%.:]load%s*%(") or c.has("[^%w_%.:]loadstring%s*%(")) and (c.has("string%.char%s*%(%s*[%w_]+%s*%[") or c.has("string%.char%s*%(%s*table%.unpack") or c.has("string%.char%s*%(%s*unpack")) and c.has("{%s*" .. string.rep("%d%d?%d?%s*,%s*", 7) .. "%d%d?%d?") then return c.has("string%.char") end
      -- a big, high-entropy string that goes into load()
      if c.has("[^%w_%.:]load%s*%(") or c.has("[^%w_%.:]loadstring%s*%(") then
        for _, s in ipairs(longStrings(c.code, 400)) do
          if M.entropy(s) > 4.6 then return c.has("[^%w_%.:]load%s*%(") or c.has("[^%w_%.:]loadstring%s*%(") end
        end
      end
      return nil
    end },
  { "ENCODED_BLOB", 2, "contains a large block of encoded data", function(c)
      for _, s in ipairs(longStrings(c.code, 600)) do
        if M.entropy(s) > 4.9 and not s:find("%s") then return true end
      end
      return nil
    end },
  { "CHAR_CODE_STRINGS", 3, "spells out text with character codes to hide it", function(c)
      if c.count("string%.char%s*%(") >= 12 or c.count("\\%d%d%d\\%d%d%d\\%d%d%d") >= 6 or c.count("\\x%x%x\\x%x%x\\x%x%x") >= 6 then return c.has("string%.char") or true end
      return nil
    end },
  { "REACHES_OUT_OF_SANDBOX", 3, "digs into the interpreter (debug library, environments)", function(c)
      local n = 0
      for _, p in ipairs({ "getfenv%s*%(", "setfenv%s*%(", "debug%.sethook", "debug%.getregistry", "debug%.setmetatable", "debug%.getupvalue", "debug%.setupvalue", "rawset%s*%(%s*_G", "_G%s*%[[^%]]-%.%.", "_ENV%s*%[[^%]]-%.%." }) do
        if c.has(p) then n = n + 1 end
      end
      if n >= 2 then return true end
      return nil
    end },
  { "COMMAND_ABUSE", 5, "runs administrator commands (op, kill, ban, gamemode ...)", function(c)
      for _, verb in ipairs({ "op", "deop", "gamemode", "kill", "ban", "pardon", "tp", "execute", "give", "stop", "whitelist", "clear", "setblock", "fill" }) do
        local l = c.has("commands%.exec%s*%(%s*[\"']/?" .. verb .. "[%s\"']") or c.has("commands%.execAsync%s*%(%s*[\"']/?" .. verb .. "[%s\"']")
        if l then return l end
      end
      return nil
    end },
  { "ATTACKS_ANTIVIRUS", 7, "tries to switch off or delete the anti-virus", function(c)
      if c.path:find("^/sys/lib/tsr/av/") or c.path == "/sys/bin/av.lua" then return nil end   -- the anti-virus itself
      return c.has("/var/lib/tsr/av") or c.has("/etc/tsr/av") or c.has("svc%.stop%s*%(%s*[\"']avd") or c.has("tsr%.av%.disable")
    end },
  { "RAISES_PRIVILEGES", 4, "tries to become the administrator without a password", function(c)
      return c.has("setSessionUser%s*%(%s*[\"']root") or c.has("auth%.asUser%s*%(%s*[\"']root") or c.has("elevated%s*=%s*1")
    end },
  { "HIDES_FILES", 1, "writes hidden files", function(c)
      return c.has("fs%.open%s*%(%s*[\"'][^\"']*/%.[%w]") or c.has("fs%.makeDir%s*%(%s*[\"'][^\"']*/%.[%w]")
    end },
}

--- Combinations that are worse together than apart: { required rule ids, extra score, id, description }.
M.COMBOS = {
  { { "DOWNLOAD_AND_RUN", "WRITES_STARTUP" }, 4, "DROPPER", "downloads code and makes it start at every boot" },
  { { "OBFUSCATED_LOAD", "WRITES_STARTUP" }, 4, "HIDDEN_PERSISTENCE", "hides code and makes it start at every boot" },
  { { "COPIES_ITSELF", "WRITES_STARTUP" }, 3, "WORM", "spreads to other disks and starts by itself" },
  { { "DOWNLOAD_AND_RUN", "OBFUSCATED_LOAD" }, 3, "HIDDEN_DOWNLOAD", "downloads encoded code and runs it" },
  { { "WRITES_STARTUP", "REBOOT_LOOP" }, 3, "BOOT_TRAP", "makes the computer restart again and again" },
}

--- Run all rules over a prepared source. Returns a list of findings { id, score, description, line } and the total score.
function M.run(code, path)
  local ctx = context(code, path)
  local findings, total, fired = {}, 0, {}
  for _, r in ipairs(M.RULES) do
    local ok, hit = pcall(r[4], ctx)
    if ok and hit then
      findings[#findings + 1] = { id = r[1], score = r[2], description = r[3], line = type(hit) == "number" and hit or nil }
      total = total + r[2]
      fired[r[1]] = true
    end
  end
  for _, combo in ipairs(M.COMBOS) do
    local all = true
    for _, id in ipairs(combo[1]) do if not fired[id] then all = false end end
    if all then
      findings[#findings + 1] = { id = combo[3], score = combo[2], description = combo[4] }
      total = total + combo[2]
    end
  end
  return findings, total
end

--- The standard anti-virus test string (like EICAR for PCs): any file that contains it is reported, so you can check that the scanner works without a dangerous file.
M.TEST_STRING = "TESSERA-AV-STANDARD-" .. "TEST-FILE!$H+H*"   -- written in two pieces so that this file is not itself reported

return M
