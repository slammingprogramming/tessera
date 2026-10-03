# Real-world computing, in the game

Tessera borrows ideas from Windows, Linux, macOS and from the software that runs the Internet, and rebuilds them for a
Minecraft world. **Everything here lives inside the game.** Nothing connects a player's computer to a real SSH server, a
real torrent swarm or a real mail server, and nothing is meant to. The commands have familiar names and familiar
behaviour so that the knowledge carries over; the protocols are our own, designed for ComputerCraft's limits (small
messages, slow Lua, a cooperative scheduler, no real random numbers).

The one deliberate exception is the **clock**: `ntp` can read the real UTC time from an HTTPS source if the server allows
HTTP, because the real time is a harmless, useful fact. Everything else stays in the world.

> Status: built and tested in CraftOS-PC (an emulator). Nothing here has run in real Minecraft yet; speed in particular is
> unknown until someone runs `doctor` on a real computer. The cryptography is checked against known-answer vectors from
> OpenSSL and other implementations, but it is **hobby-grade for a game**: do not protect anything real with it.

## At a glance

| In the real world | In Tessera | Package | What is the same, what is different |
|---|---|---|---|
| NTP / chrony / `timedatectl` / `date` | `ntp`, `ntpdate`, `timedatectl`, `date` | `ntp` | Same four-timestamp exchange and offset/delay maths, step vs slew, time zones with daylight saving. Sources: in-game time servers (any computer can run one), an HTTPS UTC source if allowed, or set by hand. |
| SSH, scp, ssh-keygen, authorized_keys, known_hosts | `ssh`, `scp`, `ssh-keygen`, `ssh-copy-id`, `sshd` | `ssh` | Same shape: host keys with fingerprints and trust-on-first-use, ephemeral key exchange (X25519), signed handshake (Ed25519), authenticated encryption (ChaCha20-Poly1305), keys instead of passwords. Own wire protocol; not compatible with OpenSSH. |
| GnuPG / PGP | `pgp` (also `gpg`) | `pgp`, `pgp-keyserver` | Key pairs, self-signatures, certification and a web of trust, revocation, detached and clear signatures, encryption to several recipients or by passphrase, key servers. Own format; not OpenPGP-compatible. |
| BitTorrent, magnet links | `torrent` | `p2p` | Pieces with SHA-256, rarest-first, per-peer workers, rate limits, bans, optional tracker, magnet links. Also shares package files, so computers without HTTP can install from neighbours. |
| iptables / Windows Firewall | `fw` | `firewall` | Rules by sender, message type and rate; paired computers; replies to our own requests always pass. |
| DNS (BIND, `host`, `dig`) | `dns`, `host`, `dig` | `dns` | Zones and records, relative and absolute names, a resolver that the network layer consults; a server role. |
| BitLocker / FileVault / LUKS | `vault` | `vault` | An encrypted folder you mount with a passphrase, with a recovery key, authenticated chunks and crash-safe writes. File names are hidden too. |
| tar, gzip, zcat | `tar`, `gzip`, `gunzip`, `zcat` | `archive` | Standard ustar and gzip/DEFLATE: real tools read what Tessera writes and the reverse (checked against zlib and git in the tests). |
| diff, patch | `diff`, `patch` | `diff` | Unified diffs, the same format as `diff -u` and git (git applies Tessera's patches), `patch -R`, hunks that moved. |
| tcpdump / Wireshark | `netmon` | `netmon` | Watch this computer's messages, or listen on modem channels for other computers' traffic ("promiscuous mode"); shows how well each message is protected. |
| Package signing (apt, Windows Authenticode) | built into `pkg` | `crypto`, `pkg` | Registry index signed with Ed25519, rollback protection, key rotation by signed updates, a policy (require / warn / off). |
| Windows Event log / Reliability Monitor, `sfc`, `fsck` | `doctor` | `doctor` | Checks the environment and VM quirks, cryptography answers and speed, installed files, signatures, services, log, clock, network; writes a report. |
| Crafting-table macros, auto-crafters | `autocraft` | `craft` | A turtle with a crafting table makes an item and everything it is made of from a chest. |
| Hardware drivers for mods (Tom's Peripherals) | `hal` drivers | `hal-toms` | Names checked against the mod's source. |

Also built, on the same principle (inside the world only): a complete **in-game internet** (Ethernet and Wi-Fi, IPv4, TCP, DHCP, DNS, switches, routers, NAT,
BGP peering, a web) in [NETWORKING.md](NETWORKING.md); **mail** with SMTP, POP3, anti-spam and anti-virus in [MAIL.md](MAIL.md); and **MQTT, Modbus and a smart-home hub**
in [IOT.md](IOT.md).

## Time: `ntp`

You decide where the time comes from, per computer:

* **An in-game time server.** Any computer with the `ntp` package can run `ntp serve on`. Others point at it with
  `ntp add peer <name>` (and `ntp up <n>` to prefer one). The exchange is the real NTP algorithm over rednet, so the delay of a message is measured and
  subtracted.
* **HTTPS UTC source (optional).** Only if the server allows HTTP and you add it: `ntp add http <url> [json|header]`. It reads a UTC time
  from a JSON field or from the `Date` header. It is rate-limited so that a loop cannot hammer a site.
* **By hand.** `ntp set 2026-10-02 18:30` or `date -s "2026-10-02 18:30:00"`. Manual mode keeps automatic sources from overriding you until `ntp auto`.
* **The in-game clock** is always available and is the fallback.

Large errors are corrected in one **step**, small ones are **slewed** (corrected gradually) so cron jobs never see time run
backwards by much; a correction larger than the panic limit (one hour by default) is refused unless you say `ntp sync --force`. Time zones, including daylight-saving rules for many zones, were
checked against the real time-zone database for every transition from 2024 to 2030. `cron` understands `daily` and
`weekly` entries in the corrected time.

## Secure shell: `ssh`

```
sshd status                      # on the server: is it running, what is its fingerprint
ssh-keygen                       # on your computer: make a key pair
ssh-copy-id alice@vault-server   # asks for the password once, installs your public key
ssh alice@vault-server           # connect; the first time you are asked to check the fingerprint
scp -r base/ alice@vault-server:/backups
```

* Passwords are **off by default** on the server (keys only). Turn them on with `sshd password on` if you must; there is a
  rate limit and a lockout.
* The first connection asks you to confirm the server's fingerprint (compare it with what `sshd fingerprint` shows on the
  server itself); afterwards a changed key is refused loudly.
* Messages are encrypted and authenticated with counters, and lost messages are retransmitted, so a flaky wireless link does
  not corrupt the session.
* This is meant for the computers of one world. It is not compatible with OpenSSH and does not reach outside the game.

## Keys and signatures: `pgp`

Create a key (`pgp --gen-key "Alice"`), sign files (`--sign`, `--clearsign`, `--detach`), encrypt to people
(`--encrypt -r bob`) or with a passphrase (`--symmetric`), certify other people's keys, set trust levels
and let the web of trust decide whether a key is valid. Run the `keyserver` service on a server so players can publish and
fetch keys (`--send-keys`, `--recv-keys`, `--search-keys`). The key format and armor are Tessera's own (not OpenPGP), so
files are only readable by Tessera computers.

## Peer-to-peer: `torrent`

```
torrent create /usr/share/maps --name maps -o maps.tsrt     # hash the content
torrent seed maps.tsrt /usr/share/maps                       # offer it
torrent get magnet:?xt=urn:btmh:1220<hash> -d /downloads     # fetch it from anybody who has it
```

Pieces are checked with SHA-256 before they are kept, so a lying peer can waste your time but not corrupt your files; peers
that send bad data are banned. Upload and download rates are limited so that a swarm does not flood the world's modem
network. `torrent packages on` lets a computer share its installed package files, which the package manager uses as a
`p2p` source.

## Firewall, DNS, vault, archives, diff, monitor

* **`fw`**: `fw preset lockdown` allows only paired computers plus discovery; `fw add allow type ssh from paired`;
  `fw test <id> <type>` tells you what would happen. Dropped messages are logged (`fw log`).
* **`dns`**: names for computers that follow them when ids change. `dns zone add <name> A <id>`, `host <name>`, `dig <name>`. The network layer
  asks the resolver when you ping or connect by name.
* **`vault`**: `vault create /secrets-store`, `vault open /secrets-store /secret`, `vault close /secret`. Write down the recovery
  key when it is shown; it is shown once.
* **`tar`, `gzip`, `gunzip`, `zcat`**: `tar czf backup.tgz /home`, `tar xf backup.tgz -C /restore`. Unsafe paths in archives
  (`..`, absolute) are refused before anything is written.
* **`diff`, `patch`**: `diff -U 3 old.lua new.lua > fix.patch`, `patch -i fix.patch old.lua`, `patch -R` to undo, `--dry-run`
  to test. Nothing is changed unless every hunk fits.
* **`netmon`**: `netmon --type ssh,rpc`, `netmon --drops`, `netmon sniff 1-30`. The summary says whether each kind of message
  was encrypted, signed or plain. Only administrators may run it when accounts exist.

## Honest limits

* **Speed.** Public-key crypto in Lua is slow. Tessera yields cooperatively so the computer stays responsive, and uses
  Ed25519/X25519 (not RSA) because they are the cheapest option, but a handshake may take seconds on a real computer. `doctor`
  measures it.
* **Randomness.** ComputerCraft has no real random source. Keys are generated from a pool fed by timing noise and by asking you
  to press keys (`collect`); a seed file is mixed in. Good enough to keep other players out; do not call it cryptographic.
* **Not interoperable.** SSH and PGP here are Tessera's own protocols and formats. `tar`, `gzip` and unified diffs *are* the
  standard formats.
* **Physical security.** Anyone who can run Lua on a computer, or break it and read its disk, can read its keys. See
  [SECURITY.md](SECURITY.md).
