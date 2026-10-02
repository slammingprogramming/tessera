-- SPDX-License-Identifier: AGPL-3.0-or-later
-- HAL drivers for Advanced Peripherals. Method names were checked against the mod's source (IntelligenceModding/AdvancedPeripherals,
-- branches dev/1.21.1 and dev/0.8-1.20.1) and the 0.7 documentation. Two generations exist and both are supported:
--   0.7 (Minecraft 1.20.1 and older): types meBridge/rsBridge..., getEnergyStorage, getMaxEnergyStorage, listItems, isItemCraftable, isItemCrafting
--   0.8 (1.20.1 and 1.21.1):          types me_bridge/rs_bridge..., getStoredEnergy, getEnergyCapacity, getItems, isCraftable, isCrafting
-- so the driver asks each bridge which of the method names it has.
local function kind(dev)
  for _, t in ipairs(dev.types) do
    local n = t:lower():gsub("_", "")
    if n == "mebridge" or n == "rsbridge" or n == "environmentdetector" or n == "energydetector" or n == "playerdetector" then
      return n
    end
  end
end

local function has(dev, method)
  for _, m in ipairs(dev.methods()) do if m == method then return true end end
  return false
end

--- The first of the given method names that this peripheral really has (the mod renamed several methods between versions).
local function pick(dev, ...)
  local names = { ... }
  local have = {}
  for _, m in ipairs(dev.methods()) do have[m] = true end
  for _, n in ipairs(names) do if have[n] then return n end end
  return names[1]
end

local function itemFilter(item)
  if type(item) == "table" then return item end
  return { name = item }
end

--- Total count of an item in a bridge: the bridge's getItem answers per item.
local function itemCount(d, item)
  local ok, res = pcall(d.call, "getItem", itemFilter(item))
  if ok and type(res) == "table" then return res.count or res.amount or 0 end
  return 0
end

local bridge = {
  id = "advancedperipherals.bridge",
  match = function(dev)
    local k = kind(dev)
    if k ~= "mebridge" and k ~= "rsbridge" then return nil end
    local read = {
      ["energy.stored"] = function(d) return d.call(pick(d, "getStoredEnergy", "getEnergyStorage")), "AE" end,
      ["energy.capacity"] = function(d) return d.call(pick(d, "getEnergyCapacity", "getMaxEnergyStorage")), "AE" end,
      ["energy.percent"] = function(d)
        local cap = d.call(pick(d, "getEnergyCapacity", "getMaxEnergyStorage"))
        if not cap or cap == 0 then return 0, "%" end
        return d.call(pick(d, "getStoredEnergy", "getEnergyStorage")) / cap * 100, "%"
      end,
      ["energy.usage"] = function(d) return d.call("getEnergyUsage"), "AE/t" end,
      --- dev:get("network.count", "minecraft:iron_ingot")
      ["network.count"] = function(d, item) return itemCount(d, item), "items" end,
      ["network.craftable"] = function(d, item)
        local ok, res = pcall(d.call, pick(d, "isCraftable", "isItemCraftable"), itemFilter(item))
        return ok and res == true
      end,
      ["network.crafting"] = function(d, item)
        local ok, res = pcall(d.call, pick(d, "isCrafting", "isItemCrafting"), itemFilter(item))
        return ok and res == true
      end,
      ["network.items"] = function(d)
        local total = 0
        for _, it in pairs(d.call(pick(d, "getItems", "listItems")) or {}) do total = total + (it.count or it.amount or 0) end
        return total, "items"
      end,
      ["network.types"] = function(d)
        local n = 0
        for _ in pairs(d.call(pick(d, "getItems", "listItems")) or {}) do n = n + 1 end
        return n
      end,
    }
    if has(dev, "getTotalItemStorage") then
      read["storage.total"] = function(d) return d.call("getTotalItemStorage"), "items" end
      read["storage.used"] = function(d) return d.call("getUsedItemStorage"), "items" end
      read["storage.available"] = function(d) return d.call("getAvailableItemStorage"), "items" end
      read["storage.percent"] = function(d)
        local total = d.call("getTotalItemStorage")
        if not total or total == 0 then return 0, "%" end
        return d.call("getUsedItemStorage") / total * 100, "%"
      end
    end
    return {
      caps = { "storage_network", "energy" },
      read = read,
      act = {
        --- dev:act("network.craft", "minecraft:stick", 16)
        ["network.craft"] = function(d, item, count)
          local f = itemFilter(item)
          f.count = tonumber(count) or f.count or 1
          local ok, res, err = pcall(d.call, "craftItem", f)
          if not ok then return nil, tostring(res) end
          if res == false or res == nil then return nil, tostring(err or "the network cannot craft that right now") end
          return true
        end,
      },
    }
  end,
}

local environment = {
  id = "advancedperipherals.environment",
  match = function(dev)
    if kind(dev) ~= "environmentdetector" then return nil end
    return {
      caps = { "sensor", "environment" },
      read = {
        ["env.time"] = function(d) return d.call("getTime") end,
        ["env.raining"] = function(d) return d.call("isRaining") end,
        ["env.thunder"] = function(d) return d.call("isThunder") end,
        ["env.dimension"] = function(d) return d.call("getDimension") end,
        ["env.biome"] = function(d) return d.call("getBiome") end,
        ["env.slime_chunk"] = function(d) return d.call("isSlimeChunk") end,
      },
    }
  end,
}

local energyDetector = {
  id = "advancedperipherals.energy_detector",
  match = function(dev)
    if kind(dev) ~= "energydetector" then return nil end
    return {
      caps = { "sensor", "energy_flow" },
      read = {
        ["energy.transfer"] = function(d) return d.call("getTransferRate"), "FE/t" end,
        ["energy.transfer_limit"] = function(d) return d.call("getTransferRateLimit"), "FE/t" end,
      },
      act = {
        ["energy.set_limit"] = function(d, n) d.call("setTransferRateLimit", math.max(0, math.floor(tonumber(n) or 0))) return true end,
      },
    }
  end,
}

local players = {
  id = "advancedperipherals.player_detector",
  match = function(dev)
    if kind(dev) ~= "playerdetector" then return nil end
    return {
      caps = { "sensor", "players" },
      read = {
        ["players.online"] = function(d) return #d.call("getOnlinePlayers") end,
        --- dev:get("players.in_range", 16) -> number of players within 16 blocks
        ["players.in_range"] = function(d, range) return #d.call("getPlayersInRange", tonumber(range) or 16) end,
        ["players.present"] = function(d, range) return #d.call("getPlayersInRange", tonumber(range) or 16) > 0 end,
        ["players.names"] = function(d) return d.call("getOnlinePlayers") end,
      },
    }
  end,
}

return { bridge, environment, energyDetector, players }
