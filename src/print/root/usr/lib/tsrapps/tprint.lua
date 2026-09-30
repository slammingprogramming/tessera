-- SPDX-License-Identifier: AGPL-3.0-or-later
-- tprint: print text on an attached printer. Successor of the old printer.lua script (which asked for a title and one
-- line of text and printed a single page): this one word-wraps, paginates, numbers the pages, checks paper and ink and
-- can print a file.
--   tprint <file> [--title T] [--copies N] [--no-numbers] [--side name]
--   tprint                       asks for a title, then reads lines until you type a single "."
local cli = require("tsrapps.cli")

local M = {}

M.SPEC = { title = "string", copies = "number", ["no-numbers"] = "bool", side = "string" }

--- Word-wrap `text` into lines of at most `width` characters (long words are split; blank lines are kept).
function M.wrap(text, width)
  local lines = {}
  text = text:gsub("\r", ""):gsub("\t", "  ")
  for para in (text .. "\n"):gmatch("([^\n]*)\n") do
    if para:match("^%s*$") then
      lines[#lines + 1] = ""
    else
      local indent = para:match("^(%s*)")
      local line = ""
      for word in para:gmatch("%S+") do
        while #word > width do
          if line ~= "" then lines[#lines + 1] = line line = "" end
          lines[#lines + 1] = word:sub(1, width)
          word = word:sub(width + 1)
        end
        if line == "" then
          -- the first word of a paragraph keeps its indentation when it fits
          line = (#indent > 0 and #indent + #word <= width) and (indent .. word) or word
        elseif #line + 1 + #word <= width then
          line = line .. " " .. word
        else
          lines[#lines + 1] = line
          line = word
        end
      end
      lines[#lines + 1] = line
    end
  end
  while #lines > 1 and lines[#lines] == "" do lines[#lines] = nil end
  return lines
end

--- Split lines into pages of `perPage` lines. The first page has `firstPage` lines if given (room for a title).
function M.paginate(lines, perPage, firstPage)
  local pages, i = {}, 1
  local size = firstPage or perPage
  while i <= #lines do
    local page = {}
    for k = i, math.min(#lines, i + size - 1) do page[#page + 1] = lines[k] end
    pages[#pages + 1] = page
    i = i + size
    size = perPage
  end
  if #pages == 0 then pages[1] = {} end
  return pages
end

--- How many pages `text` needs on a printer with the given page size.
function M.plan(text, width, height, opts)
  opts = opts or {}
  local numbers = opts.numbers ~= false
  local perPage = height - (numbers and 1 or 0)
  local first = perPage - (opts.title and 2 or 0)
  return M.paginate(M.wrap(text, width), perPage, first), perPage
end

--- Print `text`. opts: title, copies (default 1), numbers (default true). Returns pages printed, or nil + reason
--- (pages printed before a failure are reported in the message).
function M.print(printer, text, opts)
  opts = opts or {}
  local width, height = printer.getPageSize()
  local pages, perPage = M.plan(text, width, height, opts)
  local copies = opts.copies or 1
  local needed = #pages * copies
  local paper = printer.getPaperLevel()
  if paper < needed then return nil, ("need %d sheet(s) of paper, only %d loaded"):format(needed, paper) end
  local ink = printer.getInkLevel()
  if ink < 1 then return nil, "the printer is out of ink" end
  local printed = 0
  for copy = 1, copies do
    for n, page in ipairs(pages) do
      if not printer.newPage() then
        return nil, ("could not start page %d (%d printed): check paper and ink"):format(printed + 1, printed)
      end
      local y = 1
      if opts.title then
        printer.setPageTitle(#pages > 1 and ("%s (%d/%d)"):format(opts.title, n, #pages) or opts.title)
        if n == 1 then
          local header = "== " .. opts.title .. " =="
          if #header > width then header = header:sub(1, width) end
          printer.setCursorPos(math.max(1, math.floor((width - #header) / 2) + 1), 1)
          printer.write(header)
          y = 3
        end
      end
      for _, line in ipairs(page) do
        printer.setCursorPos(1, y)
        printer.write(line)
        y = y + 1
      end
      if opts.numbers ~= false and #pages > 1 then
        local label = ("- %d/%d -"):format(n, #pages)
        printer.setCursorPos(math.max(1, math.floor((width - #label) / 2) + 1), height)
        printer.write(label)
      end
      if not printer.endPage() then
        return nil, ("could not finish page %d (%d printed): the output tray may be full"):format(printed + 1, printed)
      end
      printed = printed + 1
    end
  end
  return printed
end

local function readAll(path)
  local h = fs.open(path, "r")
  if not h then return nil end
  local s = h.readAll()
  h.close()
  return s
end

--- Read lines until a lone "." (interactive mode).
local function typeText(io)
  io.say('Type your text; finish with a line containing only "."')
  local lines = {}
  while true do
    local l = io.prompt("")
    if l == nil or l == "." then break end
    lines[#lines + 1] = l
  end
  return table.concat(lines, "\n")
end

function M.main(args, io, printer)
  io = io or cli.io()
  local pos, opts = cli.parse(args, M.SPEC)
  if not pos then io.err(opts) return false end
  if not printer then
    printer = opts.side and peripheral.wrap(opts.side) or peripheral.find("printer")
  end
  if not printer then io.err("No printer found. Attach a printer (and load paper and ink), or use --side.") return false end
  local text, title = nil, opts.title
  if pos[1] then
    text = readAll(pos[1])
    if not text then io.err("Cannot read " .. pos[1]) return false end
    title = title or fs.getName(pos[1])
  else
    title = title or io.prompt("Title", "Untitled")
    text = typeText(io)
    if text == "" then io.err("Nothing to print.") return false end
  end
  local printed, err = M.print(printer, text, { title = title, copies = opts.copies, numbers = not opts["no-numbers"] })
  if not printed then io.err(err) return false end
  io.say(("Printed %d page%s."):format(printed, printed == 1 and "" or "s"))
  return true
end

return M
