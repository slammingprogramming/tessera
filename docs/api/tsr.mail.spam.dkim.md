# tsr.mail.spam.dkim

Package: `mail-spam`

DKIM (RFC 6376) with Ed25519 (RFC 8463): a server signs the headers and body of the mail it sends with a key only it holds, and publishes the public key in DNS
(selector._domainkey.domain, TXT "v=DKIM1; k=ed25519; p=<base64>"). The receiver checks the signature, so forged "From" domains and mail altered on the way show up.
Only the algorithm a=ed25519-sha256 and the canonicalisation relaxed/relaxed are produced; simple canonicalisation is understood when verifying; RSA signatures
are reported as "none" (the game has no RSA).
  local signed = dkim.sign(raw, { domain = "example.lan", selector = "mail1", seed = secretKey32Bytes, now = 1234567890 })
  local result, domain, why = dkim.verify(mail, signed)

## `M.dnsRecord(seed)`

The TXT record (without quotes) for the public key that belongs to seed.

## `M.sign(raw, opts)`

Add a DKIM-Signature header. opts: domain, selector, seed (32 bytes), headers (names to sign, default M.DEFAULT_SIGNED), now (seconds), expires (seconds from now).

## `M.verify(mail, raw)`

Verify the DKIM-Signature headers of a message. Returns result ("pass" if any signature is good, "fail", "none" without signature,
"temperror", "permerror"), the signing domain of the deciding signature, and a reason. All = list of every outcome { result, domain, why }.
