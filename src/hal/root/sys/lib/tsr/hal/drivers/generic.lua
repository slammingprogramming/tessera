-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Core drivers for the generic peripherals that CC: Tweaked itself provides (inventory, energy_storage, fluid_storage) and for
-- plain hardware (monitor, speaker, printer, drive, redstone relay).
local function hasType(dev, kind)
  for _, t in ipairs(dev.types) do if t == kind then return true end end
  return false
end


local inventory = {
  id = "generic.inventory",
  match = function(dev)
    if not hasType(dev, "inventory") then return nil end
    return {
      caps = { "inventory" },
      read = {
        ["inventory.size"] = function(d) return d.call("size"), "slots" end,
        ["inventory.used"] = function(d)
          local n = 0
          for _ in pairs(d.call("list")) do n = n + 1 end
          return n, "slots"
        end,
        ["inventory.items"] = function(d)
          local n = 0
          for _, stack in pairs(d.call("list")) do n = n + (stack.count or 0) end
          return n, "items"
        end,
        --- dev:get("inventory.count", "minecraft:coal") -> how many of that item the inventory holds
        ["inventory.count"] = function(d, item)
          local n = 0
          for _, stack in pairs(d.call("list")) do
            if stack.name == item then n = n + (stack.count or 0) end
          end
          return n, "items"
        end,
        ["inventory.percent"] = function(d)
          local size = d.call("size")
          if not size or size == 0 then return 0, "%" end
          local used = 0
          for _ in pairs(d.call("list")) do used = used + 1 end
          return used / size * 100, "%"
        end,
      },
    }
  end,
}

local energy = {
  id = "generic.energy",
  match = function(dev)
    if not hasType(dev, "energy_storage") then return nil end
    return {
      caps = { "energy" },
      read = {
        ["energy.stored"] = function(d) return d.call("getEnergy"), "FE" end,
        ["energy.capacity"] = function(d) return d.call("getEnergyCapacity"), "FE" end,
        ["energy.percent"] = function(d)
          local cap = d.call("getEnergyCapacity")
          if not cap or cap == 0 then return 0, "%" end
          return d.call("getEnergy") / cap * 100, "%"
        end,
      },
    }
  end,
}

local fluid = {
  id = "generic.fluid",
  match = function(dev)
    if not hasType(dev, "fluid_storage") then return nil end
    local function total(d)
      local sum = 0
      for _, t in pairs(d.call("tanks")) do sum = sum + (t.amount or 0) end
      return sum
    end
    return {
      caps = { "fluid" },
      read = {
        ["fluid.amount"] = function(d) return total(d), "mB" end,
        ["fluid.tanks"] = function(d) return d.call("tanks") end,
        ["fluid.name"] = function(d)
          for _, t in pairs(d.call("tanks")) do
            if (t.amount or 0) > 0 then return t.name end
          end
          return "empty"
        end,
      },
    }
  end,
}

local redstoneRelay = {
  id = "generic.redstone",
  match = function(dev)
    if not (hasType(dev, "redstone_relay") or hasType(dev, "redstoneIntegrator")) then return nil end
    return {
      caps = { "redstone" },
      read = {
        --- dev:get("redstone.input", "top") -> analog level 0-15
        ["redstone.input"] = function(d, side) return d.call("getAnalogInput", side), "level" end,
        ["redstone.output"] = function(d, side) return d.call("getAnalogOutput", side), "level" end,
      },
      act = {
        --- dev:act("redstone.set", "top", true | 0-15)
        ["redstone.set"] = function(d, side, level)
          if type(level) == "boolean" then d.call("setOutput", side, level) return true end
          d.call("setAnalogOutput", side, math.max(0, math.min(15, tonumber(level) or 0)))
          return true
        end,
      },
    }
  end,
}

local monitor = {
  id = "generic.monitor",
  match = function(dev)
    if not hasType(dev, "monitor") then return nil end
    return {
      caps = { "display" },
      read = {
        ["display.size"] = function(d) local w, h = d.call("getSize") return w .. "x" .. h end,
        ["display.color"] = function(d) return d.call("isColor") end,
      },
      act = {
        ["display.clear"] = function(d) d.call("clear") d.call("setCursorPos", 1, 1) return true end,
        ["display.write"] = function(d, text, x, y)
          if x and y then d.call("setCursorPos", x, y) end
          d.call("write", tostring(text))
          return true
        end,
        ["display.scale"] = function(d, s) d.call("setTextScale", s) return true end,
      },
    }
  end,
}

local speaker = {
  id = "generic.speaker",
  match = function(dev)
    if not hasType(dev, "speaker") then return nil end
    return {
      caps = { "audio" },
      act = {
        --- dev:act("audio.note", "bell", 1, 12)
        ["audio.note"] = function(d, instrument, volume, pitch)
          return d.call("playNote", instrument or "harp", volume or 1, pitch or 12)
        end,
        ["audio.sound"] = function(d, name, volume, pitch) return d.call("playSound", name, volume or 1, pitch or 1) end,
        ["audio.stop"] = function(d) d.call("stop") return true end,
      },
    }
  end,
}

local simple = {
  id = "generic.misc",
  match = function(dev)
    if hasType(dev, "printer") then
      return { caps = { "printer" }, read = {
        ["printer.paper"] = function(d) return d.call("getPaperLevel"), "sheets" end,
        ["printer.ink"] = function(d) return d.call("getInkLevel") end,
      } }
    elseif hasType(dev, "drive") then
      return { caps = { "drive" }, read = {
        ["drive.present"] = function(d) return d.call("isDiskPresent") end,
        ["drive.label"] = function(d) return d.call("getDiskLabel") end,
      } }
    end
  end,
}

return { inventory, energy, fluid, redstoneRelay, monitor, speaker, simple }
