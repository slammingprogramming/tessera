## What and why

<!-- One logical change. Link the issue if there is one. -->

## How I tested it

<!-- Emulator (CraftOS-PC) and/or a real world. `node tools/ci.mjs` output, new tests, ... -->

## Checklist

- [ ] Commits are signed off (`git commit -s`), see CONTRIBUTING.md
- [ ] Tests added or updated; `node tools/ci.mjs --no-emulator` passes (and the emulator tests if I could run them)
- [ ] `node tools/docs/apidoc.mjs` run if a public function changed
- [ ] Nothing leaves the Minecraft world, no telemetry, no secrets or personal data in the change
- [ ] This is not a security fix (those go to the private channel, see SECURITY.md)
