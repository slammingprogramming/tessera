-- SPDX-License-Identifier: AGPL-3.0-or-later
-- HAL drivers for CC:C Bridge (Create). Documented peripherals (cccbridge.kleinbox.dev):
--   create_source  a Create display-link source that behaves like a terminal: getSize, clear, setCursorPos, write, getLine
--   create_target  a Create display target that can be read: getSize, getLine(y), dump(), resize(w, h)
local function isType(dev, name)
  for _, t in ipairs(dev.types) do if t == name then return true end end
  return false
end

local source = {
  id = "create.source",
  match = function(dev)
    if not isType(dev, "create_source") then return nil end
    return {
      caps = { "display" },
      read = {
        ["display.size"] = function(d) local w, h = d.call("getSize") return w .. "x" .. h end,
      },
      act = {
        ["display.clear"] = function(d) d.call("clear") d.call("setCursorPos", 1, 1) return true end,
        ["display.write"] = function(d, text, x, y)
          d.call("setCursorPos", tonumber(x) or 1, tonumber(y) or 1)
          d.call("write", tostring(text))
          return true
        end,
      },
    }
  end,
}

local target = {
  id = "create.target",
  match = function(dev)
    if not isType(dev, "create_target") then return nil end
    return {
      caps = { "display", "sensor" },
      read = {
        ["display.size"] = function(d) local w, h = d.call("getSize") return w .. "x" .. h end,
        --- dev:get("display.line", 2) -> text of line 2
        ["display.line"] = function(d, y) return d.call("getLine", tonumber(y) or 1) end,
        ["display.text"] = function(d)
          local w, h = d.call("getSize")
          local lines = {}
          for y = 1, h do lines[#lines + 1] = (d.call("getLine", y) or ""):gsub("%s+$", "") end
          return table.concat(lines, "\n")
        end,
      },
    }
  end,
}

return { source, target }
