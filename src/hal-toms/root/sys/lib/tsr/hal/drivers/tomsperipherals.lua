-- SPDX-License-Identifier: AGPL-3.0-or-later
-- HAL drivers for Tom's Peripherals. Peripheral type names and methods are taken from the mod's source and wiki (github.com/tom5454/
-- Toms-Peripherals):
--   tm_gpu       GPU for bitmap monitors:  setSize(resolution), refreshSize(), getSize(), sync() and the 2D drawing functions fill, filledRectangle,
--                rectangle, line, drawText, getUsedMemory, getMaxMemory (the GPU context)
--   tm_rsPort    redstone port: getSides, getInput/getAnalogInput/getBundledInput, getOutput/getAnalogOutput/getBundledOutput,
--                setOutput/setAnalogOutput/setBundledOutput, testBundledInput      (directions: down up north south west east)
--   tm_wdt       watch dog timer: isEnabled, getTimeout, setEnabled, setTimeout, reset   (restarts the computer when the timer runs out)
--   tm_keyboard  keyboard: setFireNativeEvents(bool)
-- Events the mod fires (use them with os.pullEvent in your own programs): tm_monitor_touch, tm_monitor_mouse_*, tm_keyboard_*, tm_redstone.
local ALIASES = { top = "up", bottom = "down" }

local function dir(side)
  side = tostring(side or ""):lower()
  return ALIASES[side] or side
end

local function isType(dev, name)
  for _, t in ipairs(dev.types) do if t:lower() == name then return true end end
  return false
end

local function colorOf(c) return c end

local gpu = {
  id = "toms.gpu",
  match = function(dev)
    if not isType(dev, "tm_gpu") then return nil end
    local function drawn(d) d.call("sync") return true end
    return {
      caps = { "display", "gpu" },
      read = {
        --- "320x192" (pixels, all connected bitmap monitors together)
        ["display.size"] = function(d) local w, h = d.call("getSize") return tostring(w) .. "x" .. tostring(h) end,
        ["gpu.memory_used"] = function(d) return d.call("getUsedMemory"), "bytes" end,
        ["gpu.memory_max"] = function(d) return d.call("getMaxMemory"), "bytes" end,
        ["gpu.memory_percent"] = function(d)
          local max = d.call("getMaxMemory")
          if not max or max == 0 then return 0, "%" end
          return d.call("getUsedMemory") / max * 100, "%"
        end,
      },
      act = {
        --- dev:act("display.clear", color) -> fill the screens (default black) and show it
        ["display.clear"] = function(d, color) if color ~= nil then d.call("fill", colorOf(color)) else d.call("fill") end return drawn(d) end,
        ["display.rect"] = function(d, x, y, w, h, color, outline)
          d.call(outline and "rectangle" or "filledRectangle", x, y, w, h, colorOf(color or 0xFFFFFF))
          return drawn(d)
        end,
        ["display.line"] = function(d, x1, y1, x2, y2, color) d.call("line", x1, y1, x2, y2, colorOf(color or 0xFFFFFF)) return drawn(d) end,
        --- dev:act("display.text", x, y, "Hello", 0xFFFFFF, 0x000000)
        ["display.text"] = function(d, x, y, text, color, background)
          d.call("drawText", x or 0, y or 0, tostring(text), colorOf(color or 0xFFFFFF), colorOf(background or 0))
          return drawn(d)
        end,
        ["display.sync"] = function(d) return drawn(d) end,
        --- dev:act("display.resolution", 2) -> the resolution multiplier of every monitor block
        ["display.resolution"] = function(d, n) d.call("setSize", tonumber(n) or 1) return true end,
        ["display.refresh"] = function(d) d.call("refreshSize") return true end,
      },
    }
  end,
}

local redstonePort = {
  id = "toms.redstone_port",
  match = function(dev)
    if not isType(dev, "tm_rsport") then return nil end
    return {
      caps = { "redstone", "bundled_redstone" },
      read = {
        ["redstone.sides"] = function(d) return d.call("getSides") end,
        --- dev:get("redstone.input", "north") -> analog level 0-15 ("top" and "bottom" mean up and down)
        ["redstone.input"] = function(d, side) return d.call("getAnalogInput", dir(side)), "level" end,
        ["redstone.output"] = function(d, side) return d.call("getAnalogOutput", dir(side)), "level" end,
        ["redstone.bundled_input"] = function(d, side) return d.call("getBundledInput", dir(side)) end,
        ["redstone.bundled_output"] = function(d, side) return d.call("getBundledOutput", dir(side)) end,
        --- dev:get("redstone.bundled_test", "up", colors.red) -> is that wire (mask) powered?
        ["redstone.bundled_test"] = function(d, side, mask) return d.call("testBundledInput", dir(side), mask) end,
      },
      act = {
        --- dev:act("redstone.set", "east", true | 0-15)
        ["redstone.set"] = function(d, side, level)
          if type(level) == "boolean" then d.call("setOutput", dir(side), level) return true end
          d.call("setAnalogOutput", dir(side), math.max(0, math.min(15, math.floor(tonumber(level) or 0))))
          return true
        end,
        --- dev:act("redstone.bundled", "up", colors.combine(colors.red, colors.blue))
        ["redstone.bundled"] = function(d, side, mask) d.call("setBundledOutput", dir(side), tonumber(mask) or 0) return true end,
      },
    }
  end,
}

local watchdog = {
  id = "toms.watchdog",
  match = function(dev)
    if not isType(dev, "tm_wdt") then return nil end
    return {
      caps = { "watchdog" },
      read = {
        ["watchdog.enabled"] = function(d) return d.call("isEnabled") end,
        ["watchdog.timeout"] = function(d) return d.call("getTimeout") end,
      },
      act = {
        ["watchdog.enable"] = function(d, on) d.call("setEnabled", on ~= false) return true end,
        ["watchdog.timeout"] = function(d, n) d.call("setTimeout", math.max(1, math.floor(tonumber(n) or 1))) return true end,
        --- Keep the computer alive: call this regularly (a rules or cron job can do it).
        ["watchdog.feed"] = function(d) d.call("reset") return true end,
        ["watchdog.reset"] = function(d) d.call("reset") return true end,
      },
    }
  end,
}

local keyboard = {
  id = "toms.keyboard",
  match = function(dev)
    if not isType(dev, "tm_keyboard") then return nil end
    return {
      caps = { "input" },
      act = {
        --- true: the keyboard sends ordinary key/char events (for programs written for a terminal); false: events are prefixed tm_keyboard_
        ["input.native_events"] = function(d, on) d.call("setFireNativeEvents", on == true) return true end,
      },
    }
  end,
}

return { gpu, redstonePort, watchdog, keyboard }
