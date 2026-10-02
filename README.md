# Tessera

A modern, modular operating system family for [CC: Tweaked](https://modrinth.com/mod/cc-tweaked) computers in Minecraft.
(*A tessera is one tile of a mosaic — small modules that compose the whole.*)

**Status:** early development, **not released yet — the source code is not public**. This repository currently holds the
project's documentation and license. The core (boot, kernel, filesystem layer), package manager, offline bundles,
installer, hardware detection, setup wizard and a first set of optional apps work in the CraftOS-PC emulator; nothing has
been smoke-tested in real Minecraft yet.

**License:** [AGPL-3.0-or-later](LICENSE).

## Goals

- A guided installer that detects your hardware and recommends modules and drivers — works from the web, from a Pastebin
  backup, from a LAN server, or fully offline by pasting data into the terminal.
- Server, client, turtle, pocket ("mobile") and TV profiles; colour and black-and-white computers both supported.
- A tiny core; apps and drivers fetched on demand by a package manager (a stock computer has only about 1 MB of disk).
- An optional GUI (built from scratch) that you can add later.
- Control of modded machines through native CC integrations, with redstone as the fallback.

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — boot flow, kernel, profiles, hardware model, networking, package manager
- [Apps](docs/APPS.md) — the optional apps: turtle mining/farming/building jobs, redstone tools, door security,
  jukebox, storage sorting, file sync, a text adventure and more
- [Package format](docs/PACKAGE-FORMAT.md) · [Integrations](docs/INTEGRATIONS.md) · [Feature parity matrix](docs/PARITY-MATRIX.md)
- [Real-world tools in the game](docs/REALWORLD.md) (time sync, ssh, pgp, torrent, firewall, DNS, encrypted folders, tar/diff) · [Security model](docs/SECURITY.md)
- [Roadmap](docs/ROADMAP.md) · [Decisions](docs/DECISIONS.md) · [Research notes](docs/RESEARCH.md)

Not affiliated with CC: Tweaked, Mojang or Microsoft.
