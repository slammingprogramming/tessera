-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Measures the limits of the ComputerCraft setup Tessera is running on. Several limits are not documented and differ between
-- versions and server configurations; the measurements decide chunk sizes and fallbacks (offline paste installs, file drops, the
-- sandbox). Run `tsr-calibrate` in the game and send /var/log/calibration.json (or the printed summary) to the developers.
--   tsr-calibrate            everything that needs no help from you
--   tsr-calibrate paste      asks you to paste a long line (make one with: node tools/dev/calibration-text.mjs 4000)
--   tsr-calibrate files      asks you to drop a file onto the terminal
local M = {}

M.REPORT = "/var/log/calibration.json"

---------------------------------------------------------------------------------------------------------------------
-- Probes that run by themselves
---------------------------------------------------------------------------------------------------------------------

--- Which language and library features exist. Returns { name = true|false }.
function M.features()
  local function compiles(code) return load(code) ~= nil end
  local f = {
    goto_statement = compiles("goto x ::x::"),
    integer_division = compiles("return 7 // 2"),
    bitwise_operators = compiles("return 1 & 1"),
    bit32 = type(rawget(_G, "bit32")) == "table",
    utf8 = type(rawget(_G, "utf8")) == "table",
    string_pack = type(string.pack) == "function",
    table_move = type(table.move) == "function",
    debug_sethook = type(rawget(_G, "debug")) == "table" and type(debug.sethook) == "function",
    debug_getinfo = type(rawget(_G, "debug")) == "table" and type(debug.getinfo) == "function",
    loadstring = type(rawget(_G, "loadstring")) == "function",
    os_exit = type(os.exit) == "function",
    http = type(rawget(_G, "http")) == "table",
    websocket = type(rawget(_G, "http")) == "table" and type(http.websocket) == "function",
    palette = type(term.setPaletteColor) == "function",
    color_terminal = term.isColor(),
    speaker_audio = true,
    fs_attributes = type(fs.attributes) == "function",
    epoch_ingame = pcall(os.epoch, "ingame"),
    turtle = type(rawget(_G, "turtle")) == "table",
    pocket = type(rawget(_G, "pocket")) == "table",
    commands = type(rawget(_G, "commands")) == "table",
  }
  return f
end

--- Basic facts about this computer.
function M.facts()
  local free = fs.getFreeSpace("/")
  local capacity = fs.getCapacity and fs.getCapacity("/")
  local w, h = term.getSize()
  return {
    version = _HOST or os.version(), os_version = os.version(), lua = _VERSION, id = os.getComputerID(),
    label = os.getComputerLabel(), screen = { w, h },
    free_space = free, free_space_type = type(free), capacity = capacity, capacity_type = type(capacity),
    clock_resolution = os.clock(),
  }
end

--- How long can a program run without yielding before CC stops it? Runs a busy loop for at most `cap` seconds. Returns
--- { limited = bool, seconds = n, message = text|nil }. The default cap is 12 s: CC's limit is about 7 s.
function M.yieldLimit(cap)
  cap = cap or 12
  local start = os.clock()
  local ok, err = pcall(function()
    while os.clock() - start < cap do end
  end)
  local took = os.clock() - start
  return { limited = not ok, seconds = math.floor(took * 100) / 100, message = (not ok) and tostring(err) or nil }
end

--- Network facts without making a request.
function M.network()
  local n = { http = type(rawget(_G, "http")) == "table" }
  if n.http then
    local ok, reason = http.checkURL("https://example.com")
    n.example_allowed = ok and true or false
    n.example_reason = ok and nil or tostring(reason)
    local ok2, reason2 = http.checkURL("http://192.168.0.1")
    n.private_allowed = ok2 and true or false
    n.private_reason = ok2 and nil or tostring(reason2)
  end
  local modems = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      local wireless = false
      pcall(function() wireless = peripheral.call(name, "isWireless") end)
      modems[#modems + 1] = { name = name, wireless = wireless }
    end
  end
  n.modems = modems
  return n
end

---------------------------------------------------------------------------------------------------------------------
-- Probes that need the player
---------------------------------------------------------------------------------------------------------------------

--- The text the player should paste: `length` characters in lines-free form with a checksum-able pattern.
function M.pasteText(length)
  local alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
  local out = {}
  for i = 1, length do local k = (i - 1) % #alphabet + 1 out[i] = alphabet:sub(k, k) end
  return table.concat(out)
end

--- Check what arrived against what was sent. Returns { received, expected, intact (matches a prefix), truncated }.
function M.checkPaste(received, expectedLength)
  local expected = M.pasteText(expectedLength)
  local intact = received == expected:sub(1, #received)
  return { received = #received, expected = expectedLength, intact = intact, truncated = #received < expectedLength }
end

--- Wait for a paste event and report. `pull` is replaceable for tests. Returns the check result.
function M.measurePaste(expectedLength, pull)
  pull = pull or function() return os.pullEvent("paste") end
  local _, text = pull()
  return M.checkPaste(tostring(text or ""), expectedLength)
end

--- Wait for a file_transfer event. Returns { files = { {name, size} ... } }.
function M.measureFiles(pull)
  pull = pull or function() return os.pullEvent("file_transfer") end
  local _, transfer = pull()
  local out = { files = {} }
  if type(transfer) ~= "table" or not transfer.getFiles then return out end
  for _, file in ipairs(transfer.getFiles()) do
    local data = file.readAll and file.readAll() or ""
    out.files[#out.files + 1] = { name = file.getName and file.getName() or "?", size = #data }
    if file.close then file.close() end
  end
  return out
end

---------------------------------------------------------------------------------------------------------------------
-- Report
---------------------------------------------------------------------------------------------------------------------

local function defaultIO()
  local io = {}
  function io.say(t) print(t) end
  function io.err(t) if term.isColor() then term.setTextColor(colors.red) end print(t) term.setTextColor(colors.white) end
  return io
end

--- Run the automatic probes (and the interactive ones named in `only`). Returns the report table.
function M.collect(only, opts)
  opts = opts or {}
  local report = { when = os.epoch and os.epoch("utc") or 0, facts = M.facts(), features = M.features(), network = M.network() }
  if not only or only == "all" then report.yield = M.yieldLimit(opts.yieldCap) end
  return report
end

local function summary(report)
  local lines = {}
  local f = report.facts
  lines[#lines + 1] = ("%s / %s / computer %d"):format(tostring(f.version), tostring(f.lua), f.id)
  lines[#lines + 1] = ("screen %dx%d, free space %s (%s)"):format(f.screen[1], f.screen[2], tostring(f.free_space), f.free_space_type)
  local yes, no = {}, {}
  for k, v in pairs(report.features) do if v then yes[#yes + 1] = k else no[#no + 1] = k end end
  table.sort(yes) table.sort(no)
  lines[#lines + 1] = "has: " .. table.concat(yes, ", ")
  lines[#lines + 1] = "lacks: " .. table.concat(no, ", ")
  if report.yield then
    lines[#lines + 1] = report.yield.limited and ("yield limit: stopped after " .. report.yield.seconds .. "s (" .. tostring(report.yield.message) .. ")")
      or ("yield limit: none within " .. report.yield.seconds .. "s")
  end
  if report.paste then
    lines[#lines + 1] = ("paste: %d of %d characters%s"):format(report.paste.received, report.paste.expected, report.paste.intact and "" or " (CONTENT DIFFERS)")
  end
  if report.files then
    for _, file in ipairs(report.files.files) do lines[#lines + 1] = ("file drop: %s, %d bytes"):format(file.name, file.size) end
  end
  return lines
end
M.summary = summary

function M.run(args, io, env)
  io = io or defaultIO()
  env = env or {}
  local what = args[1] or "all"
  local report = M.collect(what, { yieldCap = env.yieldCap })
  if what == "paste" or what == "all" and args[1] == "paste" then
    local length = tonumber(args[2]) or 4000
    io.say("Paste a line of " .. length .. " characters now (make one with: node tools/dev/calibration-text.mjs " .. length .. ")")
    report.paste = M.measurePaste(length, env.pullPaste)
  elseif what == "files" then
    io.say("Drop a file onto this terminal now.")
    report.files = M.measureFiles(env.pullFiles)
  end
  local vfs = require("tsr.vfs")
  vfs.writeJSON(M.REPORT, report)
  for _, line in ipairs(summary(report)) do io.say(line) end
  io.say("Full report: " .. M.REPORT)
  return true
end

function M.main(args) return M.run(args) end

return M
