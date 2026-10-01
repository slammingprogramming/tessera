-- SPDX-License-Identifier: AGPL-3.0-or-later
-- tsh interactive loop: prompt, history, completion, multi-line input, startup files.
local exec = require("tsr.shell.exec")

local M = {}

local PROFILE = "/etc/tsr/profile.tsh"
local MAX_HISTORY_FILE = 200

local function readFile(path)
  if not fs.exists(path) or fs.isDir(path) then return nil end
  local h = fs.open(path, "r")
  local s = h.readAll() or ""
  h.close()
  return s
end

local function historyPath(sh)
  local home = sh.vars.HOME or "/"
  return (home == "/" and "" or home) .. "/.tsh_history"
end

local function loadHistory(sh)
  local text = readFile(historyPath(sh))
  if not text then return end
  for line in text:gmatch("[^\n]+") do sh:addHistory(line) end
end

local function saveHistory(sh)
  local list = sh.history
  local from = math.max(1, #list - MAX_HISTORY_FILE + 1)
  local h = fs.open(historyPath(sh), "w")
  if not h then return end
  for i = from, #list do h.writeLine(list[i]) end
  h.close()
end

--- Expand the prompt string: \w working directory, \u user, \h host, \$ "$", \n newline.
function M.prompt(sh, which)
  local ps = which == 2 and (sh.vars.PS2 or "> ") or sh.vars.PS1 or "\\w> "
  return (ps:gsub("\\(.)", function(c)
    if c == "w" then return "/" .. sh.dir
    elseif c == "u" then return sh.vars.USER or ""
    elseif c == "h" then return sh.vars.HOSTNAME or ""
    elseif c == "$" then return "$"
    elseif c == "n" then return "\n"
    elseif c == "\\" then return "\\"
    end
    return "\\" .. c
  end))
end

local function sourceIfExists(sh, path)
  local text = readFile(path)
  if text then sh:runScript(text, path, {}) end
end

--- Run the interactive loop on `sh` until it exits. opts: read (function(history, completeFn) -> line | nil, for tests),
--- noRc (skip profile and rc files).
function M.run(sh, opts)
  opts = opts or {}
  sh.interactive = true
  if not opts.noRc then
    sourceIfExists(sh, PROFILE)
    sourceIfExists(sh, (sh.vars.HOME == "/" and "" or sh.vars.HOME) .. "/.tshrc")
  end
  loadHistory(sh)
  local reader = opts.read or function(history, completeFn) return read(nil, history, completeFn) end
  local completeFn = function(line) return sh.api.complete(line) end
  local sinceSave = 0

  while not sh.exiting do
    local color = term.isColor and term.isColor()
    if color then term.setTextColor(colors.yellow) end
    write(M.prompt(sh, 1))
    if color then term.setTextColor(colors.white) end
    local ok, line = pcall(reader, sh.history, completeFn)
    if not ok then
      if line == "Terminated" then print() line = "" else error(line, 0) end
    end
    if line == nil then break end
    local buffer = line
    -- keep reading while the command is syntactically unfinished (open if/for/while or quote)
    while true do
      local ast, err, incomplete = require("tsr.shell.parse").parse(buffer)
      if ast or not incomplete then break end
      write(M.prompt(sh, 2))
      local more = reader({}, nil)
      if more == nil then break end
      buffer = buffer .. "\n" .. more
    end
    if buffer:match("%S") then
      sh:addHistory(buffer:gsub("\n", "; "))
      sinceSave = sinceSave + 1
      if sinceSave >= 20 then saveHistory(sh) sinceSave = 0 end
      local ranOk, e = pcall(sh.runLine, sh, buffer)
      if not ranOk then
        if e ~= "Terminated" then sh:err(tostring(e)) end
        sh.signal = nil
      end
    end
  end
  saveHistory(sh)
  return sh.exitCode
end

--- The default interactive session (used by the kernel). opts: parentShell.
function M.session(opts)
  opts = opts or {}
  local sh = exec.new({ parentShell = opts.parentShell, home = opts.home, user = opts.user })
  return M.run(sh, opts)
end

return M
