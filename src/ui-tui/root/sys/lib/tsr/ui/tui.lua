-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Text UI toolkit. Keyboard-first (works on basic computers, turtles and pocket computers), with mouse support where
-- the terminal has it. Colours degrade to black/white/gray on basic screens. All screens are drawn on the current
-- terminal, so they also work inside windows (tests redirect term to a window and inspect it).
--   tui.menu(title, items, opts)       -> index | nil (Backspace)
--   tui.checklist(title, items, opts)  -> { [id] = bool } | nil (Backspace)
--   tui.confirm(title, lines, opts)    -> boolean
--   tui.message(title, lines)          tui.input(title, prompt, default)   tui.bar(y, fraction)
local M = {}

---------------------------------------------------------------------------------------------------------------------
-- Theme and drawing helpers
---------------------------------------------------------------------------------------------------------------------

local function theme()
  if term.isColor() then
    return { fg = colors.white, bg = colors.black, title_fg = colors.black, title_bg = colors.lightBlue,
             sel_fg = colors.white, sel_bg = colors.blue, dim = colors.lightGray, good = colors.lime,
             warn = colors.orange, bad = colors.red, accent = colors.yellow }
  end
  return { fg = colors.white, bg = colors.black, title_fg = colors.black, title_bg = colors.white,
           sel_fg = colors.black, sel_bg = colors.white, dim = colors.lightGray, good = colors.white,
           warn = colors.white, bad = colors.white, accent = colors.white }
end
M.theme = theme

--- Cut `s` to `w` characters (with ".." when cut) and pad with spaces to exactly `w`.
local function fit(s, w)
  s = tostring(s)
  if #s > w then s = w > 2 and (s:sub(1, w - 2) .. "..") or s:sub(1, w) end
  return s .. string.rep(" ", w - #s)
end
M.fit = fit

--- Word-wrap `text` to `width` columns. Returns an array of lines.
function M.wrap(text, width)
  local lines = {}
  for para in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do
    local line = ""
    for word in para:gmatch("%S+") do
      if #word > width then
        if line ~= "" then lines[#lines + 1] = line line = "" end
        while #word > width do lines[#lines + 1] = word:sub(1, width) word = word:sub(width + 1) end
        line = word
      elseif line == "" then
        line = word
      elseif #line + 1 + #word <= width then
        line = line .. " " .. word
      else
        lines[#lines + 1] = line
        line = word
      end
    end
    lines[#lines + 1] = line
  end
  return lines
end

local function setColors(fg, bg)
  term.setTextColor(fg)
  term.setBackgroundColor(bg)
end

local function writeAt(x, y, text, fg, bg)
  term.setCursorPos(x, y)
  setColors(fg, bg)
  term.write(text)
end

--- Clear the screen and draw the title bar. Returns width, height.
function M.frame(title)
  local t = theme()
  local w, h = term.getSize()
  setColors(t.fg, t.bg)
  term.clear()
  writeAt(1, 1, fit(" " .. title, w), t.title_fg, t.title_bg)
  term.setCursorBlink(false)
  return w, h
end

local function footer(text)
  local t = theme()
  local w, h = term.getSize()
  writeAt(1, h, fit(text, w), t.dim, t.bg)
end

local function drawLines(lines, x, y, w, maxY, fg)
  local t = theme()
  for _, l in ipairs(lines) do
    if y > maxY then break end
    writeAt(x, y, fit(l, w), fg or t.fg, t.bg)
    y = y + 1
  end
  return y
end

--- Draw a progress bar on row y. fraction 0..1.
function M.bar(y, fraction, label)
  local t = theme()
  local w = term.getSize()
  local inner = w - 2
  local filled = math.floor(inner * math.max(0, math.min(1, fraction)) + 0.5)
  writeAt(1, y, "[", t.dim, t.bg)
  writeAt(2, y, string.rep(" ", filled), t.sel_fg, t.sel_bg)
  writeAt(2 + filled, y, string.rep("-", inner - filled), t.dim, t.bg)
  writeAt(w, y, "]", t.dim, t.bg)
  if label then writeAt(1, y + 1, fit(label, w), t.fg, t.bg) end
end

--- Pull the next event; Ctrl+T aborts the whole screen with the usual "Terminated" error.
local function nextEvent()
  local ev = table.pack(os.pullEventRaw())
  if ev[1] == "terminate" then error("Terminated", 0) end
  return ev
end

---------------------------------------------------------------------------------------------------------------------
-- Selection list (shared by menu and checklist)
---------------------------------------------------------------------------------------------------------------------

local function nextEnabled(items, i, dir)
  local n = #items
  for _ = 1, n do
    i = i + dir
    if i < 1 then i = n elseif i > n then i = 1 end
    if not items[i].disabled then return i end
  end
  return i
end

--- Generic list screen. opts: header (string), initial, checks (map id->bool, enables checklist mode), footer.
local function listScreen(title, items, opts)
  opts = opts or {}
  local checks = opts.checks
  local sel = opts.initial or 1
  if items[sel] and items[sel].disabled then sel = nextEnabled(items, sel, 1) end
  local top = 1
  while true do
    local t = theme()
    local w, h = M.frame(title)
    local y = 3
    if opts.header then y = drawLines(M.wrap(opts.header, w - 2), 2, y, w - 2, h - 5, t.dim) + 1 end
    -- description area at the bottom: up to 3 lines
    local descLines = {}
    if items[sel] and items[sel].desc then descLines = M.wrap(items[sel].desc, w - 2) end
    local descH = math.min(#descLines, 3)
    local listTop, listBottom = y, h - 2 - descH
    local rows = math.max(1, listBottom - listTop + 1)
    if sel < top then top = sel elseif sel >= top + rows then top = sel - rows + 1 end
    for i = top, math.min(#items, top + rows - 1) do
      local it = items[i]
      local row = listTop + (i - top)
      local mark = ""
      if checks then mark = checks[it.id] and "[x] " or "[ ] " end
      local label = mark .. it.label
      local tag = it.tag and (" " .. it.tag) or ""
      local text = fit(" " .. label, w - #tag) .. tag
      if i == sel then
        writeAt(1, row, text, t.sel_fg, t.sel_bg)
      elseif it.disabled then
        writeAt(1, row, text, t.dim, t.bg)
      else
        writeAt(1, row, text, (it.tier == "recommended" and t.good) or t.fg, t.bg)
      end
    end
    if top > 1 then writeAt(w, listTop, "^", t.accent, t.bg) end
    if top + rows - 1 < #items then writeAt(w, listBottom, "v", t.accent, t.bg) end
    drawLines(descLines, 2, h - 1 - descH, w - 2, h - 2, t.dim)
    footer(opts.footer or (checks and "Up/Down move  Space toggle  Enter done  Bksp back" or "Up/Down move  Enter select  Bksp back"))

    local ev = nextEvent()
    local name, a = ev[1], ev[2]
    if name == "key" then
      if a == keys.up then sel = nextEnabled(items, sel, -1)
      elseif a == keys.down then sel = nextEnabled(items, sel, 1)
      elseif a == keys.pageUp then sel = math.max(1, sel - rows)
      elseif a == keys.pageDown then sel = math.min(#items, sel + rows)
      elseif a == keys.home then sel = 1
      elseif a == keys["end"] then sel = #items
      elseif a == keys.space and checks and not items[sel].disabled then
        checks[items[sel].id] = not checks[items[sel].id]
      elseif a == keys.enter then
        if not items[sel].disabled or checks then return sel, checks end
      elseif a == keys.backspace then
        return nil
      end
    elseif name == "char" and checks then
      if a == "a" then for _, it in ipairs(items) do if not it.disabled then checks[it.id] = true end end
      elseif a == "n" then for _, it in ipairs(items) do if not it.disabled then checks[it.id] = false end end end
    elseif name == "char" and not checks and a:match("^[1-9]$") and items[tonumber(a)] and not items[tonumber(a)].disabled then
      return tonumber(a)
    elseif name == "mouse_click" then
      local row = ev[4]
      local i = top + (row - listTop)
      if row >= listTop and i >= 1 and i <= #items and i < top + rows and not items[i].disabled then
        if checks then
          if sel == i then checks[items[i].id] = not checks[items[i].id] end
          sel = i
        else
          return i
        end
      end
    elseif name == "mouse_scroll" then
      sel = nextEnabled(items, sel, ev[2])
    end
  end
end

--- Single choice. items: { {label, desc?, disabled?, tag?, tier?} }. Returns the chosen index or nil (Backspace).
function M.menu(title, items, opts)
  return (listScreen(title, items, opts))
end

--- Multiple choice. items: { {id, label, desc?, disabled?, tag?, tier?} }; opts.checked = { [id] = true }.
--- Returns { [id] = bool } or nil (Backspace).
function M.checklist(title, items, opts)
  opts = opts or {}
  local checks = {}
  for _, it in ipairs(items) do checks[it.id] = (opts.checked or {})[it.id] and true or false end
  local o = { header = opts.header, footer = opts.footer, checks = checks, initial = opts.initial }
  local sel = listScreen(title, items, o)
  if not sel then return nil end
  return checks
end

---------------------------------------------------------------------------------------------------------------------
-- Simple dialogs
---------------------------------------------------------------------------------------------------------------------

local function textScreen(title, lines, hint)
  local t = theme()
  local w, h = M.frame(title)
  local wrapped = {}
  for _, l in ipairs(type(lines) == "table" and lines or { lines }) do
    for _, piece in ipairs(M.wrap(l, w - 2)) do wrapped[#wrapped + 1] = piece end
  end
  drawLines(wrapped, 2, 3, w - 2, h - 2)
  footer(hint)
  return w, h
end

--- Show text and wait for a key.
function M.message(title, lines)
  textScreen(title, lines, "Press any key")
  while true do
    local ev = nextEvent()
    if ev[1] == "key" or ev[1] == "mouse_click" then return end
  end
end

--- Yes/No question. opts.default (bool). Returns true/false.
function M.confirm(title, lines, opts)
  opts = opts or {}
  local yes = opts.default
  if yes == nil then yes = true end
  while true do
    local t = theme()
    local w, h = textScreen(title, lines, "Left/Right choose  Enter accept  Y / N")
    local yLabel, nLabel = "  Yes  ", "  No  "
    local bx = 3
    writeAt(bx, h - 2, yLabel, yes and t.sel_fg or t.fg, yes and t.sel_bg or t.bg)
    writeAt(bx + #yLabel + 2, h - 2, nLabel, (not yes) and t.sel_fg or t.fg, (not yes) and t.sel_bg or t.bg)
    local ev = nextEvent()
    if ev[1] == "key" then
      if ev[2] == keys.left or ev[2] == keys.right or ev[2] == keys.tab then yes = not yes
      elseif ev[2] == keys.enter then return yes end
    elseif ev[1] == "char" then
      local c = ev[2]:lower()
      if c == "y" then return true elseif c == "n" then return false end
    elseif ev[1] == "mouse_click" and ev[4] == h - 2 then
      if ev[3] >= bx and ev[3] < bx + #yLabel then return true end
      if ev[3] >= bx + #yLabel + 2 and ev[3] < bx + #yLabel + 2 + #nLabel then return false end
    end
  end
end

--- Ask for a line of text. Returns the string (possibly empty).
function M.input(title, prompt, default)
  local t = theme()
  local w, h = textScreen(title, { prompt }, "Enter to accept")
  setColors(t.fg, t.bg)
  term.setCursorPos(2, 6)
  term.setCursorBlink(true)
  local value = read(nil, nil, nil, default)
  term.setCursorBlink(false)
  return value
end

--- One-line status message at the bottom of a frame (used while work is in progress).
function M.status(text)
  local t = theme()
  local w, h = term.getSize()
  writeAt(1, h - 1, fit(text, w), t.accent, t.bg)
end

return M
