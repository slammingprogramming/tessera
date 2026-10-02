-- SPDX-License-Identifier: AGPL-3.0-or-later
-- A small HTML reader for text screens: parses the usual tags into a tree and lays it out as wrapped lines of coloured pieces, with the links collected.
-- Understood: title, h1-h6, p, br, hr, a, b/strong, i/em/u, ul/ol/li, pre/code, blockquote, table (rows shown with " | "), img (its alt text), div and the
-- like as blocks; scripts, styles and comments are dropped; the entities &amp; &lt; &gt; &quot; &apos; &nbsp; and numeric ones are decoded.
local M = {}

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ", copy = "(c)", hellip = "...", mdash = "-", ndash = "-", laquo = "<<", raquo = ">>", bull = "*" }

local function decodeEntities(s)
  return (s:gsub("&(#?[%w]+);", function(e)
    if e:sub(1, 1) == "#" then
      local n = e:sub(2, 2):lower() == "x" and tonumber(e:sub(3), 16) or tonumber(e:sub(2))
      if n and n >= 32 and n < 127 then return string.char(n) end
      return "?"
    end
    return ENTITIES[e:lower()] or ("&" .. e .. ";")
  end))
end
M.decodeEntities = decodeEntities

local VOID = { br = true, hr = true, img = true, input = true, meta = true, link = true }
local BLOCK = { p = true, div = true, h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true, ul = true, ol = true, li = true, pre = true, blockquote = true, table = true, tr = true,
  section = true, article = true, header = true, footer = true, nav = true, main = true, form = true, hr = true, br = true, body = true, html = true, title = true, center = true, dl = true, dt = true, dd = true }
local SKIP = { script = true, style = true, head = false }

--- Parse into a tree: { tag, attrs, children } with text nodes as plain strings.
function M.parse(html)
  local root = { tag = "#root", attrs = {}, children = {} }
  local stack = { root }
  local pos = 1
  local function top() return stack[#stack] end
  local function addText(t)
    if t ~= "" then local c = top().children c[#c + 1] = t end
  end
  while pos <= #html do
    local lt = html:find("<", pos, true)
    if not lt then addText(html:sub(pos)) break end
    if lt > pos then addText(html:sub(pos, lt - 1)) end
    if html:sub(lt, lt + 3) == "<!--" then
      local e = html:find("-->", lt + 4, true)
      pos = e and e + 3 or #html + 1
    elseif html:sub(lt, lt + 1) == "<!" or html:sub(lt, lt + 1) == "<?" then
      local e = html:find(">", lt, true)
      pos = e and e + 1 or #html + 1
    else
      local e = html:find(">", lt, true)
      local skipped = false
      if not e then addText(html:sub(lt)) break end
      local inner = html:sub(lt + 1, e - 1)
      local closing = inner:sub(1, 1) == "/"
      local name = inner:match("^/?%s*([%w:-]+)")
      if not name then addText("<") pos = lt + 1
      else
        name = name:lower()
        if closing then
          for i = #stack, 2, -1 do
            if stack[i].tag == name then for _ = #stack, i, -1 do table.remove(stack) end break end
          end
        else
          local attrs = {}
          for k, q, v in inner:gmatch('([%w:-]+)%s*=%s*(["\'])(.-)%2') do attrs[k:lower()] = decodeEntities(v) end
          for k, v in inner:gmatch("([%w:-]+)%s*=%s*([^%s\"'>]+)") do if attrs[k:lower()] == nil then attrs[k:lower()] = decodeEntities(v) end end
          local node = { tag = name, attrs = attrs, children = {} }
          local c = top().children
          c[#c + 1] = node
          if SKIP[name] then
            -- raw text element: skip to its closing tag
            local close = html:lower():find("</" .. name, e + 1, true)
            pos = close and ((html:find(">", close, true) or #html) + 1) or #html + 1
            skipped = true
          elseif not VOID[name] and inner:sub(-1) ~= "/" then
            -- implied end of the previous <li>/<p>
            if name == "li" and top().tag == "li" then table.remove(stack) end
            if (name == "tr" or name == "td" or name == "th") then
              local t = top().tag
              if (name == "tr" and (t == "tr")) or ((name == "td" or name == "th") and (t == "td" or t == "th")) then table.remove(stack) end
            end
            stack[#stack + 1] = node
            -- the node was added to the old top before; keep it there
          end
        end
        if not skipped then pos = e + 1 end
      end
    end
  end
  return root
end

---------------------------------------------------------------------------------------------------------------------
-- Layout
---------------------------------------------------------------------------------------------------------------------

--- Lay out a tree. Returns { title, lines = { { { text, kind, link } ... } ... }, links = { { href, text, line } ... } }.
--- kind: "text" | "bold" | "italic" | "head" | "code" | "link". width: characters per line.
function M.layout(tree, width)
  width = width or 50
  local out = { lines = {}, links = {}, title = nil }
  local line, col = {}, 0
  local indent = 0
  local preMode = false
  local pendingSpace = false
  local blankBefore = false

  local function newline(force)
    if #line > 0 or force then out.lines[#out.lines + 1] = line end
    line, col = {}, 0
    pendingSpace = false
  end
  local function blank()
    if #out.lines > 0 and #(out.lines[#out.lines]) > 0 then newline(true) end
    newline()
    if #out.lines > 0 and #(out.lines[#out.lines]) > 0 then out.lines[#out.lines + 1] = {} end
  end
  local function put(text, kind, link)
    if text == "" then return end
    if col == 0 and indent > 0 then line[#line + 1] = { text = string.rep(" ", indent), kind = "text" } col = indent end
    line[#line + 1] = { text = text, kind = kind or "text", link = link }
    col = col + #text
  end
  local function word(w, kind, link)
    if col > indent and col + #w + (pendingSpace and 1 or 0) > width then newline() end
    if pendingSpace and col > indent then
      local last = line[#line]
      if link and last and last.link == link then put(" ", kind, link) else put(" ", "text") end
    end
    pendingSpace = false
    -- a word longer than the line is cut
    while #w > width - indent do
      put(w:sub(1, width - indent), kind, link)
      newline()
      w = w:sub(width - indent + 1)
    end
    put(w, kind, link)
  end
  local function text(t, kind, link)
    if preMode then
      for piece, nl in t:gmatch("([^\n]*)(\n?)") do
        if piece ~= "" then put(piece, kind, link) end
        if nl == "\n" then newline(true) end
      end
      return
    end
    t = decodeEntities(t:gsub("%s+", " "))
    if t:sub(1, 1) == " " then pendingSpace = true t = t:sub(2) end
    local endsSpace = t:sub(-1) == " "
    for w in t:gmatch("%S+") do word(w, kind, link) pendingSpace = true end
    if not endsSpace then pendingSpace = false end
  end

  local function walk(node, kind, link, listState)
    if type(node) == "string" then return text(node, kind, link) end
    local tag = node.tag
    if tag == "title" then
      local parts = {}
      local function collect(n) if type(n) == "string" then parts[#parts + 1] = n else for _, c in ipairs(n.children) do collect(c) end end end
      collect(node)
      out.title = decodeEntities(table.concat(parts):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
      return
    end
    local block = BLOCK[tag]
    if tag == "br" then newline(true) return end
    if tag == "hr" then blank() put(string.rep("-", math.min(width - indent, 40)), "text") blank() return end
    if tag == "img" then text("[" .. (node.attrs.alt and node.attrs.alt ~= "" and ("image: " .. node.attrs.alt) or "image") .. "]", kind, link) return end
    if tag == "input" then
      local ty = (node.attrs.type or "text"):lower()
      if ty ~= "hidden" then text("[" .. (node.attrs.value or node.attrs.name or ty) .. "]", kind, link) end
      return
    end
    local k = kind
    local l = link
    if tag == "a" and node.attrs.href then
      out.links[#out.links + 1] = { href = node.attrs.href, text = "", line = #out.lines + 1 }
      l = #out.links
      k = "link"
    elseif tag == "b" or tag == "strong" then k = "bold"
    elseif tag == "i" or tag == "em" or tag == "u" then k = "italic"
    elseif tag:match("^h%d$") then k = "head"
    elseif tag == "code" or tag == "pre" then k = "code" end
    if block and (tag == "p" or tag:match("^h%d$") or tag == "ul" or tag == "ol" or tag == "table" or tag == "pre" or tag == "blockquote") then blank() elseif block then newline() end
    local savedIndent, savedPre = indent, preMode
    if tag == "ul" or tag == "ol" then indent = indent + 2 listState = { ordered = tag == "ol", n = 0 }
    elseif tag == "blockquote" then indent = indent + 2
    elseif tag == "pre" then preMode = true end
    if tag == "li" then
      newline()
      local state = listState or { n = 0 }
      state.n = state.n + 1
      local marker = state.ordered and (state.n .. ". ") or "* "
      indent = savedIndent - 2 > 0 and savedIndent - 2 or 0
      put(string.rep(" ", indent) .. marker, "text")
      col = indent + #marker
      indent = savedIndent
      line[#line].noWrap = true
      pendingSpace = false
    end
    if tag == "td" or tag == "th" then
      if col > indent then put(" | ", "text") pendingSpace = false end
    end
    local startLink = l ~= link and l or nil
    local before = #out.lines
    local beforeParts = #line
    for _, c in ipairs(node.children) do walk(c, k, l, listState) end
    if startLink then
      -- the text of the link, for the list of links
      local parts = {}
      for i = before + 1, #out.lines do for _, piece in ipairs(out.lines[i]) do if piece.link == startLink then parts[#parts + 1] = piece.text end end end
      for i = beforeParts + 1, #line do if line[i].link == startLink then parts[#parts + 1] = line[i].text end end
      out.links[startLink].text = table.concat(parts)
    end
    indent, preMode = savedIndent, savedPre
    if block then
      if tag == "p" or tag:match("^h%d$") or tag == "ul" or tag == "ol" or tag == "table" or tag == "pre" or tag == "blockquote" then blank() else newline() end
    end
  end
  for _, c in ipairs(tree.children) do walk(c, "text", nil, nil) end
  newline()
  -- trim blank lines at both ends
  while #out.lines > 0 and #out.lines[#out.lines] == 0 do out.lines[#out.lines] = nil end
  while #out.lines > 0 and #out.lines[1] == 0 do table.remove(out.lines, 1) for _, l in ipairs(out.links) do l.line = l.line - 1 end end
  return out
end

--- Parse and lay out in one call. Plain text (not HTML) is shown as it is.
function M.render(html, width, isText)
  if isText then
    local lines = {}
    for l in (html .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = { { text = l:sub(1, width or 50), kind = "text" } } end
    return { lines = lines, links = {}, title = nil }
  end
  return M.layout(M.parse(html), width)
end

--- The plain text of a rendered page (for tests and for piping to a file).
function M.plain(page)
  local out = {}
  for _, line in ipairs(page.lines) do
    local t = {}
    for _, piece in ipairs(line) do t[#t + 1] = piece.text end
    out[#out + 1] = table.concat(t)
  end
  return table.concat(out, "\n")
end

return M
