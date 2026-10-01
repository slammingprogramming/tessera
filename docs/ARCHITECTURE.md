# Architecture (draft v0.1)

Name: **Tessera** (prefix `tsr`; DECISIONS D-01). License: AGPL-3.0 (D-08). Status: design only, no code yet.

> **Implementation status:** see docs/ROADMAP.md ("Status"). Sections 2-4, 8, 9 and the TUI part of 10 are implemented (M1-M4);
> the rest is design. Where this document and the code differ, the code wins and this file should be fixed.

## 1. Principles

1. **Small core, everything else a package.** The core must fit comfortably in well under 1 MB (stock disk limit) and
   ideally ≤ 150 KB on disk, minified. No bloat: nothing ships unless a detected need or explicit choice pulls it in.
2. **Web-first, storage-frugal.** Apps/drivers/themes are fetched on demand and cached with eviction; lazy-install stubs;
   optional mounts (disk drive, remote FS from a server).
3. **Detect, recommend, let the user override.** Hardware auto-detection drives recommendations; the user always has the
   final say. GUI is optional and installable later.
4. **One OS family, many profiles.** Shared kernel/HAL/pkg; profiles differ by package set and UI.
5. **Compatible by default.** CraftOS programs keep working (compat layer for `shell`, `os.pullEvent`, `multishell`,
   `rednet`, `term`...). We layer on CraftOS first; deeper takeover is opt-in (UnBIOS-style).
6. **Good citizen on servers.** Never self-replicate, never install on computers the user didn't pick, no default
   telemetry, respects HTTP rules/config, always has a recovery path back to plain CraftOS. (PotatOS lesson.)
7. **Capability-based hardware model.** Apps ask for "an inventory / an energy store / a display", not for a specific
   mod's peripheral. Integration packs map mods → capabilities; redstone drivers are the universal fallback.
8. **Honest security.** CC has no real privilege boundary vs. someone with physical access; permissions are best-effort
   and documented as such.

## 2. On-device filesystem layout

```
/startup.lua          stage-0 stub (≤1 KB): recovery-key check, then hands off to /sys/boot.lua
/sys/                 kernel + core modules (managed by pkg; treat read-only)
/etc/                 config: system.cfg, profile.cfg, pkg/sources.d/, services.d/, hw.cfg (detected hardware)
/usr/{bin,lib,share}  installed packages (bin may hold lazy stubs)
/var/{cache/pkg,log,lib,run}  package cache (evictable), logs, state, runtime
/home/<user>          user data
/mnt/<name>           mounts: disk drives, remote FS (server), netmount
/rom                  untouched CraftOS ROM
```

## 3. Boot flow

1. CC BIOS → CraftOS shell startup runs `/startup.lua` (stage 0).
2. Stage 0: hold-key window for **recovery** (drop to plain CraftOS, or run installer/repair). Otherwise `dofile
   /sys/boot.lua`.
3. `boot.lua`: load `/etc/hw.cfg`; re-probe hardware cheaply; select profile; load kernel; start init.
4. **init** starts services (server/turtle/tv) or a session (login → shell/TUI/GUI) per profile.
5. Level 2 (optional, later): UnBIOS-style full takeover for custom kernel semantics. Not needed for v1.

## 4. Kernel (`src/core`)

- **Cooperative scheduler** on coroutines; event router with per-process filters; process table; signals
  (`terminate`); per-process environment; `window`-based terminal per process (multishell replacement); watchdog to
  catch non-yielding processes (CC kills them otherwise).
- **Syscall layer** (`sys.*`) — the only API apps should depend on; CraftOS APIs proxied via compat.
- **VFS**: mount table over `fs` (local, disk, remote, virtual/`/dev`, `/proc`), path permissions (soft), quotas,
  atomic write helper (write-temp-then-move) — vital because turtles/computers get chunk-unloaded mid-write.
- **IPC**: named channels/queues; RPC over them; same wire format as network RPC (local = remote).
- **Config/registry**: layered (defaults → profile → system → user), change events (`setting_changed`).
- **Logging**: ring buffer + rotated files under `/var/log`, level-filtered; optional remote sink.
- **Users/auth**: optional; local accounts (salted+iterated hash), groups, session locking; server profile can host an
  auth service for LAN login.
- **Drivers/HAL** (`src/hal`): see §6.

## 5. Profiles (`src/profiles`)

A profile = a named set of packages + defaults + boot behaviour.

| Profile | Target | UI | Notes |
|---|---|---|---|
| `client-lite` | Basic (non-advanced) computer | TUI, grayscale, keyboard only | Tiny footprint; no mouse/colour assumptions |
| `client` | Advanced computer | TUI (default) or GUI (optional) | Mouse + colour |
| `server` | Any computer acting as host | Headless + admin TUI/remote | Service manager, package mirror, auth, file/db, gateways, dashboards |
| `turtle` | Turtle / advanced turtle | Minimal TUI (39×13) | Fuel, position, jobs, pathfinding, remote control |
| `pocket` | Pocket / advanced pocket | Launcher-style "mobile" UI (26×20) | Low-power, notifications, wireless remote, GPS |
| `tv` | Computer driving monitor(s) (+speakers) | 10-foot UI, touch or pocket-remote | Media, channels, screen mirroring, apps |
| `node` | Redstone/sensor controller | Headless | Minimum footprint; reports to a server |
| `command` | Command computer | TUI | Admin tools; creative/ops only |

Colour/mono variants are **capability flags** (`display.color`, `input.mouse`, `display.size`) evaluated at runtime, not
separate codebases; the profile picks the appropriate UI/theme package.

## 6. Hardware abstraction & capability model (`src/hal`, `src/integrations`)

- Probe: `peripheral.getNames()` + `getType()` (multi-type aware) + method-set fingerprint, plus environment checks
  (see §9).
- Drivers register `{match, provides = {capability...}, factory}`. Capability classes (initial):
  `display`, `input`, `inventory`, `energy`, `fluid`, `chemical`(Mekanism), `redstone`, `sensor.player`, `sensor.env`,
  `sensor.block`, `audio`, `printer`, `storage.disk`, `net.modem`, `net.http`, `net.ws`, `machine.<type>`.
- Generic peripherals (`inventory`, `energy_storage`, `fluid_storage`) are first-class drivers → wide mod coverage for free.
- **Integration packs** (`integration-<mod>`): add drivers + high-level helpers + example apps for a mod. Installed
  only when the mod's peripherals are detected (or user opts in). See INTEGRATIONS.md.
- **Redstone fallback drivers**: model a machine as `{inputs: redstone outputs, outputs: redstone/comparator inputs}` so
  automations run even with no mod integration. Support bundled cables (`colors`) where available.

## 7. Networking (`src/net`)

- Transport: modem (wired/wireless/ender), wired-modem *remote peripherals*, WebSocket/HTTP to external gateways.
- Layered protocols over rednet channels: **discovery** (services announce; DNS-like names `host.svc`), **RPC**,
  **remote FS mount**, **remote shell** (ssh-like, encrypted), **file sync**, **package mirror**, **time sync**.
- Security: pairing + keys (ecc/ecnet-style), HMAC on messages, replay protection; unauthenticated traffic is allowed
  only for discovery.
- **Server as package mirror/cache**: one HTTP-enabled server fetches from the web and serves clients over rednet, so
  clients on HTTP-restricted servers still get web-installed packages.
- External gateway (optional, self-hosted): WebSocket bridge for browser terminal (Cloud Catcher-style), heavy
  conversion (sanjuuni video), external DB/webhooks.

## 8. Package manager (`src/pkg`) — see PACKAGE-FORMAT.md

`pkg install|remove|update|upgrade|search|info|list|verify|clean|source ...`
- Registry = static JSON (GitHub Pages / raw / jsDelivr mirrors), metadata-only like CCPM: files stay wherever authors
  host them; every file pinned by SHA-256. Optional signatures for the official registry.
- Dependency resolution with semver ranges; `provides`/`requires` capability names; profiles are meta-packages.
- Transactional installs (stage → verify → swap), rollback, size accounting vs. free space, cache eviction (LRU),
  **lazy stubs** (`/usr/bin/foo` fetches on first run), minified/compressed payloads.
- Source adapters: official registry (GitHub Pages, with raw/jsDelivr mirrors), Pastebin mirror, LAN mirror (server),
  **offline import** (`pkg import`: file drag-and-drop or chunked paste, checksummed and resumable), third-party
  registries, unicornpkg/CCPM/Pinestore compat, raw URL, gist. Tier order and offline-paste spec: DECISIONS "Distribution
  tiers". Each package records `license` and `source` (AGPL source-availability).

## 9. Installer & hardware detection (`src/installer`)

Bootstrap: `wget run https://<pages-host>/install.lua` (tiny stage-0; fetches the wizard); backup: `pastebin run <id>`;
then LAN server; worst case fully offline — the stage-0 prompts the player to paste or drag-drop the wizard, then the
registry, then each chosen app payload (chunked + checksummed; a static offline-bundle-builder page generates the
chunks). The installer probes channels in that order and reports which it will use and why. Resumable, logs to
`/var/log/install.log`, never destructive without a confirm + backup offer.

Detection (all via public API): computer kind (`turtle`, `pocket`, `commands` globals; `term.isColor()`), free/total
space (`fs.getFreeSpace/getCapacity`), HTTP enabled + per-mirror reachability (`http.checkURL`), attached peripherals and
their types/methods, modems (wireless/ender/wired), monitors + sizes, speakers, drives/disks, printers, redstone relays,
generic inventories/energy/fluid, known modded peripherals (Advanced Peripherals, Mekanism, Create bridge, Tom's GPU…),
label/ID, `_HOST` / `os.version()`.

Recommendation engine: rules file (`profiles/recommend.lua`) maps detections → profile, modules, drivers, integration
packs, UI choice, with a human-readable *reason* per pick. Wizard steps: welcome → detect → profile → storage plan →
network/server role → modules (recommended pre-ticked, optional shown) → UI choice (TUI / GUI / decide later) → review
(size needed vs free) → install → first-boot setup (name, user, network).

## 10. UI stack (`src/ui`)

- **Text shell (always present):** history, completion, pipes/redirection (shell-compat), job control, aliases; **TUI
  toolkit** (menus, forms, lists) that degrades on grayscale/small screens.
- **GUI (optional package set):** compositor/window manager, widget toolkit, theme engine, launcher/desktop, file
  manager, settings. Installable later; removable. Runs on advanced computers and monitors (touch). The toolkit is
  **built from scratch** (D-06) for tight optimisation (dirty-rect rendering, minimal redraw, small footprint) and
  Tessera-specific features (theming, capability-aware widgets, monitor/touch/pocket-remote input, HAL-bound widgets such
  as gauges for inventory/energy/fluid). Design it as its own package with a stable API so other apps can use it.
- **Mobile shell (pocket profile):** app grid, notification shade, quick settings, gestures mapped to mouse.
- **TV shell (tv profile):** large-type UI, channel/app rows, remote-control over wireless from a pocket computer, screen
  mirroring from other computers, audio via speakers (DFPWM).

## 11. Server OS services (`src/services`)

Service manager (systemd-lite: deps, restart policy, logs). Candidate services: package mirror/cache; auth/directory;
file/db/kv; time; logging/metrics dashboard; GPS host; storage-system manager (Artist/Milo/MISC-class: inventory
indexing, auto-sort, crafting); scheduler/cron; redstone/automation rules engine; energy/SCADA dashboards; chat bot
(Chat Box); Krist/economy hooks; backup; web gateway; Discord/webhook bridge (via gateway).

## 12. Turtle OS (`src/profiles/turtle` + packages)

Write-ahead position/heading persistence (survives unload), GPS calibration, fuel manager, A*/pathfinding with obstacle
memory, job queue with resume, inventory protocol (auto-dump/refill), remote control + swarm coordination over modems,
stock jobs (mine/quarry/tree/farm/build-from-blueprint/sort), safety (return-home on low fuel, protect against
stuck loops).

## 13. Security model (best effort)

Signed/hashed packages; sandboxed process environments with capability tokens for syscalls; soft file permissions;
encrypted network channels; admin-approved remote installs only; audit log. Out of scope: defending against a player who
can break the computer/steal the disk.

## 14. Dev & test

- Emulator-first: **CraftOS-PC** headless for unit/integration tests (with `periphemu` fake peripherals), CCEmuX/Copy Cat
  as secondary, in-game smoke tests on 1.20.1/1.21.1/latest 26.x.
- Build tool (`tools/`): minify, hash, generate registry manifests, size report (fail CI if core > budget).
- Language: Lua (5.1-compatible subset for CC:T's VM); TypeScript→Lua is possible but not default (DECISIONS D-05).
- Style: small modules, `require` via `cc.require`-compatible paths, no globals leaked, every public API documented in
  `docs/api/`.
