# Feature Parity Matrix

Goal: before we differentiate, cover **everything the existing CC operating systems and ecosystem tools cover**.
Each row = a capability area; "Exemplars" = where it already exists; "Our module" = where it lives in this project;
Pri: **P0** foundation, **P1** v1 target, **P2** later, **P3** stretch. Status: `todo` / `design` / `wip` / `done`.
Exemplar details come from docs/RESEARCH.md (sources there); keep this file updated as work lands.

| # | Area | Exemplars | Our module | Pri | Status |
|---|---|---|---|---|---|
| 1 | Multitasking / process mgmt | Opus tabs, Phoenix kernel, PotatOS Polychoron, multishell | `core` scheduler | P0 | wip |
| 2 | CraftOS compatibility | Recrafted, MBS | `core` + `shell` | P0 | wip |
| 3 | Shell (history, completion, pipes, scripting) | cash (Bourne-like), MBS | `shell` (tsh) | P0 | wip |
| 4 | Virtual FS, mounts, quotas, permissions | Phoenix, PotatOS virtual FS | `core/vfs` | P0 | wip |
| 5 | Boot/init/service mgr | Phoenix pxboot/startmgr | `core/boot`, `svc-manager` | P0 | wip |
| 6 | Settings/registry, declarative config | PotatOS registry, cOS | `core/config` | P0 | wip |
| 7 | Logging, crash handling, recovery | — | `core/log`, startup recovery | P0 | wip |
| 8 | Package manager (deps, versions, sources) | unicornpkg, CCPM, ccpkg, Opus store | `pkg` | P0 | wip |
| 9 | App store UI | Opus, OneOS store, PineStore | `ui-gui` App Store | P1 | wip |
| 10 | Installer wizard + hw detect/recommend | (none comparable) | `installer` | P0 | wip |
| 11 | Users, login, lock screen | Redworks, PotatOS | `auth` | P1 | wip |
| 12 | Windowing GUI / desktop | OneOS, LevelOS, Opus, Phoenix WM | `ui-gui` | P1 | wip |
| 13 | UI toolkit | Basalt, GuiH, Tamper | `ui-gui` widgets, `ui-tui` | P1 | wip |
| 14 | Mobile shell | (none) | `mobile` | P1 | wip |
| 15 | Smart-TV shell | (none) | `tv` | P2 | wip |
| 16 | File manager | Opus, OneOS | `ui-gui` Files, `utils` fm | P1 | wip |
| 17 | Text editor / IDE / vim | edit, CCVim, Consult, LuaIDE | `editor` (ted) | P1 | wip |
| 18 | Lua REPL / debugger | Opus REPL | `utils` repl | P1 | wip |
| 19 | Rednet/modem networking, discovery | rednet, Opus | `net` | P0 | wip |
| 20 | Secure comms & pairing | ecnet, ecc, rawshell | `net` pairing + signed/encrypted calls | P1 | wip |
| 21 | Remote shell / telnet | netshell, rawshell, Opus telnet | `rsh` | P1 | wip |
| 22 | Remote screen (VNC-like) | Opus VNC | `rscreen` | P2 | wip |
| 23 | Remote FS / file sync | Opus remote FS, Netmount | `netfs`, `filesync` | P1 | wip |
| 24 | Package mirror over rednet (HTTP-less clients) | — | `pkg-mirror` | P1 | wip |
| 25 | Browser/outside access, web gateway | Cloud Catcher, Ultron Control | `webgw` + `tools/gateway` | P2 | wip |
| 26 | Encryption (hash, HMAC, ChaCha, ECC, FS encryption, signing) | Anavrins libs, ecc, FSEncrypt, VeriCode | `core/hash`, `net/crypto` (no ECC/signing yet) | P1 | wip |
| 27 | Scheduler / cron / alarms | — | `ops` cron | P1 | wip |
| 28 | Telemetry / metrics dashboards | Telem | `ops` metrics, `power-monitor` | P2 | wip |
| 29 | GPS host/client, waypoints, maps | stock gps | `gps` | P1 | wip |
| 30 | Audio (DFPWM, streams, trackers) | AUKit, austream, Musicify, tracc | `audio`, `media` | P2 | wip |
| 31 | Video/image (NFP/32vid, sanjuuni pipeline) | sanjuuni, YouCube | `media` (BIMG, NFP, DFPWM; 32vid not supported) | P2 | wip |
| 32 | 2D/3D graphics libs | Pine3D, C3D, Pixelbox, GEMU | `gfx` | P2 | wip |
| 33 | Games | CCDoom, CC-Minecraft, LuaGB, 8086, classics | `games`, `game-mork` | P2 | wip |
| 34 | Printing / documents | printer periph, printshop | `print` | P3 | wip |
| 35 | Storage/inventory system (index, sort, craft) | Artist, MISC, Milo | `svc-storage` | P1 | wip |
| 36 | Redstone automation rules engine | — | `rules`, `redstone` | P1 | wip |
| 37 | Turtle framework (pathing, jobs, fuel) | Opus turtle API, TurtleOS | `turtle-core` (+ A* nav) | P1 | wip |
| 38 | Turtle stock jobs (mine, quarry, farm, tree, build) | many scripts | `excavate` family, farms, `build` | P1 | wip |
| 39 | Swarm/fleet control + pocket remote | Ultron Control, Opus follow | `fleet`, `turtle-remote` | P2 | wip |
| 40 | Reactor/power/SCADA | cc-mek-scada, Draconic/BigReactors ctl | `int-mekanism` (scada) | P2 | wip |
| 41 | Mod integrations (see INTEGRATIONS.md) | AP, CC:C Bridge, Mekanism… | `hal`, `int-ap`, `int-mekanism`, `int-create` | P1 | wip |
| 42 | Economy / shops | Kristify, Radon, LP | `shop` | P3 | wip |
| 43 | Chat bot / Chat Box tools | AP Chat Box | `chatbot` | P2 | wip |
| 44 | Themes, fonts (bigfont), accessibility | Bigfont, OneOS | `gfx` palettes + big fonts, `ui-gui` themes | P2 | wip |
| 45 | Recycle bin, backup, snapshots | PotatOS | `safety` (snap, trash) | P2 | wip |
| 46 | Help/docs system, first-run tutorial | CraftOS `help` | `help` | P1 | wip |
| 47 | Dev tooling (build, emulator harness, test runner) | Howl, CraftOS-PC | `tools/` | P0 | done |
| 48 | Multi-computer scripting | Opus | `rsh` (rexec) | P2 | wip |
| 49 | Virtualization/emulators | OrangeBox, lunatic86, LuaGB | `sandbox` (vm) | P3 | wip |
| 50 | Kiosk / digital signage | — | `tv` (signage, kiosk) | P3 | wip |

Status notes (2026-10-01): every area above now has a first version that is built and tested in CraftOS-PC (unit tests on a simulated
turtle world, fake peripherals and an in-memory network, plus boot and installer end-to-end runs). They stay `wip` until each has been run in
real Minecraft; `done` means that has happened (only the dev tooling row qualifies). Known gaps: 32vid video is not decoded (convert with
`sanjuuni --bimg`), no package signing, no ECC, Tom's Peripherals have no driver (type names unverified), mod method names beyond those listed in
docs/RESEARCH.md section 9 are checked at run time rather than assumed.

Rule: an area is only "done" when a user can accomplish the task end-to-end on a stock CC:T server without extra mods
(except where the area is mod-specific).
