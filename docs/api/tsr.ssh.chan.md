# tsr.ssh.chan

Package: `ssh`

The cryptographic core of the in-game secure shell: handshake transcript, key derivation, signatures and the record layer.

  client                                   server
  hello  { sid, ce }              ->                       ce = client ephemeral X25519 public key
                                  <-  reply { sid, se, hostkey, sig }
         shared = X25519(ce, se)         sig = Ed25519(host key, SHA-256(transcript))   (transcript binds sid, both ids, ce, se, hostkey)
         keys   = HKDF-SHA256(shared, salt = transcript hash)  ->  one ChaCha20-Poly1305 key per direction
  then every message is an authenticated, encrypted record with a counter (replays and reordering are rejected).
Forward secrecy: the ephemeral keys exist only for the session, so a later theft of a host or user key does not reveal old
sessions. The client decides whether it trusts the host key (known_hosts); the server decides whether it trusts the user
(authorized_keys or password) inside the encrypted channel. This resembles SSH and the Noise framework's NK pattern, but it
is its own small protocol for ComputerCraft networks (not wire compatible with real SSH, and it never leaves the game).

## `M.transcript(sid, clientId, serverId, ce, se, hostPublic)`

SHA-256 over everything both sides must agree on (32 bytes).

## `M.deriveKeys(shared, transcriptHash)`

The two directional keys: clientToServer, serverToClient.

## `M.userSign(userSecret, h, user)`

Proof that the client owns a user key for this very session: a signature over the transcript and the user name.

## `M.seal(key, direction, sid, n, body)`

Encrypt a message body (a table) as record number `n` in `direction`. Returns base64 text.

## `M.open(key, direction, sid, n, text)`

Decrypt and parse a record. Returns the body table, or nil when it does not authenticate.
