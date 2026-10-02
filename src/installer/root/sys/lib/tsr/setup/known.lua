-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Signatures of mods whose peripherals we recognise, matched against peripheral type names (Lua patterns).
-- `verified` says where the names come from (docs/RESEARCH.md section 9). Advanced Peripherals renamed its types at Minecraft
-- 1.21.1 (camelCase -> snake_case), so every pattern accepts both spellings.
return {
  {
    id = "advancedperipherals", name = "Advanced Peripherals", verified = "docs.advanced-peripherals.de",
    types = { "^me_?[bB]ridge$", "^rs_?[bB]ridge$", "^chat_?[bB]ox$", "^player_?[dD]etector$", "^inventory_?[mM]anager$",
              "^energy_?[dD]etector$", "^environment_?[dD]etector$", "^block_?[rR]eader$", "^geo_?[sS]canner$",
              "^redstoneIntegrator$", "^nbt_?[sS]torage$", "^ar_?[cC]ontroller$", "^colony_?[iI]ntegrator$" },
  },
  {
    id = "mekanism", name = "Mekanism", verified = "mod source: MekanismBlockTypes / GeneratorsBlockTypes (1.21.x)",
    types = { "^fissionReactor", "^fusionReactor", "^inductionPort$", "^turbineValve$", "^boilerValve$", "^dynamicValve$",
              "^%l+EnergyCube$", "^%l+Bin$", "^%l+FluidTank$", "^%l+ChemicalTank$", "^digitalMiner$", "^qio[A-Z]",
              "^thermalEvaporation", "^radioactiveWasteBarrel$", "^enrichmentChamber$", "^spsPort$" },
  },
  { id = "create", name = "Create (native + CC:C Bridge)", verified = "Create source (compat/computercraft) and cccbridge.kleinbox.dev",
    types = { "^create_source$", "^create_target$", "^Create_Speedometer$", "^Create_Stressometer$", "^Create_RotationSpeedController$",
              "^Create_CreativeMotor$", "^Create_SequencedGearshift$", "^Create_DisplayLink$", "^Create_NixieTube$", "^Create_Station$",
              "^Create_Signal$", "^Create_TrainObserver$", "^Create_StockTicker$" } },
  { id = "tomsperipherals", name = "Tom's Peripherals", verified = "mod source (tm_gpu, tm_keyboard, tm_rsPort, tm_wdt)", types = { "^tm_gpu$", "^tm_keyboard$", "^tm_rsPort$", "^tm_wdt$" } },
  { id = "plethora", name = "Plethora", verified = false, types = { "^neuralInterface$", "^manipulator$" } },
}
