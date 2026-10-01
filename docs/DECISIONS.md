# Decisions & Open Questions

Format: ID — decision — status (**decided** = user; **delegated** = user handed it to the agent, agent decided; **default** = agent's provisional choice, revisit; **open**).

| ID | Topic | Decision / question | Status |
|---|---|---|---|
| D-00 | Target platform | CC: Tweaked is the only supported platform (confirmed dominant; RESEARCH §1). Original ComputerCraft / legacy MC not supported. | decided |
| D-01 | Product name | **Tessera** (short prefix `tsr`). A *tessera* is one tile of a mosaic — small modules that compose the whole OS; fits the "core + packages" model and Minecraft's blocky look. A quick web search found no existing CC OS/project with this name, but this is **not** a trademark/GitHub-name clearance: check the name on GitHub/Modrinth/forums before the first public release. Repo folder stays `computercraft-os` until the public repo is created. | delegated (2026-09-29) |
| D-02 | Layering strategy | Layer on CraftOS via `/startup.lua` (v1) with an always-available recovery path; UnBIOS-style takeover only later/optionally. | default |
| D-03 | Multitasking | Cooperative kernel; investigate preemption later. | default |
| D-04 | Distribution & install channels | See "Distribution tiers" below. GitHub Pages primary → mirrors → Pastebin → LAN server mirror → fully offline paste/file-drop. | decided (2026-09-29); exact URLs pending public repo |
| D-05 | Language | Lua (CC:T-compatible). TypeScript→Lua not default. | default |
| D-06 | GUI toolkit | **Build our own from scratch** (no Basalt dependency): better optimisation and features tailored to Tessera. Basalt/GuiH-made apps may still be installable as optional third-party packages. | decided (2026-09-29) |
| D-07 | Package registry | Own JSON registry (CCPM-like) + adapters for unicornpkg/CCPM/Pinestore. | default |
| D-08 | License | **AGPL-3.0-or-later** for Tessera's own code (user confirmed the SPDX form). SPDX headers on every source file. See "Licensing consequences" below. | decided (2026-09-29) |
| D-09 | Publication | Staged: documentation first, source code at the first release. See "Publication" below. | decided (2026-09-29) |
| D-10 | Version targets | Test on 1.20.1, 1.21.1, latest 26.x. | default |
| D-11 | Telemetry | None by default; opt-in only. | default |
| D-12 | Security | Best-effort model (ARCHITECTURE §13); package hashes mandatory, signatures for official registry. | default |
| D-13 | Registry hosting cost/ownership | GitHub Pages is free; pastebin mirrors free. A self-hosted gateway/VPS is optional and undecided. | default |
| D-14 | Offline install | Must be possible with zero in-game internet by pasting/dropping data into the terminal on prompt (registry → then app payloads as needed). See below. | decided (2026-09-29) |
| D-15 | Test environment | The maintainer has **both CraftOS-PC and a Minecraft test world**. CraftOS-PC 2.8 is at `C:\Program Files\CraftOS-PC` (user data `%APPDATA%\CraftOS-PC`). Node 24, Python 3.13, Git available; no standalone Lua. Headless works when results are written to a mounted directory (see docs/RESEARCH.md §2.6); CraftOS-PC 2.8.3 emulates ComputerCraft 1.112.0 on Lua 5.2. | decided / verified 2026-09-29 |
| D-16 | Contribution terms | DCO sign-off (default) rather than a CLA, so AGPL stays simple. | default |

## Distribution tiers (D-04, D-14)

Installer/registry client tries, in order (each probed with `http.checkURL`/a real fetch, results cached in `/etc/hw.cfg`):

1. **GitHub Pages** (primary): `installer`, `registry`, package payloads. Same content also reachable through
   raw.githubusercontent.com / jsDelivr as automatic mirrors of the same repo (only if servers allow those hosts).
2. **Pastebin backup** (if pastebin.com is unblocked): a tiny bootstrap paste, a registry snapshot paste, and per-package
   pastes; paste IDs published in a `mirrors.json` (itself inside the registry and inside the bootstrap paste). Use the
   built-in `pastebin get/run` for the bootstrap. Free-paste size/rate limits **[unverified]** — check before relying.
3. **LAN mirror**: another Tessera server (with HTTP) serves registry + packages over rednet.
4. **Offline paste / file-drop** (zero connectivity): the wizard prompts for data. Inputs accepted:
   - **File drag-and-drop** onto the terminal (`file_transfer` event) — preferred when the player can obtain files.
   - **Chunked paste**: a numbered, checksummed text stream (compressed + base64). The wizard says "paste chunk 3 of 41",
     verifies each chunk's CRC/SHA, allows resume and re-paste of a bad chunk. Clipboard paste size per event is limited
     **[unverified: reportedly a first-line/short cap]** so chunk size must be measured in-game.
   - **Floppy/disk relay** from another computer that has the data.
   - A **static "offline bundle builder" page on GitHub Pages** lets players pick a profile/packages and get the exact
     chunks to copy from their browser into the game (client-side JS; no server needed). Registry first, then only the
     app payloads they choose.
   The same import path (`pkg import`) is reused later for adding single packages offline.

## Licensing consequences of AGPL-3.0 (D-08)

- We may bundle/port code under compatible licenses: MIT, BSD, Apache-2.0, LGPL, GPL-3.0 (GPLv3 §13 allows combining
  with AGPLv3), public domain/CC0. **Not** GPL-2.0-only, and nothing proprietary/with unclear terms.
- **Do not copy CC:T ROM/Lua** (CCPL — verify terms) into our tree; interoperate via the public API and write our own.
- AGPL §13 (network use): if users interact remotely with a modified Tessera service (e.g. server OS services over
  rednet/websocket gateways), they must be offered the corresponding source. Implementation: every installed package
  carries a `source` field (repo URL + commit/tag) and the OS provides `about --source` / `pkg source <name>` and a
  network-visible source-offer in server services. Minified payloads are acceptable **only** because the original source
  is published and linked.
- Third-party packages in the registry declare their own `license`; `pkg info` shows it; registry policy: only
  redistribute what the license allows, otherwise link out.
- Sibling repo `computercraft-scripts` is GPLv3 — code from it can be ported into Tessera (GPLv3 → AGPLv3 combination is
  permitted); the reverse is not (don't relicense their work away from them).
- Add SPDX headers (`-- SPDX-License-Identifier: AGPL-3.0-or-later`) and a `LICENSE` file when the repo is initialised.

## Publication (D-09)

The project is published in stages. At the moment only documentation and the license are public; the source code
will be published at the first release. The mechanics of how the stages are produced are an internal matter.

## Still open
- Basic name clearance for "Tessera".
- Which mods/MC versions get first-class priority beyond the defaults.
