-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Cron: run commands on a schedule. The table lives in /etc/tsr/cron.tab, one job per line:
--     every 10m   rs set top on          every <n>s|m|h|d   (real time, from when the scheduler started)
--     at 06:00    tsr-backup             every day at that in-game time
--     daily 03:30 tsr-backup             every day at that WALL-CLOCK time (system time zone, see the ntp package)
--     weekly mon 06:00 pkg update        every week on that day (sun mon tue wed thu fri sat)
--     boot        svc start netd         once when the scheduler starts
--   Lines starting with # are comments.
-- Commands run in a tsh session (or the CraftOS shell without tsh) inside their own process with a time limit;
-- what they print goes to /var/log/cron.log.
local vfs = require("tsr.vfs")
local log = require("tsr.log").get("cron")

local M = {}

M.TAB_PATH = "/etc/tsr/cron.tab"
M.LOG_PATH = "/var/log/cron.log"
M.LOG_MAX = 20000
M.TIMEOUT = 60

---------------------------------------------------------------------------------------------------------------------
-- Table
---------------------------------------------------------------------------------------------------------------------

local UNITS = { s = 1, m = 60, h = 3600, d = 86400 }
local WEEKDAYS = { sun = 0, mon = 1, tue = 2, wed = 3, thu = 4, fri = 5, sat = 6 }

--- Parse one line. Returns a job { kind, seconds | hour, command, text } or nil + error. Blank/comment lines return false.
function M.parseLine(line)
  line = line:gsub("^%s+", ""):gsub("%s+$", "")
  if line == "" or line:sub(1, 1) == "#" then return false end
  local kind, rest = line:match("^(%a+)%s+(.*)$")
  if line == "boot" then return nil, "boot needs a command" end
  if kind == "boot" then
    return { kind = "boot", command = rest, text = line }
  elseif kind == "every" then
    local n, unit, cmd = rest:match("^(%d+)([smhd])%s+(.+)$")
    if not n then return nil, "expected: every <number><s|m|h|d> <command>" end
    local seconds = tonumber(n) * UNITS[unit]
    if seconds < 1 then return nil, "interval must be at least 1 second" end
    return { kind = "every", seconds = seconds, command = cmd, text = line }
  elseif kind == "at" then
    local h, m, cmd = rest:match("^(%d%d?):(%d%d)%s+(.+)$")
    h, m = tonumber(h), tonumber(m)
    if not h or h > 23 or m > 59 then return nil, "expected: at HH:MM <command> (in-game time)" end
    return { kind = "at", hour = h + m / 60, command = cmd, text = line }
  elseif kind == "daily" then
    local h, m, cmd = rest:match("^(%d%d?):(%d%d)%s+(.+)$")
    h, m = tonumber(h), tonumber(m)
    if not h or h > 23 or m > 59 then return nil, "expected: daily HH:MM <command> (wall-clock time)" end
    return { kind = "daily", minute = h * 60 + m, command = cmd, text = line }
  elseif kind == "weekly" then
    local day, h, m, cmd = rest:match("^(%a%a%a)%s+(%d%d?):(%d%d)%s+(.+)$")
    local wd = day and WEEKDAYS[day:lower()]
    h, m = tonumber(h), tonumber(m)
    if not wd or not h or h > 23 or m > 59 then return nil, "expected: weekly <sun|mon|...|sat> HH:MM <command>" end
    return { kind = "weekly", weekday = wd, minute = h * 60 + m, command = cmd, text = line }
  end
  return nil, "unknown schedule '" .. tostring(kind) .. "' (use every, at, daily, weekly or boot)"
end

--- Read the table. Returns jobs, problems (strings).
function M.load()
  local text = vfs.readFile(M.TAB_PATH) or ""
  local jobs, problems = {}, {}
  local n = 0
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    n = n + 1
    local job, err = M.parseLine(line)
    if job then jobs[#jobs + 1] = job
    elseif job == nil then problems[#problems + 1] = "line " .. n .. ": " .. err end
  end
  return jobs, problems
end

local function saveLines(lines)
  return vfs.writeFile(M.TAB_PATH, table.concat(lines, "\n") .. (#lines > 0 and "\n" or ""))
end

local function readLines()
  local out = {}
  local text = vfs.readFile(M.TAB_PATH) or ""
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do out[#out + 1] = line end
  while #out > 0 and out[#out] == "" do out[#out] = nil end
  return out
end

function M.add(line)
  local job, err = M.parseLine(line)
  if job == nil then return nil, err end
  if job == false and line:match("^%s*$") then return nil, "empty line" end
  local lines = readLines()
  lines[#lines + 1] = line
  saveLines(lines)
  return true
end

--- Remove the nth job (counting only real jobs, as `crontab list` numbers them).
function M.remove(n)
  local lines, jobNo = readLines(), 0
  for i, line in ipairs(lines) do
    if M.parseLine(line) then
      jobNo = jobNo + 1
      if jobNo == n then
        table.remove(lines, i)
        saveLines(lines)
        return true
      end
    end
  end
  return nil, "no job number " .. tostring(n)
end

---------------------------------------------------------------------------------------------------------------------
-- Scheduler
---------------------------------------------------------------------------------------------------------------------

--- Time source: { seconds = real seconds, hour = in-game hour 0-24, day = in-game day number, minute/weekday/date = wall-clock time in
--- the system time zone (from the ntp package's clock when it is installed) }.
function M.now()
  local okT, time = pcall(require, "tsr.time")
  local ms = (okT and time.now()) or (os.epoch and os.epoch("utc")) or os.clock() * 1000
  local now = { seconds = ms / 1000, hour = os.time("ingame"), day = os.day("ingame") }
  if okT then                                   -- wall-clock fields exist only with the ntp package (it owns time zones)
    local offset = time.offsetAt(time.currentZone(), math.floor(ms / 1000))
    local y, mo, d, h, mi, _, wd = time.fields(math.floor(ms / 1000) + offset * 60)
    now.minute, now.weekday, now.date = h * 60 + mi, wd, y * 10000 + mo * 100 + d
  end
  return now
end

--- Does `job` need to run at `now`? state is the job's memory ({ last = seconds, lastDay = n, ran = bool }) and is updated.
function M.due(job, now, state)
  if job.kind == "boot" then
    if state.ran then return false end
    state.ran = true
    return true
  elseif job.kind == "every" then
    if state.last == nil then state.last = now.seconds return false end   -- first run one interval after start
    if now.seconds - state.last >= job.seconds then
      state.last = now.seconds
      return true
    end
    return false
  elseif job.kind == "at" then
    if now.hour >= job.hour and state.lastDay ~= now.day then
      -- do not fire for a time that long passed before the scheduler began (e.g. started at 22:00 for an 06:00 job)
      if state.lastDay == nil and now.hour - job.hour > 0.25 then
        state.lastDay = now.day
        return false
      end
      state.lastDay = now.day
      return true
    end
    return false
  elseif job.kind == "daily" or job.kind == "weekly" then
    if now.minute == nil then return false end
    if job.kind == "weekly" and now.weekday ~= job.weekday then return false end
    if now.minute >= job.minute and state.lastDate ~= now.date then
      -- do not fire for a time that passed long before the scheduler began
      local missed = state.lastDate == nil and now.minute - job.minute > 5
      state.lastDate = now.date
      return not missed
    end
    return false
  end
  return false
end

local function appendLog(text)
  local old = vfs.readFile(M.LOG_PATH) or ""
  local new = old .. text
  if #new > M.LOG_MAX then new = new:sub(-M.LOG_MAX) end
  vfs.writeFile(M.LOG_PATH, new)
end

--- Run one command line now. Returns status, output.
function M.run(command, timeout)
  local okExec, exec = pcall(require, "tsr.shell.exec")
  local sh
  if okExec then
    sh = exec.new({ parentShell = rawget(_G, "shell"), home = "/" })
  else
    sh = { runLine = function(_, line) return shell.run(line) and 0 or 1 end, withIO = function(self, _, cap, fn) return fn() end }
  end
  local rsh_like = okExec and require("tsr.shell.capture")
  local okK, kernel = pcall(require, "tsr.kernel")
  if okExec and okK and kernel.isRunning and kernel.isRunning() then
    local cap = rsh_like.new()
    local status = 1
    local pid = kernel.spawn({ name = "cron-job", term = cap.term, daemon = true, fn = function() status = sh:runLine(command) end })
    local timedOut = false
    if pid then
      local timer = os.startTimer(timeout or M.TIMEOUT)
      while kernel.get(pid) do
        local ev, id = os.pullEvent()
        if ev == "timer" and id == timer then kernel.kill(pid) timedOut = true end
      end
    end
    return status, cap.text() .. (timedOut and "\n[stopped: took too long]" or "")
  end
  if okExec then
    local status, out = sh:withIO("", true, function() return sh:runLine(command) end)
    return status, out or ""
  end
  return sh:runLine(command), ""
end

--- Check every job once and run those that are due. Returns the number started.
function M.tick(jobs, states, now)
  local started = 0
  for i, job in ipairs(jobs) do
    states[i] = states[i] or {}
    if M.due(job, now or M.now(), states[i]) then
      started = started + 1
      local status, out = M.run(job.command)
      log.info("ran '%s' (status %s)", job.command, tostring(status))
      appendLog(("[%s] %s -> %s\n%s%s"):format(require("tsr.util").timestamp(), job.command, tostring(status), out or "",
        (out and out ~= "" and out:sub(-1) ~= "\n") and "\n" or ""))
    end
  end
  return started
end

--- The crond service: re-reads the table whenever it changes.
function M.daemon()
  local jobs, states, stamp = {}, {}, nil
  while true do
    local size = fs.exists(M.TAB_PATH) and fs.getSize(M.TAB_PATH) or -1
    if size ~= stamp then
      stamp = size
      local problems
      jobs, problems = M.load()
      states = {}
      for _, p in ipairs(problems) do log.warn("cron.tab %s", p) end
    end
    M.tick(jobs, states)
    sleep(1)
  end
end

---------------------------------------------------------------------------------------------------------------------
-- crontab command
---------------------------------------------------------------------------------------------------------------------

local function defaultIO()
  local io = {}
  local function color(c) if term.isColor() then term.setTextColor(c) end end
  function io.say(t) print(t) end
  function io.err(t) color(colors.red) print(t) color(colors.white) end
  return io
end

--- crontab list | add <schedule line...> | remove <n> | run <n> | log
function M.crontab(args, io)
  io = io or defaultIO()
  local cmd = args[1] or "list"
  if cmd == "list" then
    local jobs, problems = M.load()
    if #jobs == 0 then io.say("No jobs. Example: crontab add every 10m rs set top on") end
    for i, j in ipairs(jobs) do io.say(i .. ". " .. j.text) end
    for _, p in ipairs(problems) do io.err(p) end
    return #problems == 0
  elseif cmd == "add" then
    local ok, err = M.add(table.concat(args, " ", 2))
    if not ok then io.err(tostring(err)) return false end
    io.say("Added.")
    return true
  elseif cmd == "remove" then
    local ok, err = M.remove(tonumber(args[2]) or -1)
    if not ok then io.err(tostring(err)) return false end
    io.say("Removed.")
    return true
  elseif cmd == "run" then
    local jobs = M.load()
    local job = jobs[tonumber(args[2]) or -1]
    if not job then io.err("no such job") return false end
    local status, out = M.run(job.command)
    if out and out ~= "" then io.say(out) end
    io.say("status " .. tostring(status))
    return status == 0
  elseif cmd == "log" then
    local text = vfs.readFile(M.LOG_PATH) or ""
    io.say(text == "" and "The log is empty." or text:sub(-1500))
    return true
  end
  io.err("usage: crontab list | add <every|at|boot ...> | remove <n> | run <n> | log")
  return false
end

return M
