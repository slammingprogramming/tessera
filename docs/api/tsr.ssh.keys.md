# tsr.ssh.keys

Package: `ssh`

Keys for the in-game secure shell: host keys, user keys (optionally protected by a passphrase), known_hosts and authorized_keys.

This is an in-game system: "hosts" are computers on the same Minecraft world's wired/wireless network, identified by their computer
id and name. Nothing here talks to the real Internet.

Formats (deliberately like OpenSSH's, so they are easy to read and edit):
  public key line     tsr-ed25519 <base64 of the 32 byte key> [comment]
  authorized_keys     one public key line per line ('#' comments)
  known_hosts         <id:12>,<hostname> tsr-ed25519 <base64>
  private key file    JSON; with a passphrase the seed is sealed with ChaCha20-Poly1305 under a PBKDF2-SHA256 key

## `M.encode(public, comment)`

"tsr-ed25519 <base64> comment" for a 32-byte public key.

## `M.decode(line)`

Parse a public key line. Returns public (32 bytes), comment or nil + reason.

## `M.randomart(public, title)`

OpenSSH-style "randomart" picture of a key (the drunken bishop): easier to compare by eye than a fingerprint.
Returns a list of 11 lines (a box 17 wide).

## `M.save(path, key, passphrase, comment)`

Write a key ({ secret, public }) to `path` (and the public line to path .. ".pub"). A non-empty passphrase seals the secret.

## `M.needsPassphrase(path)`

Does the private key file need a passphrase?

## `M.load(path, passphrase)`

Load a private key file. Returns { secret, public, comment } or nil + reason ("passphrase" when one is needed or wrong).

## `M.generate(path, opts)`

Create a key pair and store it. Returns the key.

## `M.hostKey()`

The host key of this computer, created on first use.

## `M.checkHost(path, id, hostname, public)`

Compare a host's key with the file. Returns "known", "new" or "changed" (and the stored public key when changed).

## `M.removeHost(path, who)`

Forget a host (by id number, id:N or hostname). Returns how many entries were removed.

## `M.authorized(path)`

Public keys allowed to log in: list of { public, comment }.

## `M.addAuthorized(path, public, comment)`

Add a key to an authorized_keys file (no duplicates).
