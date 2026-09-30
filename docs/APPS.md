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
