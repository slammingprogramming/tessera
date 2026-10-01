# Research Notes

Research snapshot: **2026-09-29**. Everything here was fetched from the sources listed at the bottom unless tagged
**[unverified]** (from prior knowledge; confirm before relying on it). Re-check volatile facts (versions, download counts,
mod support) before any release. Add new findings here, with a source and a date.

---

## 1. Is CC: Tweaked the community standard? — Yes

| Fact | Value (2026-09-29) | Source |
|---|---|---|
| Modrinth downloads | 5.2 M, 846 followers | Modrinth page |
| Latest release | Mod 1.120.3 for MC "26.3" (released 28 Sep 2026; NeoForge compat fix) | GitHub releases |
| Supported MC versions | 1.15.2, 1.16.4–1.16.5, 1.17.1, 1.18.x, 1.19.x, 1.20–1.20.6, 1.21–1.21.1, 1.21.7–1.21.8, 1.21.11 (+ the new year-style 26.x line) | Modrinth |
| Loaders | Fabric, Forge, NeoForge | Modrinth |
| License | CCPL (ComputerCraft Public License) | Modrinth |
| Distribution | **No longer published on CurseForge — Modrinth is the official download** | CurseForge page |
| GitHub | `cc-tweaked/CC-Tweaked`, ~1.2 k stars, 291 forks | GitHub |
| Docs | https://tweaked.cc (updated 2026-09-28) | tweaked.cc |

Conclusions:
- Original ComputerCraft (Dan200) is effectively abandoned; CC: Tweaked is the maintained fork and the de-facto standard.
  The old "CC: Restitched" Fabric port is superseded now that CC:T itself ships for Fabric.
- Minecraft is moving to year-based version numbers (26.x). The mod ships separate builds per MC version, so the OS must
  not assume a specific MC version; it should key off CC:T's Lua-visible behaviour (`_HOST`, `os.version()`) and feature
  detection, never MC version.
- Practical target set for compatibility testing: **1.20.1 and 1.21.1** (where Advanced Peripherals and most addons are
  actively supported) plus the **latest 26.x**.
- Release 1.120.1 made a breaking change: pocket computer upgrade slot renamed "bottom" → "top". The tweaked.cc `pocket`
  module page still documents `equipBack()`/`unequipBack()`. **Verify current names in-game before writing pocket code.**

---

## 2. Platform facts the OS must design around

### 2.1 Lua API surface (tweaked.cc)
Globals/APIs: `_G, colors/colours, commands, disk, fs, gps, help, http, io, keys, multishell, os, paintutils, parallel,
peripheral, pocket, rednet, redstone, settings, shell, term, textutils, turtle, vector, window`.
Modules (`require`): `cc.audio.dfpwm, cc.base64, cc.completion, cc.expect, cc.image.nft, cc.pretty, cc.require,
cc.shell.completion, cc.strings`.

Built-in peripherals: `command, computer, drive, modem, monitor, printer, redstone_relay, speaker`.
Generic peripherals (any modded block exposing the capability): `energy_storage, fluid_storage, inventory`.

Events: `alarm, char, computer_command, disk, disk_eject, file_transfer, http_check, http_failure, http_success, key,
key_up, modem_message, monitor_resize, monitor_touch, mouse_click, mouse_drag, mouse_scroll, mouse_up, paste,
peripheral, peripheral_detach, rednet_message, redstone, setting_changed, speaker_audio_empty, task_complete,
term_resize, terminate, timer, turtle_inventory, websocket_closed, websocket_failure, websocket_message,
websocket_success`.

### 2.2 Hard limits (drive the "no bloat / web-first" requirement)
- **Computer/turtle disk space: 1,000,000 bytes by default** (`computer_space_limit`). The OS core + installed apps must
  fit in <1 MB on a stock server; anything else must be fetched on demand or live on a mounted disk / remote mount.
- Floppy disks: **125,000 bytes** default (`floppy_space_limit`) [as reported by a config search; confirm].
- HTTP defaults (`computercraft-server.toml`, `[[http.rules]]`): private/LAN addresses **denied**; per rule max upload
  4,194,304 B, max download 16,777,216 B, timeout 30 s, websocket message 131,072 B. Servers may whitelist only a few
  domains or disable HTTP entirely. → The installer must probe HTTP and offer an offline/LAN path.
- Config file location (MC 1.13+): `<world>/serverconfig/computercraft-server.toml`.
- Coroutines that don't yield are killed ("too long without yielding") **[unverified: ~7 s]** → the kernel must be
  cooperative; true preemption is not available in stock CC:T. (Phoenix claims preemptive multitasking — investigate how;
  see backlog.)
- Screen sizes **[unverified]**: computer 51×19, turtle 39×13, pocket 26×20, monitors up to 8×6 blocks by default config.
  Basic (non-advanced) computers/turtles/pockets are grayscale and have no mouse input; advanced ones have 16-colour
  palettes, mouse events and monitor touch. Detect with `term.isColor()`, never by name.

### 2.3 GPS
Needs 4 host computers with (ender) modems: 3 at ground-level corners + 1 above; `gps host x y z` in each `startup`;
larger constellations = better accuracy (a 10×10×10 cube is optimal, 5×5×5 still works over thousands of blocks); all hosts
must stay chunk-loaded. → Server OS should ship a "GPS host" role that automates this.

### 2.4 Turtle API (tweaked.cc)
Movement: forward/back/up/down/turnLeft/turnRight (fuel per move, not per turn). Dig/place/attack ×3 directions.
Inventory: select, getItemCount/Space/Detail, drop/suck ×3, transferTo, compare*. Sensing: detect*, inspect*, compare*.
Crafting: `craft`. Fuel: getFuelLevel/getFuelLimit/refuel (normal 20,000, advanced 100,000). Upgrades: equipLeft/Right,
getEquipped*; tools = diamond pickaxe/axe/shovel/hoe/sword, wireless/ender modem, speaker (+ modded upgrades).

### 2.5 Pocket API
`pocket.equipBack()`, `pocket.unequipBack()` (see §1 caveat about the renamed slot).

---

### 2.6 Local dev environment (verified 2026-09-29 on the user's machine)
CraftOS-PC **2.8.3** at `C:Program FilesCraftOS-PC` (`CraftOS-PC.exe`, `CraftOS-PC_console.exe`, `rom/`, `bios.lua`,
`lua52.dll`); user data at `%APPDATA%CraftOS-PC{computer,config}`. It reports `_HOST` "ComputerCraft 1.112.0
(CraftOS-PC v2.8.3)", `_VERSION` = Lua 5.2, supports `goto`, exposes `debug.sethook`. **Headless mode prints terminal frames
to stdout and exits 0 - read results from a mounted directory** (`--mount-rw out=<dir>`; the script writes a file, then
`os.shutdown()`). Monitors cannot be created headless (`periphemu.create` errors); speaker/drive/modem can. In this
emulator `fs.getFreeSpace("/")` returns ~10^12 (host disk), unlike a real 1 MB computer. CLI flags: `--headless`, `--cli`,
`--raw`, `--script`, `--exec`, `--mount[-ro|-rw] <path>=<dir>`, `-d <dir>`, `--id`. Because the VM is Lua 5.2 (not Cobalt),
never trust emulator-only results for VM-sensitive behaviour. Known Cobalt difference, learned via a failing run:
`string.format("%d", n)` raises "not a number in proper range" for |n| >= 2^31 (use `%.0f`). Node 24.18, Python 3.13.2,
Git 2.49 available; no standalone Lua.

## 3. Existing operating systems ("parity targets")

| Project | Notes | Source |
|---|---|---|
| **CraftOS** | Stock shell/ROM in every computer. Baseline compatibility target. | wiki.computercraft.cc |
| **Opus OS** | MIT, ~199★, branch develop-1.8. Tabbed multitasking, GUI, UI API, telnet + VNC, remote FS across wireless, file manager, Lua REPL, multi-computer script runner, turtle API with A* pathfinding, GPS-follow/return. Install: `pastebin run UzGHLbNC`. Apps: Milo (storage/crafting; needs Plethora). | GitHub, awesome-CC |
| **PotatOS** (osmarks) | Satirical; background processes, keyboard shortcuts, registry, virtual FS, recycle bin, SPUDNET websockets, capability-level process security via Polychoron. **Notorious for being installed on servers against admins' wishes — we must never replicate that behaviour.** | potatos.madefor.cc |
| **Phoenix** (JackMacWindows) | "Next-gen modular OS": kernel, pxboot bootloader, libsystem/libcraftos, startmgr init, window manager, filesystem permissions, virtual device tree, claims preemptive multitasking. Alpha. Recommends ~2 MB storage. Closest architectural peer. | phoenix.madefor.cc |
| **Recrafted** | CraftOS rewrite with improved API design. | awesome-CC |
| **cOS** | NixOS-inspired declarative config OS. | awesome-CC |
| **LevelOS** | Windows-like GUI OS. | awesome-CC |
| **UnBIOS** | Resets system to pre-BIOS state so an OS can take over fully. Key technique for deep replacement. | awesome-CC |
| OneOS, Redworks, LyqydOS, Craftbang, TurtleOS | Historic forum OSes (multitasking desktop, login system, app collections; LyqydOS supported both advanced and basic computers). | computercraft.info wiki |
| Forums | OS boards: computercraft.info forums (archive at ccf.squiddev.cc) and forums.computercraft.cc. | — |

## 4. Package managers / distribution

| Project | Notes |
|---|---|
| **unicornpkg** | Modern, GitHub-based; default repo `unicornpkg/unicornpkg-main`; custom remotes, multiple providers, Lua API, CLI. v1.4.0 (Nov 2025). Best interop candidate. |
| **CCPM** + CCPM-Registry | Registry stores metadata only: per-package `package.json` + one `<version>.json` manifest listing file URLs + SHA-256. Mirrors Pinestore packages as `pinestore/<name>`. Good model for our manifest. |
| **PineStore** (pinestore.cc) | Community app store. |
| **ccpkg** (ccpkg.netlify.app) | Vetted central distribution of libs/programs. |
| CCPT, cc-packman (GopherAtl/lyqyd), cpm | Older apt-style managers. |
| pastebin / gist / `wget` | The universal bootstrap. `wget run <url>` is the standard one-line install. |

## 5. Libraries & tools worth integrating, wrapping or matching

- **GUI:** Basalt (Pyroxenium; Basalt2 exists), GuiH, Tamper.
- **Graphics:** Pine3D, C3D, IsometriH, Pixelbox Lite, GEMU, Bigfont.
- **Networking/remote:** ecnet (secure comms), netshell, rawshell, ModemShark, Turtleshell, Cloud Catcher (browser access to in-game computers), Netmount (remote storage via WebSocket/WebDAV), Ultron Control (web API for turtles).
- **Crypto:** ecc.lua, ChaCha20/SHA-256/SHA-1/MD5 (Anavrins), VeriCode (code signing), FSEncrypt.
- **Media:** AUKit, austream, Musicify, tracc, YouCube, sanjuuni (image/video → CC formats; needs an external converter), DFPWM converters.
- **Storage/crafting:** Artist, MISC, Milo (Opus+Plethora), hopper.lua.
- **Shell/editors:** cash (Bourne-compatible), MBS (scrollback etc.), CCVim, Consult, LuaIDE.
- **Economy:** Krist ecosystem (Kristify, Radon, LP, msks…).
- **Mod SCADA examples:** cc-mek-scada (Mekanism fission), Draconic/Big Reactors control programs.
- **Utility:** CC-Archive, Luz (compression), dbprotect, RedRun, Telem (telemetry), pngLua, OrangeBox (virtualization).
- **Dev tooling:** CraftOS-PC (fast C++ emulator, peripheral emulation, headless), CCEmuX, Copy Cat (browser), Howl (build), cc-tstl-template (TypeScript→Lua), VS Code extensions.
- **Games/apps ported to CC:** CCDoom, CC-Minecraft (Pine3D), LuaGB (Game Boy), lunatic86 (8086 PC), Battleship, Yahtzee.

Licensing of each must be checked before bundling/porting (see DECISIONS D-08).

## 6. Mod integrations (ComputerCraft ecosystem)

| Mod | What it exposes | Notes |
|---|---|---|
| **Mekanism** | Native CC:T support (annotations `@ComputerMethod`): machines, tanks, reactors, turbines, digital miner, etc. | Advanced Peripherals' Mekanism integration was **removed** (v0.7.7r) because Mekanism now does it. |
| **Advanced Peripherals** | 13 peripherals: Chat Box, Energy Detector, Environment Detector, Player Detector, Inventory Manager, NBT Storage, Block Reader, Geo Scanner, Redstone Integrator, AR Controller, ME Bridge (AE2), RS Bridge (Refined Storage), Colony Integrator (MineColonies). Integrations: Beacon, Note Block, Botania (flowers, mana pool/spreader), Create (basin, blaze burner, fluid tank, mixer, scroll behaviour), Draconic Evolution, Immersive Engineering (connector, probe), Integrated Dynamics (variable store), Powah, Storage Drawers. | MC 1.16.5–1.21.1; only 1.20.1 and 1.21.1 get full updates. |
| **CC:C Bridge** | Create: Source/Target blocks, displays (Flip Display, Nixie Tubes, lecterns, signs), animatronics, RedRouter. | 1.19.2, 1.20.1–1.20.2, 1.21.1; Apache-2.0; ~745 k downloads. |
| **Create Crafts & Additions** | Electric motor etc. as peripherals. | |
| **Tom's Peripherals** | GPU + bitmap monitors (up to 64×64 res per monitor block; PNG load/save), keyboard, redstone port, watchdog timer. MIT. MC 1.18.2–1.21.1. | Enables real high-res GUI/smart-TV. |
| **Storage for ComputerCraft** | RS and AE2 peripherals (query items/fluids/patterns, craft, extract). | Alternative to AP bridges. |
| **More Immersive Wires** | Lets IE wires carry AE/RS/CC peripheral connections. | |
| **Plethora, Computronics, Classic Peripherals, Turtlematic, UnlimitedPeripheralWorks, sc-peripherals (SwitchCraft), Roadworks** | Various (sensors/neural interface, sound, radio, crypto, 3D printers, traffic lights). | Mostly older MC; verify per version. |
| Generic peripherals (built into CC:T) | `inventory`, `fluid_storage`, `energy_storage` for **any** mod that exposes those capabilities. | Our HAL should prefer these — covers most modded machines with zero per-mod code. |

Where no CC integration exists: fall back to redstone (`redstone`, `redstone_relay`, bundled cables via `colors` on
mods that support them, comparator reads, AP Redstone Integrator). See INTEGRATIONS.md.

## 7. Backlog — still to research

1. How Phoenix achieves "preemptive" multitasking; is `debug.sethook`/instruction limiting exposed in CC:T's Cobalt VM?
2. Exact CC:T Lua feature level (Cobalt: 5.1 + which 5.2/5.3 additions) and `_HOST` string format for detection.
3. Current tweaked.cc behaviours for: `fs` mounting APIs (`fs.attributes`, `fs.getCapacity`), `peripheral.hasType`, `require` search paths.
4. Refined Storage / AE2 current CC support on 1.21.1 and 26.x.
5. Tom's Simple Storage, Sophisticated Storage, Thermal, Ender IO, Powah, Flux Networks, Valkyrien Skies (CC:VS), Create: Trains — CC support status.
6. Licenses: Basalt, Pine3D, ecc, ecnet, cash, MBS, unicornpkg, Opus (MIT) — for reuse vs. compatibility-only.
7. Signing scheme feasible in Lua performance-wise (ed25519 verify time on a stock computer).
8. Server-admin norms: how servers restrict HTTP; how to make installs admin-friendly.
9. Existing "smart TV / kiosk / video" pipelines (sanjuuni formats: NFP, 32vid; YouCube protocol).
10. Bundled-cable mods (Project Red, Immersive Engineering?, RFTools?) status on 1.20.1/1.21.1.

## 8. Sources

- https://modrinth.com/mod/cc-tweaked
- https://github.com/cc-tweaked/CC-Tweaked and /releases
- https://www.curseforge.com/minecraft/mc-mods/cc-tweaked
- https://tweaked.cc/ , /module/turtle.html , /module/pocket.html , /guide/local_ips.html , /guide/gps_setup.html
- https://github.com/tomodachi94/awesome-computercraft (README)
- https://computercraft.info/wiki/Category:OSes
- https://github.com/kepler155c/opus
- https://potatos.madefor.cc/
- https://phoenix.madefor.cc/
- https://unicornpkg.madefor.cc/
- https://github.com/SorcerioTheWizard/CCPM-Registry , https://pinestore.cc/ , https://ccpkg.netlify.app/
- https://docs.advanced-peripherals.de/0.7/ and /integrations/mekanism/
- https://modrinth.com/mod/cccbridge
- https://modrinth.com/mod/toms-peripherals
- https://www.curseforge.com/minecraft/mc-mods/storage-for-computercraft
- https://github.com/MikaylaFischler/cc-mek-scada
- https://github.com/AllTheMods/ATM-4 (config example), https://www.craftos-pc.cc/docs/config
