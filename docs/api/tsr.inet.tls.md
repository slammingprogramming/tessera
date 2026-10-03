# tsr.inet.tls

Package: `tls`

A TLS-like secure channel over a TCP socket of the in-game network (for https, SMTP STARTTLS and SMTPS, POP3S, MQTT over TLS and your own services).
It is not wire-compatible with real TLS and never leaves the game, but it does what TLS 1.3 does:
  * a fresh X25519 key exchange for every connection (forward secrecy), the server proves its identity by signing the handshake with the key of its certificate
  * the certificate is checked: valid dates, the right name, and either signed by a CA you trust, or pinned the first time it was seen (and loudly refused if
    it ever changes), and not on the revoked list
  * records are encrypted and authenticated with ChaCha20-Poly1305 and sequence numbers, so nothing can be read, altered, replayed or reordered
The wrapped socket has the same methods as a TCP socket (send, receive, close, getpeername, settimeout), so protocols can run over it unchanged.

  local tls = require("tsr.inet.tls")
  local conn = socket.tcp(); conn:connect("mail.lan", 465)
  local secure, err = tls.client(conn, "mail.lan")          -- verifies the certificate against the trust store
  secure:send("hello\r\n")
  -- server side, on an accepted socket:
  local secure = tls.server(accepted, { cert = certObject, key = signingKeyPair })
Speed: public-key operations in Lua take time (a handshake may take seconds on a real computer); keep connections open and reuse them.

## `M.store(opts)`

A trust store: CA certificates, pinned server certificates (host -> fingerprint) and revocations. All files live in M.DIR unless paths are given.

## `M.verify(c, host, store, now)`

Check a server certificate. Returns true, how ("ca" | "pinned" | "new") or nil + reason ("expired", "name", "revoked", "untrusted", "changed", "bad signature").

## `M.client(sock, host, opts)`

Wrap a connected TCP socket as the client. opts: store (trust store, default M.store()), now (UTC ms), timeout (20), ignoreTime.
Returns the secure socket, or nil + reason (+ detail text).

## `M.server(sock, opts)`

Wrap an accepted TCP socket as the server. opts: cert (decoded certificate), key (signing key pair { secret, public } of the certificate),
certs (a list of { cert, key } to choose from by the name the client asks for), timeout (20).

## `M.loadCredentials(name, dir)`

Load <dir>/<name>.crt and <dir>/<name>.key. Returns { cert, key } or nil + reason.
