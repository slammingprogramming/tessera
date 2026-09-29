-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Interactive offline import: lets a player with NO network feed Tessera its registry and package payloads by
--   * dropping a bundle file onto the terminal (file_transfer event), or
--   * pasting the numbered "TSR1 ..." text lines (one paste per line; order and repeats do not matter).
-- Used by `pkg import` and by the installer wizard.
local bundle = require("tsr.bundle")

local M = {}

local function color(c)
  if term.isColor() then term.setTextColor(c) end
end

local function say(c, text)
  color(c)
  print(text)
  color(colors.white)
end

--- Read every file in a file_transfer event. Returns array of strings.
local function transferred(files)
  local out = {}
  for _, f in ipairs(files.getFiles()) do
    local data = f.readAll()
    f.close()
    if data then out[#out + 1] = data end
  end
  return out
end

--- Block until a complete bundle has arrived (or the user presses Ctrl+T). Returns the parsed bundle table, or nil.
--- opts.prompt overrides the first instruction line.
function M.interactive(opts)
  opts = opts or {}
  say(colors.yellow, opts.prompt or "Offline import")
  print("Drag a .tsrbundle file onto this window,")
  print("or paste the TSR1 lines one at a time (Ctrl+V).")
  print("Press Ctrl+T to cancel.")
  local asm = bundle.newAssembler()
  while true do
    local ev = table.pack(os.pullEventRaw())
    if ev[1] == "terminate" then
      say(colors.red, "Import cancelled.")
      return nil
    elseif ev[1] == "file_transfer" then
      for _, data in ipairs(transferred(ev[2])) do
        local b, err = bundle.parse(data)
        if b then
          say(colors.lime, "Bundle file accepted.")
          return b
        end
        say(colors.red, "Not a usable bundle: " .. tostring(err))
      end
    elseif ev[1] == "paste" then
      for line in (ev[2] .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        local status, detail = asm:add(line)
        if status == "ok" then
          local have, total = asm:progress()
          say(colors.lime, ("chunk %d ok  (%d/%d)"):format(detail, have, total))
        elseif status == "dup" then
          say(colors.lightGray, "chunk " .. detail .. " already received")
        elseif status == "bad" then
          say(colors.red, tostring(detail) .. " - paste that line again")
        end
        if asm:complete() then
          local b, err = asm:result()
          if b then
            say(colors.lime, "All chunks received.")
            return b
          end
          say(colors.red, "Bundle rejected: " .. tostring(err))
          asm = bundle.newAssembler()
        end
      end
      if asm.total and not asm:complete() then
        local m = asm:missing()
        if #m <= 8 then say(colors.lightGray, "still missing: " .. table.concat(m, ", ")) end
      end
    end
  end
end

return M
