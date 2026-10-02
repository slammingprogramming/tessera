-- SPDX-License-Identifier: AGPL-3.0-or-later
-- A text web browser for the in-game web (and for local HTML files).
--   www [url]          Up/Down/PgUp/PgDn scroll, Tab / Shift+Tab pick a link, Enter follows it (or click it), Backspace goes back, G types an address,
--                      R reloads, S saves the page, Q quits
local msg = require("tsr.inet.http.message")
local html = require("tsr.inet.http.html")
local client = require("tsr.inet.http.client")
local vfs = require("tsr.vfs")

local M = {}

M.COLORS = { text = "white", bold = "yellow", italic = "lightGray", head = "lime", code = "cyan", link = "lightBlue" }

--- Fetch and lay out a page. Returns a page table { url, status, title, lines, links, type, body } or nil + reason.
function M.load(url, width, opts)
  opts = opts or {}
  local resp, err
  local localPath = url:match("^file://(.*)$")
  if localPath then
    local data = vfs.readFile(localPath, true)
    if not data then return nil, "cannot read " .. localPath end
    resp = { status = 200, headers = { ["content-type"] = msg.mimeOf(localPath) }, body = data, url = url }
  elseif url:match("^%a[%w+.-]*://") then
    resp, err = client.get(url, { stack = opts.stack, timeout = opts.timeout or 10 })
  else
    resp, err = client.get("http://" .. url, { stack = opts.stack, timeout = opts.timeout or 10 })
    if resp then url = "http://" .. url end
  end
  if not resp then return nil, err end
  local ctype = (resp.headers["content-type"] or ""):lower()
  local page
  if ctype:find("text/html", 1, true) or (ctype == "" and resp.body:find("<html", 1, true)) then page = html.render(resp.body, width)
  elseif ctype:find("^text/") or ctype:find("json", 1, true) or ctype:find("xml", 1, true) then page = html.render(resp.body, width, true)
  else
    page = html.render(("[%s, %d bytes]\n\nThis is not text. Press S to save it to a file."):format(ctype ~= "" and ctype or "unknown type", #resp.body), width, true)
  end
  page.url, page.status, page.type, page.body, page.reason = resp.url or url, resp.status, ctype, resp.body, resp.reason
  if resp.status >= 400 and #page.lines == 0 then page = html.render(("%d %s"):format(resp.status, resp.reason or ""), width, true) page.url, page.status = url, resp.status end
  return page
end

---------------------------------------------------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------------------------------------------------

local function colorOf(t, name) return t.isColor and t.isColor() and colors[name] or nil end

--- Draw the page into `t` (a term object): title bar, text, status line.
function M.draw(t, page, state)
  local w, h = t.getSize()
  local color = t.isColor and t.isColor()
  t.setBackgroundColor(colors.black)
  t.clear()
  t.setCursorPos(1, 1)
  t.setBackgroundColor(color and colors.blue or colors.white)
  t.setTextColor(color and colors.white or colors.black)
  local title = (page.title or page.url or "") .. " "
  t.write(title:sub(1, w) .. string.rep(" ", w - #title))
  t.setBackgroundColor(colors.black)
  local body = h - 2
  for row = 1, body do
    local line = page.lines[state.scroll + row]
    if not line then break end
    t.setCursorPos(1, row + 1)
    for _, piece in ipairs(line) do
      local selected = piece.link and piece.link == state.selected
      if color then
        t.setTextColor(colors[M.COLORS[piece.kind] or "white"])
        if selected then t.setBackgroundColor(colors.white) t.setTextColor(colors.blue) end
      else
        if selected then t.setBackgroundColor(colors.white) t.setTextColor(colors.black) else t.setTextColor(colors.white) end
      end
      t.write(piece.text)
      t.setBackgroundColor(colors.black)
    end
  end
  -- status line
  t.setCursorPos(1, h)
  t.setBackgroundColor(color and colors.gray or colors.white)
  t.setTextColor(color and colors.white or colors.black)
  local status = state.message
  if not status then
    local l = state.selected and page.links[state.selected]
    status = l and msg.resolve(msg.parseUrl(page.url) or { scheme = "http", host = "?", port = 80, path = "/" }, l.href) or "G go  Tab link  Enter open  Bksp back  Q quit"
  end
  t.write(status:sub(1, w) .. string.rep(" ", math.max(0, w - #status)))
  t.setBackgroundColor(colors.black)
  t.setTextColor(colors.white)
end

--- The link on screen row `row` and column `col`, if any.
function M.linkAt(page, state, row, col)
  local line = page.lines[state.scroll + row - 1]
  if not line then return nil end
  local x = 1
  for _, piece in ipairs(line) do
    if piece.link and col >= x and col < x + #piece.text then return piece.link end
    x = x + #piece.text
  end
end

---------------------------------------------------------------------------------------------------------------------
-- The browser
---------------------------------------------------------------------------------------------------------------------

--- opts: term (default the current terminal), stack, events (function() -> event table, default os.pullEvent), prompt (function(text) -> string, default read()).
function M.browse(url, opts)
  opts = opts or {}
  local t = opts.term or term.current()
  local nextEvent = opts.events or function() return { os.pullEvent() } end
  local prompt = opts.prompt or function(text)
    local w, h = t.getSize()
    t.setCursorPos(1, h)
    t.setBackgroundColor(colors.black)
    t.clearLine()
    t.write(text)
    return read()
  end
  local history = {}
  local page, state
  local function show(newUrl, pushHistory)
    local w, h = t.getSize()
    local p, err = M.load(newUrl, w, opts)
    if not p then
      state = state or { scroll = 0 }
      state.message = "cannot load " .. newUrl .. ": " .. tostring(err)
      if page then M.draw(t, page, state) end
      return false, err
    end
    if pushHistory and page then history[#history + 1] = page.url end
    page = p
    state = { scroll = 0, selected = #p.links > 0 and 1 or nil }
    M.draw(t, page, state)
    return true
  end
  if url then local ok, err = show(url, false) if not ok then return nil, err end end
  if not page then page = html.render("Type G to enter an address.", 40, true) page.url = "" state = { scroll = 0 } M.draw(t, page, state) end
  while true do
    local ev = nextEvent()
    local name = ev[1]
    local w, h = t.getSize()
    local body = h - 2
    local maxScroll = math.max(0, #page.lines - body)
    state.message = nil
    if name == "key" then
      local k = ev[2]
      if k == keys.up then state.scroll = math.max(0, state.scroll - 1)
      elseif k == keys.down then state.scroll = math.min(maxScroll, state.scroll + 1)
      elseif k == keys.pageUp then state.scroll = math.max(0, state.scroll - body)
      elseif k == keys.pageDown then state.scroll = math.min(maxScroll, state.scroll + body)
      elseif k == keys.home then state.scroll = 0
      elseif k == keys["end"] then state.scroll = maxScroll
      elseif k == keys.tab and #page.links > 0 then
        state.selected = ((state.selected or 0) % #page.links) + 1
        local l = page.links[state.selected]
        if l.line <= state.scroll then state.scroll = math.max(0, l.line - 1) elseif l.line > state.scroll + body then state.scroll = math.min(maxScroll, l.line - body) end
      elseif k == keys.enter and state.selected then
        local target = msg.resolve(msg.parseUrl(page.url) or { scheme = "http", host = "?", port = 80, path = "/" }, page.links[state.selected].href)
        show(target, true)
      elseif k == keys.backspace and #history > 0 then
        local back = table.remove(history)
        show(back, false)
      elseif k == keys.g then
        local entered = prompt("Go to: ")
        if entered and entered ~= "" then show(entered, true) end
      elseif k == keys.r and page.url ~= "" then show(page.url, false)
      elseif k == keys.s and page.body then
        local name2 = prompt("Save as: ")
        if name2 and name2 ~= "" then
          local ok = vfs.writeFile(vfs.normalize(name2), page.body, true)
          state.message = ok and ("saved " .. name2) or "could not save"
        end
      elseif k == keys.q then return true end
    elseif name == "mouse_click" then
      local l = M.linkAt(page, state, ev[4], ev[3])
      if l then
        state.selected = l
        show(msg.resolve(msg.parseUrl(page.url) or { scheme = "http", host = "?", port = 80, path = "/" }, page.links[l].href), true)
      end
    elseif name == "mouse_scroll" then
      state.scroll = math.max(0, math.min(maxScroll, state.scroll + ev[2]))
    elseif name == "term_resize" and page.url ~= "" then
      show(page.url, false)
    end
    if state then M.draw(t, page, state) end
  end
end

return M
