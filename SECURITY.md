# Security policy

## Reporting a vulnerability

**Please do not open a public issue or pull request for a security problem.**

Report it privately on [SimpleX Chat](https://smp14.simplex.im/a#3gZ-zeHs4QrFZKLAN0o3SC_XQJXhj1eYBVTO_c0FAtg)
(end-to-end encrypted; no account, email address or phone number needed). It is the only supported channel for vulnerability reports.

Please include:

- what is affected (package and version, or the command) and what an attacker could do with it,
- steps to reproduce, ideally in CraftOS-PC or on a test world,
- whether you have told anyone else, and whether you want to be credited.

Things that could harm other players' servers (remote code execution, bypassing `auth`, forging signed registries, leaking keys, escaping the
sandbox) should be kept private until a fix is available. This is a small volunteer project: expect a first reply within a few days, and
coordinated disclosure once a fix exists.

## Supported versions

Tessera is in early development; only the latest release (and the main branch) receives fixes.

## Scope and honesty

Tessera protects players from each other inside one Minecraft world. It is a game, not a defence of anything real; the model, its limits and
what each security feature does *not* do are written down in [docs/SECURITY.md](docs/SECURITY.md). Its networks, mail, ssh and similar tools never
connect to the real internet, so reports about real-world protocol compliance are out of scope unless they cause a problem inside the game.
