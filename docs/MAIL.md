# Mail between players

Tessera has a complete **mail system for the in-game internet**: SMTP between servers and from mail programs, POP3 for reading, mailboxes with quotas,
aliases and lists, a delivery queue with retries and bounce messages, encrypted connections, **anti-spam**, **anti-virus**, and a text mail program.
It is built on the network stack described in [NETWORKING.md](NETWORKING.md) and, like it, lives entirely inside the game: it does not talk to real
mail servers and real mail servers cannot talk to it.

> Status: built and tested in CraftOS-PC on a simulated network (two servers, a client, loss and outages). Not run in real Minecraft yet.

## What you install

| Package | What it is |
|---|---|
| `mail` | The server (`maild`: SMTP on 25 and 587, POP3 on 110, queue), the mail program `mail`, the admin tool `mailctl`. |
| `mail-spam` | SPF, DKIM (Ed25519), DMARC, greylisting, blocklists in DNS, scoring rules, a learning filter. Optional. |
| `av` | The anti-virus (see [below](#anti-virus)). Scans mail attachments, floppies and, if you want, packages. Optional. |
| `tls` | Certificates, so that STARTTLS, SMTPS (465) and POP3S (995) work. Optional but needed for passwords on untrusted links. |

The installer's **Mail server** use case installs all of them. By hand:

```
pkg install mail mail-spam av tls
mailctl init mail.example.lan example.lan     # writes /etc/tsr/mail/mail.lua
mailctl user add alice                        # asks for a password
mailctl dns                                   # lists the DNS records the domain needs
svc start maild
```

## Making a domain work

For other servers to deliver mail to `alice@example.lan`, DNS must say where the mail server is. `mailctl dns` prints the records:

```
mail.example.lan.   A    10.0.0.25
example.lan.        MX   10 mail.example.lan.
example.lan.        TXT  "v=spf1 mx -all"                       # only this server sends mail for the domain
_dmarc.example.lan. TXT  "v=DMARC1; p=quarantine"               # what receivers do with forged mail (start with p=none)
mail1._domainkey.example.lan.  TXT  "v=DKIM1; k=ed25519; p=..." # from: mailctl dkim key mail1
```

Add them with `dnsctl add ...` on your name server. If you have no DNS at all, a mail server falls back to the host name given as the destination.

## Using it

```
mail account set address=alice@example.lan server=10.0.0.25 user=alice
mail fetch                 # download new mail (POP3) into ~/.mail
mail                       # interactive: list, read 3, reply 3, send bob@other.lan -s "Hi", delete 3, spam 4, quit
```

The mail program keeps a **local copy** of your mail (folders Inbox, Sent, Drafts, Trash, Spam) and talks to the server only over the network, so it
works for ordinary users on any computer. Sending uses the submission port (587) with your password, over TLS if the server offers it (`tls=starttls` to insist).
Attachments (`send ... -a file`) are encoded as real MIME; replies keep the thread headers.

## The server in detail

* **SMTP** (RFC 5321): EHLO capabilities (SIZE, STARTTLS, AUTH PLAIN/LOGIN), envelope checks, limits on size, recipients and errors, loop detection (too many `Received` headers),
  `Return-Path`/`Delivered-To`/`Received` headers added the way real servers do.
* **No open relay.** Only logged-in users and the networks in `relayNetworks` may send to other domains; a user may only send as themselves; unknown local users are refused
  while the sender is still connected (so a bounce is never sent to a forged address: no "backscatter").
* **The queue** (`/var/spool/mail/queue`): tries again after 5 min, 15 min, 1 h, 4 h, 12 h (configurable), gives up after 5 days and sends the sender a **bounce** (a delivery status message with
  the reason and the beginning of the original). `mailctl queue` shows and flushes it. MX records are used in order of preference.
* **Mailboxes** (`/var/mail`): one file per message, an index with flags, a quota per user, folders, `+tag` addresses (`alice+news@...` goes to `alice`), **aliases and lists**
  (`mailctl alias add team alice bob carol@other.lan`). Mailbox passwords are salted and stretched (PBKDF2).
* **POP3** (RFC 1939): USER/PASS (only over TLS unless you allow plain logins), STAT, LIST, RETR, DELE, TOP, UIDL, CAPA, STLS; one session per mailbox; five wrong passwords from one address lock it out for ten minutes.
* **Encrypted connections:** STARTTLS on 25/587, SMTPS on 465, STLS/POP3S on 110/995 with a certificate from `tlsctl`. Between servers encryption is *opportunistic* (used when offered).

## Anti-spam (`mail-spam`)

Each incoming message from another server runs through these checks, in order. Mail from your own trusted networks and from logged-in users is never judged.

1. **Greylisting** (optional, `greylist = { delay = 300 }`): a sender never seen before is told to try again; real servers retry from their queue, most spam software does not. After a successful retry the sender's network is trusted.
2. **SPF** (RFC 7208): does the sending address match the domain's list of allowed servers (`a`, `mx`, `ip4`, `include`, `redirect`, `exists`, macros, the limit of 10 lookups)?
3. **DKIM** (RFC 6376 with Ed25519, RFC 8463): the sending server signs headers and body; a changed message or a forged `From` domain fails. Your server **signs outgoing mail** once you publish a key (`mailctl dkim key mail1`).
4. **DMARC** (RFC 7489): the domain owner says what to do with mail that is not aligned with the domain's SPF or DKIM; `p=reject` mail is refused while the sender is still connected.
5. **Scoring rules**: shouting subjects, "you have won" wording and in-game scams ("free op", "free diamonds"), links to raw addresses, HTML-only mail, a `Reply-To` or display name that points elsewhere, dangerous attachments (`.exe`, double extensions), missing headers, and results of the checks above.
6. **Blocklists** in DNS (DNSBL): a list server a player runs, each list with its own score.
7. **A learning filter** (naive Bayes with Robinson smoothing): teach it with `mailctl spam learn spam|ham <file>`; it judges once it has seen three of each.

Scores add up: from `spamAt` (5) a message goes to the **Spam** folder with `X-Spam-Status` and `X-Spam-Level` headers; from `rejectAt` (12) it is refused with 554. Everything is explained in the
headers (`tests=...`). Allow and deny lists: `mailctl spam allow add friend@x.lan`, `mailctl spam deny add spammer.lan`. `mailctl spam test <file>` shows how a stored message would be judged. The
`Authentication-Results` header records SPF, DKIM and DMARC for the receiving user.

## Anti-virus

In ComputerCraft a "virus" is a script that harms other players: wipes a disk, downloads and runs unknown code, copies itself to floppies, switches off Ctrl+T, steals password files, floods the
network, or runs administrator commands. The `av` package finds them in three ways:

* **Behaviour rules** (about 20, each with a score) read the program, not its name: `fs.delete("/")`, download-and-run, running code that arrived over rednet (a backdoor), writing a startup file, copying itself
  to a drive, reading key files and sending them, fake password prompts, process and message floods, code assembled from character codes, interpreter tricks, `commands.exec("op ...")`, attacks on the anti-virus itself. Combinations
  add up (`DROPPER`, `WORM`). From score 5 a file is *suspicious*, from 10 *malicious*. Comments are ignored; ordinary programs are not reported (the test suite scans everything Tessera installs and expects zero findings).
* **Signatures:** the SHA-256 of whole files known to be bad (or known good) and patterns, in **definitions** files. Definitions are updated with `av update <url or path>`; an update is only accepted when it carries a
  signature of a **publisher you trust** (`av trust add <name> <key>`) and its version is newer. Anyone can run a publisher (`av defs keygen`, `av defs sign`); the project does not decide what you trust.
* **A test file:** `av testfile /t.txt` writes the standard harmless test string; `av check /t.txt` must report it (like EICAR).

Where it looks: `av scan <path>` (add `--quarantine` to move findings into `/var/lib/tsr/av/quarantine`, from where `av quarantine restore` brings them back), floppies when inserted (service `avd`),
**mail** (incoming attachments and code pasted in a message: malicious ones are refused, doubtful ones go to the Spam folder; users cannot *send* malware out), and, with `av config set scan_packages=true`,
files that the package manager is about to install from any source (a malicious file blocks the install; nothing is written).

Limits: these are heuristics. They catch the usual mischief and copy-pasted "free op" scripts, not a determined author; for code you do not trust use the `sandbox` package.

## Honest limits

* Not IMAP: read with POP3 (INBOX only) or, on the server computer, with the local store; the mail program keeps its own folders.
* No S/MIME or PGP integration (use the `pgp` package on the text of a message).
* Greylisting and the delivery queue use the real clock when the game offers it (`os.epoch`), otherwise the computer's own.
* Mail is slow where the network is slow; a large attachment over several hops takes a while. The default size limit is 1 MB.
* Tested in simulation only.
