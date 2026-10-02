-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Built-in manuals and the first-run tour.
--   thelp                 menu of topics         thelp <topic>      show one (a prefix is enough)
--   thelp search <word>   topics that mention it      tsr-tour       a short guided introduction
-- Topics are text files /usr/share/help/<order>-<id>.txt: the first line is the title, the rest is the body. Other packages can
-- add their own files there.
local M = {}

M.DIR = "/usr/share/help"
M.TOUR_DONE = "/etc/tsr/tour.done"

local function readFile(path)
  local h = fs.open(path, "r")
  if not h then return nil end
  local s = h.readAll()
  h.close()
  return s
end

--- All topics in order: { id, title, text, file }.
function M.topics()
  local out = {}
  if not fs.isDir(M.DIR) then return out end
  local names = fs.list(M.DIR)
  table.sort(names)
  for _, f in ipairs(names) do
    local id = f:match("^%d*%-?(.-)%.txt$")
    if id and id ~= "" then
      local text = readFile(M.DIR .. "/" .. f) or ""
      local title, body = text:match("^([^\n]*)\n?(.*)$")
      out[#out + 1] = { id = id, title = title or id, text = body or "", file = f }
    end
  end
  return out
end

--- Topic by id or unambiguous prefix.
function M.find(name)
  local list = M.topics()
  for _, t in ipairs(list) do if t.id == name then return t end end
  local match
  for _, t in ipairs(list) do
    if t.id:sub(1, #name) == name then
      if match then return nil, "several topics start with '" .. name .. "'" end
      match = t
    end
  end
  if match then return match end
  return nil, "no topic called '" .. name .. "'"
end

--- Topics (and the matching lines) that mention `word`, case-insensitively.
function M.search(word)
  local out = {}
  word = word:lower()
  for _, t in ipairs(M.topics()) do
    local hits = {}
    for line in (t.title .. "\n" .. t.text):gmatch("[^\n]+") do
      if line:lower():find(word, 1, true) then hits[#hits + 1] = (line:gsub("^%s+", "")) end
    end
    if #hits > 0 then out[#out + 1] = { topic = t, lines = hits } end
  end
  return out
end

--- Cut text into lines that fit `width`.
function M.layout(text, width)
  local lines = {}
  for raw in (text .. "\n"):gmatch("(.-)\n") do
    local indent = raw:match("^%s*")
    local rest = raw:sub(#indent + 1)
    if rest == "" then
      lines[#lines + 1] = ""
    else
      local line = indent
      for word in rest:gmatch("%S+") do
        if #line + #word + (line == indent and 0 or 1) > width and line ~= indent then
          lines[#lines + 1] = line
          line = indent .. word
        else
          line = line .. (line == indent and "" or " ") .. word
        end
      end
      lines[#lines + 1] = line
    end
  end
  while #lines > 0 and lines[#lines] == "" do lines[#lines] = nil end
  return lines
end

--- Show lines one screen at a time (Space/PageDown next, Up/Down scroll, q leaves). io.* lets tests drive it.
function M.pager(title, lines, io)
  io = io or {}
  local w, h = term.getSize()
  local top = 1
  local body = h - 2
  local function draw()
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(term.isColor() and colors.yellow or colors.white)
    write(title:sub(1, w))
    term.setTextColor(colors.white)
    for i = 1, body do
      term.setCursorPos(1, i + 1)
      local l = lines[top + i - 1]
      if l then write(l:sub(1, w)) end
    end
    term.setCursorPos(1, h)
    term.setTextColor(colors.lightGray)
    write(("q quit  Up/Down scroll  Space next  (%d%%)"):format(math.min(100, math.floor((top + body - 1) / math.max(1, #lines) * 100))):sub(1, w))
    term.setTextColor(colors.white)
  end
  local pull = io.pull or function() return os.pullEvent() end
  while true do
    draw()
    local ev, a, b2, c = pull()
    if ev == "key" then
      if a == keys.q or a == keys.backspace then break
      elseif a == keys.down then top = math.min(math.max(1, #lines - body + 1), top + 1)
      elseif a == keys.up then top = math.max(1, top - 1)
      elseif a == keys.space or a == keys.pageDown then
        if top + body > #lines then break end
        top = math.min(#lines, top + body)
      elseif a == keys.pageUp then top = math.max(1, top - body)
      elseif a == keys.home then top = 1
      elseif a == keys["end"] then top = math.max(1, #lines - body + 1) end
    elseif ev == "char" and a == "q" then break
    elseif ev == "mouse_scroll" then
      top = math.max(1, math.min(math.max(1, #lines - body + 1), top + a))
    end
  end
  term.clear()
  term.setCursorPos(1, 1)
end

--- opts: ui (tui module), pager (function(title, lines))
function M.run(args, io, opts)
  io = io or { say = print, err = function(t) printError(t) end }
  opts = opts or {}
  local pager = opts.pager or function(title, lines) M.pager(title, lines) end
  local w = select(1, term.getSize())
  local first = args[1]
  if first == "search" then
    local word = args[2]
    if not word then io.err("usage: thelp search <word>") return false end
    local results = M.search(word)
    if #results == 0 then io.say("Nothing found for '" .. word .. "'.") return true end
    for _, r in ipairs(results) do
      io.say(r.topic.id .. "  -  " .. r.topic.title)
      for i = 1, math.min(3, #r.lines) do io.say("    " .. r.lines[i]:sub(1, w - 5)) end
    end
    return true
  elseif first then
    local topic, err = M.find(first)
    if not topic then io.err(err) return false end
    pager(topic.title, M.layout(topic.text, w - 1))
    return true
  end
  -- no argument: a menu of topics
  local ui = opts.ui or require("tsr.ui.tui")
  local topics = M.topics()
  if #topics == 0 then io.say("No manual pages are installed.") return true end
  local items = {}
  for i, t in ipairs(topics) do items[i] = { label = t.title, desc = t.id } end
  while true do
    local pick = ui.menu("Tessera manual", items)
    if not pick then return true end
    pager(topics[pick].title, M.layout(topics[pick].text, w - 1))
  end
end

function M.main(args) return M.run(args) end

---------------------------------------------------------------------------------------------------------------------
-- Tour
---------------------------------------------------------------------------------------------------------------------

M.TOUR = {
  { "Welcome to Tessera", { "A small core, with everything else a package you choose.", "This tour takes about a minute." } },
  { "The shell", { "Programs run as before, and pipes and scripts work: `list | grep lua`.", "Press Tab to complete, Up for history." } },
  { "Packages", { "`pkg search` shows what is available, `pkg install <name>` adds it.", "Nothing is installed twice and installs roll back on failure." } },
  { "Getting help", { "`thelp` opens the manual, `thelp search <word>` finds text.", "`tsr-setup` re-runs the wizard that recommends packages." } },
  { "Safe to explore", { "Hold R at boot for the recovery menu.", "Replaced files are always backed up in /etc/tsr/backup." } },
}

--- Walk through the tour screens. opts.ui for tests. Returns true when it was shown to the end.
function M.tour(opts)
  opts = opts or {}
  local ui = opts.ui or require("tsr.ui.tui")
  for i, page in ipairs(M.TOUR) do
    local lines = { table.unpack(page[2]) }
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("(%d of %d)"):format(i, #M.TOUR)
    ui.message(page[1], lines)
  end
  local h = fs.open(M.TOUR_DONE, "w")
  if h then h.write("done") h.close() end
  return true
end

function M.tourDone() return fs.exists(M.TOUR_DONE) end

function M.tourMain() return M.tour() end

return M
