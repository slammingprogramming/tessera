# Security model

Tessera tries to be honest about what it protects. A ComputerCraft computer is a single Lua program with a keyboard; nothing
inside it is a hard boundary against someone who can run code on it or who can break the computer and read its disk.

## What is protected, and against whom

| Layer | Protects against | Does not protect against |
|---|---|---|
| Package installs | corrupted or truncated downloads (every file is verified by SHA-256 before it is written), interrupted installs (journal + rollback), losing your edits (replaced files are backed up), **a tampered or malicious registry host** (the registry index is signed, see "Signed registries" below) | a stolen signing key; installing from an unsigned source after you turned the policy to `off` or `warn`; a registry that is signed but hostile because its owner is |
| Network pairing | other players impersonating a computer, forging or replaying messages (HMAC with a per-peer key, counters, a 2-minute freshness window), reading *encrypted* calls | someone who watches the pairing exchange and can try about 10^15 codes per second (the one-time code has about 50 bits), someone who can read the key file on a computer, radio-level denial of service, traffic analysis. Discovery, ping and time replies are public by design. |
| Secure shell (`ssh`) | eavesdropping and tampering on the wire (X25519 key exchange, Ed25519-signed handshake, ChaCha20-Poly1305 records with counters), impersonation of a server after the first connection (known-hosts check; a changed key is refused), password guessing (off by default, rate limit and lockout) | the first connection if you accept an unknown fingerprint without comparing it, someone who can read your private key file (it can be passphrase-protected), a server that has been taken over |
| Firewall (`fw`) | strangers sending messages the computer should not process (by sender, type and rate), floods | anything the rules allow; radio-level jamming |
| Encrypted folders (`vault`) | someone reading the files on disk without the passphrase or recovery key; changed, swapped or truncated chunks are detected | a keylogger, memory contents while the vault is mounted, a weak passphrase |
| `pgp` | forged or altered signed files; reading encrypted files without the key; wrong keys (web of trust, revocation) | key theft; a trusted person who certifies the wrong key |
| Remote shell, screen, files, fleet | strangers: every one of them refuses computers that are not paired *and* explicitly allowed (`rsh allow`, `rscreen allow`, `netfs export ... --peers`, `fleet allow`) | an allowed computer: that is root-equivalent access on purpose |
| Users and login | other players at a shared keyboard making accidents or snooping; ordinary users cannot write outside their home and /tmp, read other homes, or read pairing keys, ssh keys and tokens | anyone who can run Lua (they can restore the original `fs`), disk access through a disk drive, breaking the computer |
| Sandbox / virtual computers | accidents and the usual hostile tricks: file deletion outside the jail, shutdown, network and peripheral access, endless loops (CPU limit that `pcall` cannot swallow), runaway tables | native-code abuse such as `("x"):rep(1e9)` or pathological patterns, and unknown holes in CC itself |
| Web gateway | exposes only the services you list, behind a bearer token; the gateway binds to localhost by default | a gateway on the open internet without TLS (the token travels in clear text); use a TLS proxy |
| Kiosk mode | passers-by pressing Ctrl+T | a person with the keyboard and the recovery key (hold R at boot) |
| Archives | `tar` refuses absolute paths and `..` before it writes anything; gzip checks CRC and size | a hostile archive that is merely huge (check the size first) |

## Signed registries

The package registry is static files on a web host. A host (or an attacker who controls it) could serve different files, so the
index is **signed** by a registry key:

* `index.json` carries a serial number and an expiry, and for every package the SHA-256 of its description. It is signed with
  Ed25519 (`index.json.sig`: format, algorithm, key id, signature). The signed data is
  `"tessera-signature-v1" 0 context 0 SHA-256(data)`, so a signature made for one purpose cannot be replayed for another.
* Package descriptions are checked against the hashes in the signed index, and every file against the hashes in its
  description: one signature covers everything that gets installed.
* **Rollback protection:** a source's serial may never go backwards, and an expired index is refused, so an attacker cannot
  replay an old (vulnerable) registry.
* **Trust file** `/etc/tsr/trust.json` holds the keys you trust; the build embeds the project's public key. Keys can be
  replaced by a *signed* update from a key you already trust (rotation). Policy `pkg.signatures`:
  `require` (default whenever a trusted key exists), `warn`, `off`.
* Offline bundles carry the signed index; pasted Pastebin snapshots carry it too. A LAN mirror serves the signature files
  and the trust file, but clients verify them themselves: **a mirror cannot forge packages**.
* The private signing key is generated by the maintainer on their own machine (`node tools/build/keys.mjs gen`), is never
  committed, and signs in the release pipeline only.

What signing does not do: it does not make the packages' *code* trustworthy, only authentic. If the signing key is stolen,
rotate it with a signed update from a backup key.

## Cryptography in the box

`crypto` provides SHA-512, Ed25519, X25519, ChaCha20-Poly1305, HKDF and PBKDF2 in pure Lua, with the known-answer vectors
from the RFCs and cross-checks with OpenSSL in the tests. It is used by signed registries, `ssh`, `pgp` and `vault`. (Network pairing and calls use the older HMAC code in `net`;
time replies from a time server you are paired with are authenticated by the pairing key, replies from strangers are plain and are
limited by the panic limit, which refuses large corrections.) Public-key operations take noticeable time on a real computer; the library
yields cooperatively so the rest of the system keeps running. `doctor` measures the speed.

## Where secrets live

Pairing keys, ssh keys, vault headers, gateway tokens and allow lists are stored under `/etc/tsr` (and `~/.ssh`, `~/.pgp`) and are
unreadable for non-administrators once the auth package is active. Passwords are salted and stretched with iterated SHA-256;
`vault` uses PBKDF2 with a work factor chosen for the game (cheap by design on a Lua VM).

**Randomness.** There is no real random number source in ComputerCraft. Keys come from a pool fed by the clock, timers,
and key-press timing (commands that make keys ask you to press a few keys, `collect`), plus a seed file kept between runs. That
keeps other players out; it is not a source you should call cryptographic.

## Supply chain

No telemetry. No self-updating without a command from you. Installs happen only when you run `pkg` or apply a role.
Third-party code is never executed from a page or a chat message: the chat bot runs only the commands you list, the fleet
agent only whitelisted jobs, the gateway only exposed services.

## Things that are in the game only

`ssh`, `pgp`, `torrent`, `dns`, `fw`, `netmon` work between computers of one world. Nothing connects to the real Internet except
what the *server administrator* has enabled for HTTP, and the one optional clock source (`ntp add http`). `netmon`'s promiscuous
mode shows that radio is public: anyone with a modem in range can read plain messages, which is why the secure tools encrypt.

## Reporting problems

Open an issue (or contact the maintainer privately for anything that could harm other players' servers).
