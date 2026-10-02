-- SPDX-License-Identifier: AGPL-3.0-or-later
-- HAL drivers for Create. First, the CC:C Bridge add-on (cccbridge.kleinbox.dev):
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

---------------------------------------------------------------------------------------------------------------------
-- Create's own ComputerCraft integration (Create 0.5.1+ for 1.20.1 and 1.21.1, no CC:C Bridge needed). Peripheral types and methods checked
-- against the mod's source (Creators-of-Create/Create, compat/computercraft/implementation/peripherals):
--   Create_Speedometer getSpeed | Create_Stressometer getStress, getStressCapacity | Create_RotationSpeedController get/setTargetSpeed |
--   Create_CreativeMotor get/setGeneratedSpeed | Create_SequencedGearshift rotate(angle [, modifier]), move(distance [, modifier]), isRunning |
--   Create_DisplayLink terminal-like (getSize, clear, setCursorPos, write, update...) | Create_NixieTube setText(text [, colour]), setTextColour
-- ---------------------------------------------------------------------------------------------------------------------

local speedometer = {
  id = "create.speedometer",
  match = function(dev)
    if not isType(dev, "Create_Speedometer") then return nil end
    return { caps = { "sensor", "kinetic" }, read = { ["kinetic.speed"] = function(d) return d.call("getSpeed"), "RPM" end } }
  end,
}

local stressometer = {
  id = "create.stressometer",
  match = function(dev)
    if not isType(dev, "Create_Stressometer") then return nil end
    return {
      caps = { "sensor", "kinetic" },
      read = {
        ["kinetic.stress"] = function(d) return d.call("getStress"), "SU" end,
        ["kinetic.capacity"] = function(d) return d.call("getStressCapacity"), "SU" end,
        ["kinetic.percent"] = function(d)
          local cap = d.call("getStressCapacity")
          if not cap or cap == 0 then return 0, "%" end
          return d.call("getStress") / cap * 100, "%"
        end,
      },
    }
  end,
}

local speedController = {
  id = "create.speed_controller",
  match = function(dev)
    if not isType(dev, "Create_RotationSpeedController") then return nil end
    return {
      caps = { "kinetic", "actuator" },
      read = { ["kinetic.target_speed"] = function(d) return d.call("getTargetSpeed"), "RPM" end },
      --- dev:act("kinetic.set_speed", 64)  (the controller accepts -256..256 RPM)
      act = { ["kinetic.set_speed"] = function(d, rpm) d.call("setTargetSpeed", math.max(-256, math.min(256, math.floor(tonumber(rpm) or 0)))) return true end },
    }
  end,
}

local creativeMotor = {
  id = "create.creative_motor",
  match = function(dev)
    if not isType(dev, "Create_CreativeMotor") then return nil end
    return {
      caps = { "kinetic", "actuator" },
      read = { ["kinetic.generated_speed"] = function(d) return d.call("getGeneratedSpeed"), "RPM" end },
      act = { ["kinetic.set_speed"] = function(d, rpm) d.call("setGeneratedSpeed", math.max(-256, math.min(256, math.floor(tonumber(rpm) or 0)))) return true end },
    }
  end,
}

local gearshift = {
  id = "create.sequenced_gearshift",
  match = function(dev)
    if not isType(dev, "Create_SequencedGearshift") then return nil end
    return {
      caps = { "kinetic", "actuator", "machine" },
      read = { ["machine.running"] = function(d) return d.call("isRunning") == true end },
      act = {
        --- dev:act("gearshift.rotate", 90) / ("gearshift.rotate", 90, -1): turn by an angle (the modifier 1, 2, -1, -2 changes speed and direction)
        ["gearshift.rotate"] = function(d, angle, modifier) d.call("rotate", math.floor(tonumber(angle) or 0), math.floor(tonumber(modifier) or 1)) return true end,
        --- dev:act("gearshift.move", 3): move a piston / bearing contraption by a distance in blocks
        ["gearshift.move"] = function(d, distance, modifier) d.call("move", math.floor(tonumber(distance) or 0), math.floor(tonumber(modifier) or 1)) return true end,
      },
    }
  end,
}

local displayLink = {
  id = "create.display_link",
  match = function(dev)
    if not isType(dev, "Create_DisplayLink") then return nil end
    return {
      caps = { "display" },
      read = { ["display.size"] = function(d) local w, h = d.call("getSize") return w .. "x" .. h end },
      act = {
        ["display.clear"] = function(d) d.call("clear") d.call("setCursorPos", 1, 1) return true end,
        --- the text only reaches the target display after update()
        ["display.write"] = function(d, text, x, y)
          d.call("setCursorPos", tonumber(x) or 1, tonumber(y) or 1)
          d.call("write", tostring(text))
          return true
        end,
        ["display.update"] = function(d) d.call("update") return true end,
      },
    }
  end,
}

local nixie = {
  id = "create.nixie_tube",
  match = function(dev)
    if not isType(dev, "Create_NixieTube") then return nil end
    return {
      caps = { "display" },
      act = {
        --- dev:act("display.text", "1234", "red")  (colour names are Minecraft dye colours)
        ["display.text"] = function(d, text, colour)
          if colour then d.call("setText", tostring(text), tostring(colour)) else d.call("setText", tostring(text)) end
          return true
        end,
        ["display.color"] = function(d, colour) d.call("setTextColour", tostring(colour)) return true end,
      },
    }
  end,
}

return { source, target, speedometer, stressometer, speedController, creativeMotor, gearshift, displayLink, nixie }
