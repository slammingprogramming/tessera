-- SPDX-License-Identifier: AGPL-3.0-or-later
-- HAL drivers for Mekanism's native ComputerCraft support. The peripheral type of a Mekanism block is its "computer name", camelCase and
-- checked against the mod's source (mekanism/Mekanism, branch 1.21.x, MekanismBlockTypes / GeneratorsBlockTypes): machines such as
-- digitalMiner or enrichmentChamber, multiblock ports (inductionPort, boilerValve, dynamicValve, turbineValve, fissionReactorPort,
-- fissionReactorLogicAdapter, fusionReactorPort, fusionReactorLogicAdapter, thermalEvaporationController...) and tiered blocks
-- (basicEnergyCube, eliteBin, ultimateFluidTank...). EVERY Mekanism machine with an energy buffer has getEnergy, getMaxEnergy,
-- getEnergyNeeded and getEnergyFilledPercentage, so the energy driver accepts them all.
-- Documented methods (mekanism.github.io, 10.7): energy cube getEnergy/getMaxEnergy/getEnergyFilledPercentage; digital miner
-- start/stop/isRunning/getState; fission reactor activate/scram/getStatus/getTemperature/setBurnRate/getFuel; fusion reactor
-- getTemperature/isIgnited/setInjectionRate/getProductionRate; turbine getFlowRate/getMaxFlowRate/getProductionRate/getSteam.
-- (energy.percent is computed from getEnergy/getMaxEnergy: the documentation does not say whether the *Percentage methods return
-- 0-1 or 0-100.) Further readings (damage, coolant, waste, burn rate) are offered only when the machine reports having those methods, so a
-- Mekanism version that lacks one simply does not list it.
local function isType(dev, ...)
  for _, t in ipairs(dev.types) do
    for _, want in ipairs({ ... }) do if t == want then return true end end
  end
  return false
end

local function methodSet(dev)
  local have = {}
  for _, m in ipairs(dev.methods()) do have[m] = true end
  return have
end

--- Reading that calls `method` and is only registered when the device has it. Extra converters turn the raw value into the unit.
local function optional(read, have, name, method, unit, convert)
  if not have[method] then return end
  read[name] = function(d)
    local v = d.call(method)
    if convert then v = convert(v) end
    return v, unit
  end
end

local TIER = { basic = true, advanced = true, elite = true, ultimate = true, creative = true }
local PLAIN = {}
for name in ("enrichmentChamber crusher energizedSmelter precisionSawmill osmiumCompressor combiner metallurgicInfuser purificationChamber " ..
  "chemicalInjectionChamber pressurizedReactionChamber chemicalCrystallizer chemicalDissolutionChamber chemicalInfuser chemicalOxidizer " ..
  "chemicalWasher rotaryCondensentrator electrolyticSeparator digitalMiner formulaicAssemblicator electricPump fluidicPlenisher " ..
  "solarNeutronActivator teleporter chargepad laser laserAmplifier laserTractorBeam resistiveHeater seismicVibrator fuelwoodHeater " ..
  "oredictionificator quantumEntangloporter logisticalSorter modificationStation isotopicCentrifuge nutritionalLiquifier " ..
  "antiprotonicNucleosynthesizer pigmentExtractor pigmentMixer paintingMachine dimensionalStabilizer qioDriveArray qioDashboard " ..
  "qioImporter qioExporter qioRedstoneAdapter dynamicValve boilerValve inductionPort thermalEvaporationController thermalEvaporationValve " ..
  "radioactiveWasteBarrel spsPort heatGenerator bioGenerator solarGenerator windGenerator gasBurningGenerator advancedSolarGenerator " ..
  "turbineValve fissionReactorPort fissionReactorLogicAdapter fusionReactorPort fusionReactorLogicAdapter"):gmatch("%S+") do
  PLAIN[name] = true
end

--- Is this a Mekanism machine? (a known computer name, or a tiered block such as basicEnergyCube)
local function isMekanism(dev)
  for _, t in ipairs(dev.types) do
    if PLAIN[t] then return true end
    local tier, rest = t:match("^(%l+)(%u%w+)$")
    if tier and TIER[tier] and (rest == "EnergyCube" or rest == "Bin" or rest == "FluidTank" or rest == "ChemicalTank") then return true end
  end
  return false
end

local energy = {
  id = "mekanism.energy",
  match = function(dev)
    if not isMekanism(dev) then return nil end
    local have = methodSet(dev)
    if not (have.getEnergy and have.getMaxEnergy) then return nil end
    return {
      caps = { "energy" },
      read = {
        -- Mekanism reports joules; 1 J = 0.4 FE, but the raw unit is kept so values match what the machine GUI shows
        ["energy.stored"] = function(d) return d.call("getEnergy"), "J" end,
        ["energy.capacity"] = function(d) return d.call("getMaxEnergy"), "J" end,
        ["energy.percent"] = function(d)
          local cap = d.call("getMaxEnergy")
          if not cap or cap == 0 then return 0, "%" end
          return d.call("getEnergy") / cap * 100, "%"
        end,
      },
    }
  end,
}

local fission = {
  id = "mekanism.fission",
  match = function(dev)
    if not isType(dev, "fissionReactor", "fissionReactorLogicAdapter", "fissionReactorPort") then return nil end
    local have = methodSet(dev)
    if not have.getStatus then return nil end
    local read = {
      ["reactor.running"] = function(d) return d.call("getStatus") == true end,
    }
    optional(read, have, "reactor.temperature", "getTemperature", "K")
    -- Units checked in the mod's source: getDamagePercent is ALREADY 0-100 (a rounded percentage); the *FilledPercentage methods return a
    -- fraction 0-1 (stored / capacity), so they are multiplied by 100 here.
    local fraction = function(v) return v * 100 end
    optional(read, have, "reactor.damage", "getDamagePercent", "%")
    optional(read, have, "reactor.coolant", "getCoolantFilledPercentage", "%", fraction)
    optional(read, have, "reactor.fuel", "getFuelFilledPercentage", "%", fraction)
    optional(read, have, "reactor.waste", "getWasteFilledPercentage", "%", fraction)
    optional(read, have, "reactor.heated_coolant", "getHeatedCoolantFilledPercentage", "%", fraction)
    optional(read, have, "reactor.actual_burn_rate", "getActualBurnRate", "mB/t")
    optional(read, have, "reactor.burn_rate", "getBurnRate", "mB/t")
    optional(read, have, "reactor.max_burn_rate", "getMaxBurnRate", "mB/t")
    local act = {}
    if have.activate then act["reactor.activate"] = function(d) d.call("activate") return true end end
    if have.scram then act["reactor.scram"] = function(d) d.call("scram") return true end end
    if have.setBurnRate then act["reactor.set_burn_rate"] = function(d, n) d.call("setBurnRate", tonumber(n) or 0) return true end end
    act["machine.start"], act["machine.stop"] = act["reactor.activate"], act["reactor.scram"]
    read["machine.running"] = read["reactor.running"]
    return { caps = { "reactor", "machine" }, read = read, act = act }
  end,
}

local fusion = {
  id = "mekanism.fusion",
  match = function(dev)
    if not isType(dev, "fusionReactor", "fusionReactorLogicAdapter", "fusionReactorPort") then return nil end
    local have = methodSet(dev)
    local read = {}
    optional(read, have, "reactor.temperature", have.getPlasmaTemperature and "getPlasmaTemperature" or "getTemperature", "K")
    optional(read, have, "reactor.case_temperature", "getCaseTemperature", "K")
    optional(read, have, "reactor.injection_rate", "getInjectionRate")
    optional(read, have, "reactor.production", "getProductionRate", "J/t")
    if have.isIgnited then read["reactor.running"] = function(d) return d.call("isIgnited") == true end end
    local act = {}
    if have.setInjectionRate then act["reactor.set_injection"] = function(d, n) d.call("setInjectionRate", math.floor(tonumber(n) or 0)) return true end end
    return { caps = { "reactor" }, read = read, act = act }
  end,
}

local turbine = {
  id = "mekanism.turbine",
  match = function(dev)
    if not isType(dev, "turbineValve", "industrialTurbine") then return nil end
    local have = methodSet(dev)
    local read = {}
    optional(read, have, "turbine.flow", "getFlowRate", "mB/t")
    optional(read, have, "turbine.max_flow", "getMaxFlowRate", "mB/t")
    optional(read, have, "turbine.production", "getProductionRate", "J/t")
    optional(read, have, "turbine.steam", "getSteam")
    return { caps = { "generator" }, read = read }
  end,
}

local miner = {
  id = "mekanism.digital_miner",
  match = function(dev)
    if not isType(dev, "digitalMiner") then return nil end
    local have = methodSet(dev)
    local read, act = {}, {}
    if have.isRunning then read["machine.running"] = function(d) return d.call("isRunning") == true end end
    if have.getState then read["machine.state"] = function(d) return d.call("getState") end end
    if have.start then act["machine.start"] = function(d) d.call("start") return true end end
    if have.stop then act["machine.stop"] = function(d) d.call("stop") return true end end
    return { caps = { "machine" }, read = read, act = act }
  end,
}

return { energy, fission, fusion, turbine, miner }
