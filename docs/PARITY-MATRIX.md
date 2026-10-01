# Feature Parity Matrix

Goal: before we differentiate, cover **everything the existing CC operating systems and ecosystem tools cover**.
Each row = a capability area; "Exemplars" = where it already exists; "Our module" = where it lives in this project;
Pri: **P0** foundation, **P1** v1 target, **P2** later, **P3** stretch. Status: `todo` / `design` / `wip` / `done`.
Exemplar details come from docs/RESEARCH.md (sources there); keep this file updated as work lands.

| # | Area | Exemplars | Our module | Pri | Status |
|---|---|---|---|---|---|
| 1 | Multitasking / process mgmt | Opus tabs, Phoenix kernel, PotatOS Polychoron, multishell | `core` scheduler | P0 | wip |
| 2 | CraftOS compatibility | Recrafted, MBS | `core/compat` | P0 | wip |
| 3 | Shell (history, completion, pipes, scripting) | cash (Bourne-like), MBS | `ui/shell` | P0 | design |
| 4 | Virtual FS, mounts, quotas, permissions | Phoenix, PotatOS virtual FS | `core/vfs` | P0 | wip |
| 5 | Boot/init/service mgr | Phoenix pxboot/startmgr | `core/boot`, `services/manager` | P0 | wip |
| 6 | Settings/registry, declarative config | PotatOS registry, cOS | `core/config` | P0 | wip |
| 7 | Logging, crash handling, recovery | — | `core/log`, `installer/repair` | P0 | wip |
| 8 | Package manager (deps, versions, sources) | unicornpkg, CCPM, ccpkg, Opus store | `pkg` | P0 | wip |
| 9 | App store UI | Opus, OneOS store, PineStore | `ui/gui` + `pkg` | P1 | todo |
| 10 | Installer wizard + hw detect/recommend | (none comparable) | `installer` | P0 | wip |
| 11 | Users, login, lock screen | Redworks, PotatOS | `core/auth` | P1 | todo |
| 12 | Windowing GUI / desktop | OneOS, LevelOS, Opus, Phoenix WM | `ui/gui` (optional) | P1 | todo |
| 13 | UI toolkit | Basalt, GuiH, Tamper | `ui/toolkit` | P1 | todo |
| 14 | Mobile shell | (none) | `profiles/pocket` | P1 | todo |
| 15 | Smart-TV shell | (none) | `profiles/tv` | P2 | todo |
| 16 | File manager | Opus, OneOS | `apps/files` | P1 | todo |
| 17 | Text editor / IDE / vim | edit, CCVim, Consult, LuaIDE | `apps/edit` (+ optional pkgs) | P1 | todo |
| 18 | Lua REPL / debugger | Opus REPL | `apps/lua` | P1 | todo |
| 19 | Rednet/modem networking, discovery | rednet, Opus | `net` | P0 | design |
| 20 | Secure comms & pairing | ecnet, ecc, rawshell | `net/secure` | P1 | todo |
| 21 | Remote shell / telnet | netshell, rawshell, Opus telnet | `net/shell` | P1 | todo |
| 22 | Remote screen (VNC-like) | Opus VNC | `net/vnc` | P2 | todo |
| 23 | Remote FS / file sync | Opus remote FS, Netmount | `net/fs` | P1 | wip |
| 24 | Package mirror over rednet (HTTP-less clients) | — | `services/pkgmirror` | P1 | todo |
| 25 | Browser/outside access, web gateway | Cloud Catcher, Ultron Control | `services/gateway` + external | P2 | todo |
| 26 | Encryption (hash, HMAC, ChaCha, ECC, FS encryption, signing) | Anavrins libs, ecc, FSEncrypt, VeriCode | `lib/crypto` | P1 | wip |
| 27 | Scheduler / cron / alarms | — | `services/cron` | P1 | todo |
| 28 | Telemetry / metrics dashboards | Telem | `services/metrics` | P2 | todo |
| 29 | GPS host/client, waypoints, maps | stock gps | `services/gps`, `apps/maps` | P1 | wip |
| 30 | Audio (DFPWM, streams, trackers) | AUKit, austream, Musicify, tracc | `apps/audio` | P2 | wip |
| 31 | Video/image (NFP/32vid, sanjuuni pipeline) | sanjuuni, YouCube | `apps/media` | P2 | todo |
| 32 | 2D/3D graphics libs | Pine3D, C3D, Pixelbox, GEMU | `lib/gfx` (wrap/depend) | P2 | todo |
| 33 | Games | CCDoom, CC-Minecraft, LuaGB, 8086, classics | packages (`games-*`) | P2 | wip |
| 34 | Printing / documents | printer periph, printshop | `apps/print` | P3 | wip |
| 35 | Storage/inventory system (index, sort, craft) | Artist, MISC, Milo | `services/storage` | P1 | wip |
| 36 | Redstone automation rules engine | — | `services/rules` | P1 | wip |
| 37 | Turtle framework (pathing, jobs, fuel) | Opus turtle API, TurtleOS | `profiles/turtle` | P1 | wip |
| 38 | Turtle stock jobs (mine, quarry, farm, tree, build) | many scripts | `apps/turtle-*` | P1 | wip |
| 39 | Swarm/fleet control + pocket remote | Ultron Control, Opus follow | `services/fleet` | P2 | wip |
| 40 | Reactor/power/SCADA | cc-mek-scada, Draconic/BigReactors ctl | `integrations/*` | P2 | todo |
| 41 | Mod integrations (see INTEGRATIONS.md) | AP, CC:C Bridge, Mekanism… | `integrations/*` | P1 | design |
| 42 | Economy / shops | Kristify, Radon, LP | `apps/shop` | P3 | todo |
| 43 | Chat bot / Chat Box tools | AP Chat Box | `services/chatbot` | P2 | todo |
| 44 | Themes, fonts (bigfont), accessibility | Bigfont, OneOS | `ui/theme` | P2 | todo |
| 45 | Recycle bin, backup, snapshots | PotatOS | `services/backup` | P2 | todo |
| 46 | Help/docs system, first-run tutorial | CraftOS `help` | `apps/help` | P1 | todo |
| 47 | Dev tooling (build, emulator harness, test runner) | Howl, CraftOS-PC | `tools/` | P0 | todo |
| 48 | Multi-computer scripting | Opus | `net/exec` | P2 | todo |
| 49 | Virtualization/emulators | OrangeBox, lunatic86, LuaGB | packages | P3 | todo |
| 50 | Kiosk / digital signage | — | `profiles/tv` | P3 | todo |

Status notes (2026-09-29): rows 1, 2, 4-8 and 10 are `wip` = a working first version exists and is tested in CraftOS-PC, but the
row's end-to-end criterion is not met yet (no per-process sandbox/permissions, no service manager, no in-game test).
Row 26: hashing (SHA-256, CRC-32, base64, DEFLATE inflate) is done; ciphers, signatures and ECC are not started.

Apps wave (see docs/APPS.md): rows 23 (file sync), 29 (GPS), 30 (audio), 33 (a text game), 34 (printing), 35 (storage), 36 (redstone
sequences), 37-39 (turtle framework, stock jobs, remote control) now have tested first versions and are `wip` until they have been run in real Minecraft.

Rule: an area is only "done" when a user can accomplish the task end-to-end on a stock CC:T server without extra mods
(except where the area is mod-specific).
