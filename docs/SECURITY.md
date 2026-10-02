# Security model

Tessera tries to be honest about what it protects. A ComputerCraft computer is a single Lua program with a keyboard; nothing
inside it is a hard boundary against someone who can run code on it or who can break the computer and read its disk.

## What is protected, and against whom

| Layer | Protects against | Does not protect against |
|---|---|---|
| Package installs | corrupted or truncated downloads (every file is verified by SHA-256 before it is written), interrupted installs (journal + rollback), losing your edits (replaced files are backed up) | a malicious *registry host*: package descriptions come from the host, so install only from sources you trust (GitHub Pages over HTTPS, or a LAN mirror you paired with yourself). Package signing is future work. |
| Network pairing | other players impersonating a computer, forging or replaying messages (HMAC with a per-peer key, counters, a 2-minute freshness window), reading *encrypted* calls | someone who watches the pairing exchange and can try about 10^15 codes per second (the one-time code has about 50 bits), someone who can read the key file on a computer, radio-level denial of service, traffic analysis. Discovery, ping and time replies are public by design. |
| Remote shell, screen, files, fleet | strangers: every one of them refuses computers that are not paired *and* explicitly allowed (`rsh allow`, `rscreen allow`, `netfs export ... --peers`, `fleet allow`) | an allowed computer: that is root-equivalent access on purpose |
| Users and login | other players at a shared keyboard making accidents or snooping; ordinary users cannot write outside their home and /tmp, read other homes, or read pairing keys and tokens | anyone who can run Lua (they can restore the original `fs`), disk access through a disk drive, breaking the computer |
| Sandbox / virtual computers | accidents and the usual hostile tricks: file deletion outside the jail, shutdown, network and peripheral access, endless loops (CPU limit that `pcall` cannot swallow), runaway tables | native-code abuse such as `("x"):rep(1e9)` or pathological patterns, and unknown holes in CC itself |
| Web gateway | exposes only the services you list, behind a bearer token; the gateway binds to localhost by default | a gateway on the open internet without TLS (the token travels in clear text); use a TLS proxy |
| Kiosk mode | passers-by pressing Ctrl+T | a person with the keyboard and the recovery key (hold R at boot) |

## Where secrets live

Pairing keys, gateway tokens and allow lists are stored under `/etc/tsr` and are unreadable for non-administrators once the
auth package is active. Passwords are salted and stretched with iterated SHA-256 (cheap by design on a Lua VM). There is no
real random number source in ComputerCraft: keys come from a pool fed by clock, timers and key timing, which is good enough to
keep other players out and not good enough to call cryptographic.

## Supply chain

No telemetry. No self-updating without a command from you. Installs happen only when you run `pkg` or apply a role.
Third-party code is never executed from a page or a chat message: the chat bot runs only the commands you list, the fleet
agent only whitelisted jobs, the gateway only exposed services.

## Reporting problems

Open an issue (or contact the maintainer privately for anything that could harm other players' servers).
