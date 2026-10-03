# tsr.inet.tls.cert

Package: `tls`

Certificates and a certificate authority for the in-game network: a certificate says "this public key belongs to this name, from this day to that day"
and carries a signature (Ed25519) of whoever vouches for it. A player (or a whole server) can run a CA: its public certificate goes into the trust
store of every computer that should believe it, and from then on every certificate it signs is believed. Without a CA a server certificate can still
be pinned the first time it is seen (like SSH host keys). Wildcard names ("*.lan") cover one label.

Text form (one value per line, easy to copy into a chat or a book):
  TESSERA CERTIFICATE 1
  subject: mail.lan            names: smtp.lan, pop.lan            (names is optional)
  key: <base64 public key>
  from: <UTC ms>   until: <UTC ms>
  issuer: Lab CA               issuerKey: <base64 public key of the issuer>   ca: true|false
  serial: <hex>
  signature: <base64>

## `M.issue(opts)`

Issue a certificate. opts: subject, names (more names it is valid for), key (the public key to certify), issuerName, issuerKey (signing key pair of the issuer),
days (valid for, default 365), ca (may sign other certificates).

## `M.selfSigned(subject, keypair, opts)`

A self-signed certificate for a key pair (used by servers without a CA, and for the CA's own certificate).

## `M.signatureOk(c)`

Does the signature verify against the key the certificate names as issuer's?

## `M.matches(c, host)`

Is `host` one of the names of the certificate (exact, or a wildcard for one label)?

## `M.isSelfSigned(c)`

Is the certificate self-signed (its issuer key is its own key)?
