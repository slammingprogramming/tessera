# Tessera

A modern, modular operating system family for [CC: Tweaked](https://modrinth.com/mod/cc-tweaked) computers in Minecraft.
(*A tessera is one tile of a mosaic — small modules that compose the whole.*)

**Status:** planning / design — no code yet. **License:** AGPL-3.0.

Goals
- Guided installer that detects your hardware and recommends modules/drivers — works from the web, from a Pastebin
  backup, from a LAN server, or fully offline by pasting data into the terminal.
- Server, client, turtle, pocket ("mobile") and TV profiles; colour and black-and-white supported.
- Tiny core; apps and drivers fetched on demand by a package manager (default disk is only ~1 MB).
- Optional GUI (built from scratch) you can add later.
- Control modded machines through native CC integrations, with redstone as the fallback.

See [docs/](docs/) for research, architecture, roadmap and decisions.
