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

## Status (2026-09-29)

| M | Status | Notes |
|---|---|---|
| M0 | done | docs |
| M1 | done | headless test runner works via a mounted results directory; in-game paste/file-drop limits **not yet measured** |
| M2 | done | 12 kernel + VFS/config/log tests, boot e2e; crash-loop guard and recovery key exist but have no e2e scenario yet |
| M3 | done | offline paths tested (directory mirror, bundle file, pasted chunks); **HTTP and Pastebin channels are untested against real servers** (no public repo yet); browser bundle-builder page still to do |
| M4 | done | recommender + wizard tested with scripted UI and unattended e2e; mod signatures other than Advanced Peripherals are unverified guesses |
| M9 (partly) | started early | App wave 1: turtle foundation + 12 turtle apps and 12 computer apps (docs/APPS.md); tested with a simulated turtle world and fake peripherals, not yet in real Minecraft |
| M5–M8, M10 | not started | |

Cross-cutting from M2 onward: docs per module, tests per module, size budget checks, security review of anything that
executes downloaded code.
