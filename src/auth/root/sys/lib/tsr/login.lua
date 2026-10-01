-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Login prompt and lock screen. Every function takes an optional `io` table so tests can drive it:
--   io.clear(), io.say(text), io.ask(prompt), io.secret(prompt), io.sleep(seconds), io.snapshot() -> restore function
local auth = require("tsr.auth")
local version = require("tsr.version")

local M = {}

local function defaultIO()
  local io = {}
  function io.clear() term.setBackgroundColor(colors.black) term.setTextColor(colors.white) term.clear() term.setCursorPos(1, 1) end
  function io.say(text) print(text) end
  function io.ask(prompt) write(prompt) return read() end
  function io.secret(prompt) write(prompt) return read("*") end
  function io.sleep(s) sleep(s) end
  --- Save what is on screen (windows only; a native terminal cannot be read back) and return a function that restores it.
  function io.snapshot()
    local t = term.current()
    if not t.getLine then return function() end end
    local w, h = t.getSize()
    local rows = {}
    for y = 1, h do rows[y] = table.pack(t.getLine(y)) end
    local cx, cy = t.getCursorPos()
    return function()
      for y = 1, h do
        local r = rows[y]
        if r and r[1] then t.setCursorPos(1, y) t.blit(r[1], r[2], r[3]) end
      end
      t.setCursorPos(cx, cy)
    end
  end
  return io
end

local function hostname()
  return (rawget(_G, "tsr") and tsr.hostname and tsr.hostname()) or os.getComputerLabel() or ("cc-" .. os.getComputerID())
end

--- Ask for credentials until they are right. Returns the user (public view); with opts.attempts, gives up with nil after that
--- many failures. The user becomes the session user of the calling process.
function M.run(opts)
  opts = opts or {}
  local io = opts.io or defaultIO()
  local failures = 0
  while true do
    io.clear()
    io.say(version.name .. " " .. version.version .. " - " .. hostname())
    io.say("")
    local name = io.ask("login: ")
    if name == nil then return nil end
    local pass = io.secret("password: ")
    local user, why, count = auth.verify(name, pass or "")
    if user then
      auth.setSessionUser(name)
      return user
    end
    failures = failures + 1
    io.say(why == "locked" and "This account is locked." or "Login incorrect.")
    if opts.attempts and failures >= opts.attempts then return nil end
    io.sleep(math.min(10, count or failures))
  end
end

--- Hide the screen until the current user's password is typed. Returns true once unlocked.
function M.lock(opts)
  opts = opts or {}
  local io = opts.io or defaultIO()
  local name = auth.current()
  if not name or name == auth.ROOT then return false, "nobody is logged in" end
  local restore = io.snapshot()
  local failures = 0
  while true do
    io.clear()
    io.say("Locked: " .. name .. " - " .. hostname())
    io.say("")
    local pass = io.secret("password: ")
    if pass == nil then return false, "cancelled" end
    if auth.verify(name, pass) then
      restore()
      return true
    end
    failures = failures + 1
    io.say("Wrong password.")
    if opts.attempts and failures >= opts.attempts then return false, "too many attempts" end
    io.sleep(math.min(10, failures))
  end
end

return M
