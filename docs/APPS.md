# Apps

Optional programs you install with the package manager (`pkg install <name>`, or tick them in the setup wizard; the wizard
recommends the ones that match your hardware). Every app is its own small package, downloaded only if you want it. They are
all built on shared libraries (`app-kit`, `turtle-core`, `excavate`) that are pulled in automatically.

Status: all apps below are implemented and covered by automated tests (turtle apps run against a simulated turtle world,
peripheral apps against fake peripherals) and by an install-everything check on the built registry. **None has been tried
in real Minecraft yet** — please report anything that behaves differently in the game.

## Turtles

| Package | Command(s) | What it does |
|---|---|---|
| `turtle-core` | `tstatus`, `tresume` | Library: journaled position tracking that survives chunk unloads, fuel handling, safe dig-and-move, `goto`, GPS calibration, job save/resume. A boot daemon resumes an interrupted job after a restart. |
| `bore` | `bore`, `maketunnel` | Dig a tunnel of any length/width/height; torches in wall alcoves; chest dumping; resumes after a reboot. |
| `carve` | `carve`, `makeroom` | Dig out a room from the corner or the centre, with an offset. |
| `stripmine` | `stripmine` | Main shaft with regular side branches (1×2 tunnels). |
| `quarry` | `quarry` | Dig a rectangular pit layer by layer. |
| `build` | `build` | Floors, walls, hollow boxes and layered blueprint files; checks materials, waits for more. |
| `treefarm` | `treefarm` | Waits for the tree, fells it, replants, refuels from the logs, empties into a chest. |
| `cropfarm` | `cropfarm` | Harvest only ripe wheat/carrots/potatoes/beetroot/nether wart in a rectangle and replant. |
| `cobblegen` | `cobblegen` | Mine a cobblestone generator, emptying into a chest. |
| `guard` | `guard` | Attack anything near (front/up/down), optionally turning; collect drops. |
| `turtle-remote` | `tlisten`, `tcontrol` | Wireless remote control of a turtle from a computer or pocket computer (HMAC-authenticated, replay-protected, fixed command set). |
| `turtle-jobs` | — | Meta package: installs all of the above turtle apps. |

Common options: `--dump back|down|up` (empty into a chest), `--junk` (throw rubbish away), `--stay` (do not return),
`--yes`. Put torches/fuel/saplings/seeds in the turtle's inventory; they are found by item name, not by slot.

## Computers

| Package | Command(s) | What it does |
|---|---|---|
| `print` | `tprint` | Word-wrapped multi-page printing from a file or typed text; titles, page numbers, copies, paper/ink checks. |
| `redstone` | `rs`, `redseq` | Read/set/pulse/toggle/watch redstone on any side, bundled colour or relay; timed sequence scripts with fail-safe shutdown. |
| `cannon` | `cannon` | Arming-code protected controller for a redstone TNT cannon (charge pulses, fire, cooldown, dry run). |
| `chunkctl` | `chunkctl` | Switch a chunk loader always / on a schedule / only while players are near (Advanced Peripherals player detector). |
| `access-control` | `access`, `keypad` | Keycard doors (signed floppy cards, levels, revocation, log) and keypad doors (salted code, lockouts); piston doors supported. |
| `disk-tools` | `disks` | List drives, show contents, label, copy, wipe, make a disk auto-run a program. |
| `display` | `monclock`, `monstat`, `monwrite` | Big clock, status board and message board for monitors. |
| `audio` | `jukebox` | DFPWM music player with playlist, shuffle, loop, volume, pause; files, folders or URLs. |
| `gps` | `gpshost`, `where` | Host a GPS beacon (also at boot); position, waypoints, distance and bearing. |
| `svc-storage` | `storage` | Chest-network manager: scan, find, auto-sort an input chest by rules, fetch items; works with any inventory peripheral. |
| `filesync` | `filesync` | Sync a folder between computers over rednet (HMAC-signed, path-confined, hash-compared). |
| `game-mork` | `mork` | A small text adventure. |

## Where the old scripts went

The old `computercraft-scripts` repository (GPLv3, same author) had four working scripts and a folder tree of plans. All
of it is covered; the code that existed was rewritten on the shared foundations rather than copied line by line.

| Old file / plan | Now |
|---|---|
| `Computers/Peripherals/Printer/printer.lua` | `print` → `tprint` |
| `Turtles/mining/makeroom.lua` (earlier `carveroom`) | `carve` (`makeroom` still works) |
| `Turtles/mining/maketunnel.lua` | `bore` (`maketunnel` still works) |
| `Turtles/felling/treefarm.txt` | `treefarm` |
| `mining/cobblegen.lua`, `mining/dig.lua`, `mining/makestripmine.lua` (empty plans) | `cobblegen`, `quarry`, `stripmine` |
| `universal/direction.lua`, `locate.lua`, `move.lua` (empty plans) | `turtle-core` (`tsr.turtle`: facing, position, movement, GPS) |
| `universal/makefloor.lua` (empty plan) | `build floor` |
| `Universal/bootstrapper.lua`, `updater/install|uninstall|update.lua` (empty plans) | the Tessera installer and `pkg` (install / remove / upgrade) |
| `Games/mork` (folder only) | `game-mork` |
| `Music/Jukebox Script` (folder only) | `audio` → `jukebox` |
| `Offensive/TNT Cannon Controller` (folder only) | `cannon` (on top of `redstone`) |
| `Security/DoorAccessControl`, `Security/Piston Door` (folders only) | `access-control` → `access`, `keypad` |
| `Peripherals/Disk Drive`, `Peripherals/Monitor` (folders only) | `disk-tools`, `display` |
| `Turtles/farming`, `melee`, `wireless` (folders only) | `cropfarm`, `guard`, `turtle-remote` |
| README plans: building assistant, networking tools, inventory manager, chunk-loader logic, keycard terminals, wireless file sync | `build`, `filesync` + `turtle-remote`, `svc-storage`, `chunkctl`, `access`, `filesync` |
| `Turtles/crafting` (folder only) | not built yet (a crafting turtle is on the wish list) |

## Writing your own app

```
node tools/dev/new-app.mjs mytool --desc "What it does" --cmds mytool --module mytool --requires app-kit
```

creates `src/mytool/` with a `package.json` and a launcher. Put the logic in `root/usr/lib/tsrapps/mytool.lua` as
`M.main(args, io)` (take an `io` table so it can be tested without a keyboard — see `tsrapps.cli`), add tests under
`tests/apps/`, and the build, registry, `pkg` and the wizard pick it up.

## System, server, interface and tools (added 2026-10-01)

Same status as above: built and tested in CraftOS-PC, not yet run in real Minecraft. Details for each are in the in-game manual (`thelp`).

| Package | Command(s) | What it does |
|---|---|---|
| `shell` | `tsh` | The default shell: pipes, redirects, variables, globs, `$(...)`, scripts (`if`/`for`/`while`), history, completion; runs stock CraftOS programs unchanged. |
| `svc-manager` | `svc` | Supervised background services with dependencies, restart policies and back-off. |
| `auth` | `useradd`, `passwd`, `su`, `sudo`, `lock`, `users`, ... | Accounts, login and lock screen, roles, soft file permissions (honest limits: see docs/SECURITY.md). |
| `net` | `net` | Discovery, ping, time, one-time-code pairing, signed (optionally encrypted) remote calls. |
| `rsh` | `rsh`, `rexec` | Remote shell on paired computers that you allowed. |
| `netfs` | `netfs` | Share folders and mount other computers' shares. |
| `rscreen` | `rview`, `rscreen` | Watch and control another computer's screen. |
| `pkg-mirror` | `pkgmirror` | Package mirror for networks without internet access (`lan` package source). |
| `ops` | `crontab`, `metrics`, `logship` | Cron, metrics (local and remote), central log collection. |
| `roles` | `role` | One-command server roles (mirror, file server, shell host, monitor, log collector, ...). |
| `webgw` | `webgw` | Outbound connection to `tools/gateway/gateway.mjs` so web pages and scripts can call exposed services. |
| `chatbot` | `chatbot` | In-game `!commands` through an Advanced Peripherals chat box. |
| `hal` | `hal` | One set of readings and actions for every machine and mod device, including redstone-only machines. |
| `rules` | `rules` | Automation rules with hold times and hysteresis. |
| `int-ap` | `me` | Advanced Peripherals: ME and RS bridges, detectors. |
| `int-mekanism` | `scada` | Mekanism energy, reactors, turbines, miners; reactor safety supervision. |
| `int-create` | `cdisplay` | Create display links through CC:C Bridge. |
| `power-monitor` | `power`, `tanks` | Live power and fluid dashboards on terminal or monitor. |
| `ui-gui` | `gui` | The desktop: windows, taskbar, Files, Terminal, Settings, App Store, Task Manager. |
| `mobile` | — | Phone-style interface for pocket computers. |
| `tv` | `tv`, `tvremote`, `signage`, `kiosk`, `mirror` | TV home screen, remote, signage slideshows, kiosk mode, screen mirroring. |
| `media` | `play` | BIMG/NFP/DFPWM playback. |
| `gfx` | `banner`, `imgview`, `palette` | Sub-pixel canvas, big fonts, image formats, colour palettes. |
| `editor` | `ted` | Text editor. |
| `utils` | `fm`, `repl` | Text-mode file manager and Lua prompt. |
| `help` | `thelp`, `tsr-tour` | Manual and first-run tour. |
| `safety` | `snap`, `trash` | Snapshots and a recycle bin. |
| `sandbox` | `sandbox`, `vm` | Restricted program runner and virtual computers. |
| `shop` | `shop` | Chest-based vending shop. |
| `games` | `snake`, `2048`, `mines` | Small games with high scores. |
| `fleet` | `fleet` | Turtle fleet control over the network. |
| `calibrate` | `tsr-calibrate` | Measures this setup's real limits (paste length, file drops, yield timeout, Lua features). |

## Real-world tools (added 2026-10-02)

See [REALWORLD.md](REALWORLD.md) for how they work and what is the same as the real thing.

| Package | Command(s) | What it does |
|---|---|---|
| `crypto` | (library) | SHA-512, Ed25519, X25519, ChaCha20-Poly1305, HKDF, PBKDF2 in pure Lua. |
| `ntp` | `ntp`, `ntpdate`, `timedatectl`, `date` | Clock sync from in-game time servers, an optional HTTPS source or by hand; time zones; can serve time. |
| `ssh` | `ssh`, `scp`, `ssh-keygen`, `ssh-copy-id`, `sshd` | Secure shell and file copy between computers (own protocol). |
| `pgp`, `pgp-keyserver` | `pgp`, `gpg` | Signatures, encryption, web of trust and a key server (own format). |
| `p2p` | `torrent` | Torrent-style sharing between computers, magnet links, tracker, package sharing. |
| `firewall` | `fw` | Rules by sender, message type and rate. |
| `dns` | `dns`, `host`, `dig` | Names for computers, zones, resolver and server. |
| `vault` | `vault` | Encrypted folders with a recovery key. |
| `archive` | `tar`, `gzip`, `gunzip`, `zcat` | Standard tar and gzip. |
| `diff` | `diff`, `patch` | Unified diffs and patches (git-compatible). |
| `netmon` | `netmon` | Network monitor with a promiscuous mode. |
| `doctor` | `doctor` | Self-check and speed measurement; writes a report for bug reports. |
| `craft` | `autocraft` | Crafting turtle: make items and what they are made of. |
| `hal-toms` | (drivers) | Tom's Peripherals through `hal`. |

## The in-game internet, mail and devices (added 2026-10-03)

See [NETWORKING.md](NETWORKING.md), [MAIL.md](MAIL.md) and [IOT.md](IOT.md).

| Package | Command(s) | What it does |
|---|---|---|
| `inet` | `ip`, `ifconfig`, `ping`, `traceroute`, `netstat`, `tcpdump`, `nc`, `arp` | Ethernet, ARP, IPv4, ICMP, UDP, TCP and the tools to look at them. |
| `dhcp` | `dhcp` | DHCP client, server and relay. |
| `inet-dns` | `nslookup`, `dnsctl` | Name server (zones, recursion, secondaries) and lookup tool. |
| `inet-switch` | `swctl` | Managed switch: VLANs, Spanning Tree, port security, mirroring. |
| `wifi` | `wifi` | Access point and station with a WPA2-style handshake. |
| `inet-fw` | `iptables`, `iptables-save`, `iptables-restore`, `conntrack` | Packet filter, NAT, port forwards, connection tracking. |
| `inet-route`, `bgp` | `routectl` | RIPv2 and BGP-4 with peering policy. |
| `web` | `fetch`, `www` | HTTP server, client and text browser; `www --board` information display. |
| `tls` | `tlsctl` | Certificate authority, certificates and trust for HTTPS, SMTPS and more. |
| `mail` | `mail`, `mailctl` | SMTP/POP3 server, queue, mailboxes, mail program, administration. |
| `mail-spam` | (via `mailctl spam`, `mailctl dkim`) | SPF, DKIM, DMARC, greylisting, DNSBL, scoring, learning filter. |
| `av` | `av` | Anti-virus: scan, quarantine, signed definition updates, floppy scanning. |
| `mqtt` | `mqtt`, `mqttctl` | MQTT broker and client. |
| `modbus` | `modbus`, `modbusctl` | Modbus/TCP slave and client. |
| `smarthome` | `home` | Smart-home hub with scenes, schedule and MQTT bridge. |
