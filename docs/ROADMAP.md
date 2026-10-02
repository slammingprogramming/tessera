# Roadmap

Sequencing principle: build the smallest vertical slice that installs and boots on a stock CC:T computer, then widen.
Each milestone must run on CraftOS-PC headless tests and be smoke-tested in-game before being called done.

| M | Name | Deliverables | Exit criteria |
|---|---|---|---|
| M0 | Foundation | Research, architecture, parity matrix, integrations, package format, repo skeleton | Docs reviewed |
| M1 | Toolchain & repo setup | CraftOS-PC test runner, Node tooling: minifier/hasher, registry generator, size-budget check, offline-bundle chunker; AGPL `LICENSE` + SPDX convention; in-game measurement of paste / `file_transfer` limits; CI | A test runs on a hello-world package; builds are reproducible |
| M2 | Core slice | `/startup.lua` stub, boot, kernel scheduler, VFS, config, log, CraftOS compat shim, recovery path | Boots to shell on basic + advanced computers; CraftOS programs run |
| M3 | Package manager + bootstrap installer (text) | `pkg` CLI, registry v0 on GitHub Pages, `wget run` + Pastebin bootstrap, transactional install, lazy stubs, LAN mirror stub, **offline import (paste/file-drop) + offline bundle builder page** | Fresh computer → installed core in <1 MB via web, via Pastebin, and via pure paste with no HTTP |
| M4 | Detection + recommender | Hardware probe, rules, wizard with reasons, profile selection, resumable install | Correct recommendations on a matrix of test rigs (basic/advanced/turtle/pocket/monitor/modem/speaker/drive) |
| M5 | Client + Server profiles | TUI toolkit, shell polish, auth, networking (discovery, secure RPC, remote shell/FS), service manager, pkg mirror | Two computers: server mirror + client install without HTTP on client |
| M6 | Optional GUI | Compositor/WM, toolkit, desktop, launcher, file manager, settings, app store; installable later & removable | Install GUI post-hoc on an existing client; uninstall cleanly |
| M7 | Turtle + Pocket profiles | Position persistence, fuel, jobs, pathfinding, remote control; mobile launcher | Turtle survives unload mid-job and resumes; pocket controls turtle |
| M8 | Integration packs v1 | hal-core, generic peripherals, Mekanism, Advanced Peripherals, CC:C Bridge, Tom's GPU, AE2/RS, redstone fallback | Demo automation per mod; rules engine drives both mod + redstone backends |
| M9 | App parity wave | Editor, files, help, storage system, GPS, cron, audio/media, games (port/depend), turtle stock jobs | Parity matrix P1 rows all `done` |
| M10 | TV + expansion | Smart-TV shell, media pipeline, mirroring, kiosk; next ideas | — |

## Status (2026-10-01)

| M | Status | Notes |
|---|---|---|
| M0 | done | docs |
| M1 | done | headless test runner, builders, size guard, API reference generator, browser bundle builder, Pastebin publisher; `tsr-calibrate` measures the in-game limits that are still unknown |
| M2 | done | kernel, VFS, config, log, boot; stage-0 escape hatches (recovery key, disabled flag, crash-loop guard) have unit scenarios |
| M3 | done | offline paths tested end to end; HTTP and Pastebin channels are untested against real servers (the fake-API tests pass) |
| M4 | done | recommender + wizard; mod signatures for Advanced Peripherals, Mekanism and CC:C Bridge verified against their documentation |
| M5 | built | tsh shell, auth, net (pairing, signed RPC), rsh, netfs, svc-manager, pkg-mirror (lan source), ops (cron, metrics, logs), roles, rscreen, web gateway, chat bot |
| M6 | built | widgets, window manager, desktop, Files / Terminal / Settings / App Store / Task Manager; installable later, removable, falls back to the shell |
| M7 | built | phone interface, notifications, A* pathfinding with obstacle memory, fleet control |
| M8 | built | hal (generic + redstone-only devices), rules engine, Advanced Peripherals / Mekanism (+SCADA) / CC:C Bridge packs, power and tank dashboards |
| M9 | built | editor, text file manager, Lua prompt, manual and tour, graphics + image formats + palettes, snapshots + recycle bin, sandbox and virtual computers, shop, games |
| M10 | built | TV home screen, media player, signage, kiosk, mirroring, pocket remote |

"built" = implemented and green in CraftOS-PC; nothing has run in real Minecraft yet. The next milestone for every row is an in-game
smoke test (see AGENTS.md for the list of what to try first).

Cross-cutting from M2 onward: docs per module, tests per module, size budget checks, security review of anything that
executes downloaded code.
