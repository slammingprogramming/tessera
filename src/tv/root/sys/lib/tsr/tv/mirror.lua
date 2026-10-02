-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Screen mirroring: show what a computer's terminal shows on one or more monitors as well.
--   mirror <monitor>... [-- command]    run the command (default: a shell) with its output also appearing on the monitors
--   mirror copy <monitor>...            copy what is on the screen right now (windows only) and leave
-- A "tee" terminal forwards every drawing call to all of its targets. The first target is the master: sizes, cursor and colours
-- queries are answered by it; the others simply draw (monitors clip what does not fit).
local M = {}

local METHODS = { "write", "blit", "clear", "clearLine", "setCursorPos", "setCursorBlink", "scroll", "setTextColor", "setTextColour",
                  "setBackgroundColor", "setBackgroundColour", "setPaletteColor", "setPaletteColour" }
local QUERIES = { "getCursorPos", "getCursorBlink", "getSize", "isColor", "isColour", "getTextColor", "getTextColour", "getBackgroundColor",
                  "getBackgroundColour", "getPaletteColor", "getPaletteColour", "getLine", "getPosition" }

--- A terminal object that draws on every target. targets[1] is the master.
function M.tee(targets)
  local master = targets[1]
  local t = {}
  for _, name in ipairs(METHODS) do
    t[name] = function(...)
      local result
      for i, target in ipairs(targets) do
        local fn = target[name]
        if fn then
          local r = table.pack(pcall(fn, ...))
          if i == 1 then
            if not r[1] then error(r[2], 0) end
            result = r
          end
        end
      end
      if result then return table.unpack(result, 2, result.n) end
    end
  end
  for _, name in ipairs(QUERIES) do
    if master[name] then t[name] = function(...) return master[name](...) end end
  end
  -- a monitor's text scale is its own business; ignore it here
  t.setTextScale = function() end
  return t
end

--- Redraw the current contents of `source` (a window) onto `target`. Returns true or nil + reason.
function M.copy(source, target)
  if not source.getLine then return nil, "this terminal cannot be copied (run it inside a window)" end
  local w, h = source.getSize()
  local tw, th = target.getSize()
  for y = 1, math.min(h, th) do
    local text, fg, bg = source.getLine(y)
    target.setCursorPos(1, y)
    target.blit(text:sub(1, tw), fg:sub(1, tw), bg:sub(1, tw))
  end
  return true
end

local function defaultIO()
  local io = {}
  function io.say(t) print(t) end
  function io.err(t) if term.isColor() then term.setTextColor(colors.red) end print(t) term.setTextColor(colors.white) end
  return io
end

--- env: peripheral (tests), run(line) (what to execute while mirrored)
function M.cli(args, io, env)
  io = io or defaultIO()
  env = env or {}
  local per = env.peripheral or peripheral
  local names, command = {}, nil
  local copyOnly = args[1] == "copy"
  local start = copyOnly and 2 or 1
  for i = start, #args do
    if args[i] == "--" then command = table.concat(args, " ", i + 1) break end
    names[#names + 1] = args[i]
  end
  if #names == 0 then io.err("usage: mirror <monitor>... [-- command]   |   mirror copy <monitor>...") return false end
  local targets = { term.current() }
  for _, n in ipairs(names) do
    local mon = per.wrap(n)
    if not mon then io.err("no monitor named " .. n) return false end
    targets[#targets + 1] = mon
  end
  if copyOnly then
    for i = 2, #targets do
      local ok, err = M.copy(targets[1], targets[i])
      if not ok then io.err(err) return false end
    end
    return true
  end
  local tee = M.tee(targets)
  local previous = term.redirect(tee)
  local run = env.run or function(line)
    local okExec, exec = pcall(require, "tsr.shell.exec")
    if okExec then
      local sh = exec.new({ parentShell = rawget(_G, "shell") })
      require("tsr.shell.repl").run(sh, { noRc = true, read = nil })
    else
      shell.run("shell")
    end
  end
  local ok, err = pcall(function()
    if command and command ~= "" then
      if env.run then env.run(command) else shell.run(command) end
    else
      run()
    end
  end)
  term.redirect(previous)
  if not ok then io.err(tostring(err)) return false end
  return true
end

function M.main(args) return M.cli(args) end

return M
