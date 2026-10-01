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
    id = "mekanism", name = "Mekanism", verified = "mekanism.github.io computer data (10.7.0)",
    types = { "^fissionReactor", "^fusionReactor", "^inductionPort$", "^inductionMatrix$", "^industrialTurbine$",
              "^boilerValve$", "^energyCube$", "^digitalMiner$", "^qio[A-Z]", "^thermalEvaporation",
              "^radioactiveWasteBarrel$", "^chemicalTank$", "^dynamicTank$" },
  },
  { id = "create", name = "Create (CC:C Bridge)", verified = "cccbridge.kleinbox.dev", types = { "^create_source$", "^create_target$" } },
  { id = "tomsperipherals", name = "Tom's Peripherals", verified = false, types = { "^tm_" } },
  { id = "plethora", name = "Plethora", verified = false, types = { "^neuralInterface$", "^manipulator$" } },
}
