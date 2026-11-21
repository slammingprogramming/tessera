# Contributing to Tessera

Thank you for wanting to help. Tessera is an operating system family for [CC: Tweaked](https://modrinth.com/mod/cc-tweaked) computers.
It is licensed [AGPL-3.0-or-later](LICENSE); by contributing you agree that your work is released under that license.

## Before you start

- **Security problems go to the private channel, not to an issue or a pull request:** see [SECURITY.md](SECURITY.md).
- For anything bigger than a small fix, open an issue first so we can agree on the approach. The design decisions that are
  already made are in [docs/DECISIONS.md](docs/DECISIONS.md); the architecture is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- Questions, ideas and bug reports are all welcome as issues. Please say which CC: Tweaked / Minecraft version you use, and
  whether you tested in the game or only in the CraftOS-PC emulator.

## What fits the project

- **A small core, everything else a package.** New features are usually a new package in `src/<name>/` (metadata in
  `package.json`, files under `root/`), not an addition to `core`. See [docs/PACKAGE-FORMAT.md](docs/PACKAGE-FORMAT.md).
- **Nothing leaves the Minecraft world** (D-18). Networking, mail, ssh, torrents and the like are in-game equivalents: no bridge to
  the real internet, and no feature that lets a player reach real-world servers.
- **No telemetry**, no uninvited installs, nothing that copies itself. Honest security claims: say what a feature does *not* protect against.
- **Keep it modest.** Computers are slow Lua machines with about 1 MB of disk and cooperative multitasking: respect the package size budgets,
  yield in long loops, and keep messages small.

## Building and testing

You need [Node.js](https://nodejs.org) 22 or newer and, for the Lua tests, [CraftOS-PC](https://www.craftos-pc.cc) 2.8 (set `TSR_CRAFTOS` if it is not
in the default location).

```bash
node tools/ci.mjs                  # everything, including the emulator tests (several minutes)
node tools/ci.mjs --no-emulator    # build, size budgets, docs and the Node-only tests
node tools/test/run.mjs --filter inet/mail   # one group of Lua tests
node tools/dev/new-app.mjs ...     # scaffold a new app package
```

- Add or update tests for what you change (`tests/**/*_test.lua`). A bug fix should come with a test that fails without it.
- The unit-test run can report "Too long without yielding" on a slow or busy computer. If a test fails like that, run the file alone before concluding anything.
- Everything is verified in the emulator only. If you can test in a real world, say so in the pull request: that is valuable.
- Regenerate the API reference with `node tools/docs/apidoc.mjs` when you change a module's public functions.

## Code style

Write code that reads like the code around it: the same naming, the same comment density, the same idiom. Files start with the
`-- SPDX-License-Identifier: AGPL-3.0-or-later` line. Lua runs on Cobalt (CC: Tweaked) as well as the emulator's Lua 5.2: avoid `//`,
`%z`, and `%d` formats for numbers above 2^31 (use `%.0f`).

## Commits and pull requests

- **Sign off every commit** (`git commit -s`): this is the [Developer Certificate of Origin](https://developercertificate.org); there is no CLA.
- Use your GitHub **no-reply** address if you do not want your real email in the history.
- Signed commits (SSH or GPG) are appreciated and may be required on the main branch.
- One logical change per pull request, with a clear description of what and why. Describe how you tested it.
- AI-assisted contributions are fine if you have read, understood and tested every line, and you say so in the description.
- Please do not include secrets, tokens, personal data or other people's code under an incompatible license.

## Supporting the project

Donations are optional; see [docs/SUPPORT.md](docs/SUPPORT.md).
