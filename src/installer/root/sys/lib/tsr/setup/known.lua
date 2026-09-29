-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Signatures of mods whose peripherals we recognise, matched against peripheral type names (Lua patterns).
-- `verified` records where the type names come from; entries marked false are educated guesses that MUST be checked
-- in-game (see docs/INTEGRATIONS.md) and refined — a wrong pattern only means a missed recommendation, never a wrong
-- install, because the wizard always shows every recommendation and its reason for the user to accept.
return {
  {
    id = "advancedperipherals", name = "Advanced Peripherals", verified = "docs.advanced-peripherals.de (peripheral list)",
    types = { "^meBridge$", "^rsBridge$", "^chatBox$", "^playerDetector$", "^inventoryManager$", "^energyDetector$",
              "^environmentDetector$", "^blockReader$", "^geoScanner$", "^redstoneIntegrator$", "^nbtStorage$",
              "^arController$", "^colonyIntegrator$" },
  },
  {
    id = "mekanism", name = "Mekanism", verified = false,
    types = { "[Ff]ission", "[Ff]usion", "[Ii]nductionPort", "[Tt]hermalEvaporation", "[Dd]igitalMiner",
              "[Tt]urbineValve", "[Bb]oilerValve", "[Ee]nergyCube", "[Ww]asteBarrel" },
  },
  { id = "create", name = "Create (CC:C Bridge / Additions)", verified = false, types = { "^Create_", "^create_" } },
  { id = "tomsperipherals", name = "Tom's Peripherals", verified = false, types = { "^tm_" } },
  { id = "plethora", name = "Plethora", verified = false, types = { "^neuralInterface$", "^manipulator$" } },
}
