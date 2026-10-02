# Mod Integration Strategy

Order of preference for controlling anything modded:

1. **Native CC:T generic peripherals** (`inventory`, `fluid_storage`, `energy_storage`) — works for any mod exposing
   those capabilities.
2. **Mod's own CC integration** (Mekanism, Create Crafts & Additions…).
3. **Bridge/addon mods** (Advanced Peripherals, CC:C Bridge, Tom's Peripherals, Storage for ComputerCraft…).
4. **Redstone fallback** (redstone/redstone_relay/bundled cables/comparators) via the redstone capability driver.

Every integration ships as an `integration-<mod>` package: detection rule + drivers → capability classes + helpers +
sample apps. It is recommended by the installer only when matching peripherals are detected.

## Matrix (verified facts from research; MC support to be re-verified per release)

| Mod / addon | Route | Peripherals/capabilities to wrap | Pack | Status |
|---|---|---|---|---|
| CC:T core | native | drive, modem, monitor, printer, speaker, redstone_relay, command, inventory/energy/fluid | `hal-core` | design |
| Mekanism | native (v10+) | machines, tanks, reactors, turbines, digital miner, energy, chemical | `int-mekanism` | built; names and units checked against the mod's source |
| Advanced Peripherals | addon | Chat Box, Energy/Environment/Player Detector, Inventory Manager, NBT Storage, Block Reader, Geo Scanner, Redstone Integrator, AR Controller, ME Bridge, RS Bridge, Colony Integrator | `int-ap` | built; method names checked for 0.7 and 0.8, fallbacks for both |
| AP integrations | addon | Beacon, Note Block, Botania, Create (basin/blaze burner/tank/mixer/scroll), Draconic Evolution, Immersive Engineering, Integrated Dynamics, Powah, Storage Drawers | sub-packs | todo |
| Create | native CC peripherals (speedometer, stressometer, speed controller, creative motor, gearshift, display link, nixie tube...) and CC:C Bridge | readings, speed control, display links | `int-create` | built; names checked against the mod's source |
| Applied Energistics 2 | AP ME Bridge or Storage for ComputerCraft | items/fluids/patterns, craft, export | `integration-ae2` | todo |
| Refined Storage | AP RS Bridge or Storage for ComputerCraft (rs4cc) | same | `integration-rs` | todo |
| Tom's Peripherals | addon | GPU / bitmap monitors, keyboard, redstone port, watchdog | `hal-toms` | built; peripheral types verified against the mod's source |
| Immersive Engineering | AP / More Immersive Wires | connectors, probes; wires for peripherals | `integration-ie` | todo |
| MineColonies | AP Colony Integrator | colony requests | `integration-minecolonies` | todo |
| Plethora / Computronics / Classic Peripherals / sc-peripherals | legacy addons | check per MC version | community packs | backlog |

## Redstone fallback design

- Describe a device: `{name, kind, outputs = {side/colour → meaning}, inputs = {side/colour → meaning}}`.
- Sides via `redstone`/`redstone_relay`; bundled cables via `colors` mask; analog 0–15 signal levels; comparator reads
  for inventory fill/level; pulse/toggle/hold helpers; debounce; safe-state on shutdown.
- Rules engine (`services/rules`) consumes capabilities identically whether backed by a mod driver or by redstone.

## To research before building each pack
Current CC support on 1.20.1 / 1.21.1 / 26.x, method names, event behaviour, and versions dropped from AP (e.g. Mekanism
integration removed at AP 0.7.7r).

## Status of verification (2026-10-02)

The drivers were written and corrected against the **source code** of each mod (peripheral type names, method names, units), and are tested
against simulated peripherals. They have not been tried with the real mods in a running game; the first in-game test of each
mod should be `hal list` and then the pack's own command (`me`, `scada`, `cdisplay`). Where the mods differ between versions
(Advanced Peripherals 0.7 vs 0.8, units in Mekanism) the drivers pick the right form at run time instead of assuming.
