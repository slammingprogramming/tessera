# Tessera

A modern, modular operating system family for [CC: Tweaked](https://modrinth.com/mod/cc-tweaked) computers in Minecraft.
(*A tessera is one tile of a mosaic — small modules that compose the whole.*)

**Status:** early development. The core (boot, kernel, filesystem layer), package manager, offline bundles, bootstrap
installer, hardware detection and setup wizard work and are tested in the CraftOS-PC emulator; nothing has been
smoke-tested in real Minecraft yet. **License:** AGPL-3.0-or-later.

Goals
- Guided installer that detects your hardware and recommends modules/drivers — works from the web, from a Pastebin
  backup, from a LAN server, or fully offline by pasting data into the terminal.
- Server, client, turtle, pocket ("mobile") and TV profiles; colour and black-and-white supported.
- Tiny core; apps and drivers fetched on demand by a package manager (default disk is only ~1 MB).
- Optional GUI (built from scratch) you can add later.
- Control modded machines through native CC integrations, with redstone as the fallback.

See [docs/](docs/) for research, architecture, roadmap and decisions, and [docs/APPS.md](docs/APPS.md) for the optional apps
(turtle mining/farming/building jobs, redstone tools, door security, jukebox, storage sorting, file sync, a text adventure and more).

## Try it (development)

Requires Node 18+ and [CraftOS-PC](https://www.craftos-pc.cc/).

```
node tools/ci.mjs            # build + all tests
node tools/dev/try.mjs       # open an emulator window, then run: /site/install.lua /site
```
