# tsr.mail.spam.dmarc

Package: `mail-spam`

DMARC (RFC 7489), the part that matters for a receiver: the domain owner publishes in DNS (_dmarc.domain TXT "v=DMARC1; p=reject; ...") what to do with mail that
claims to be from the domain but neither SPF nor DKIM vouches for *that* domain ("alignment"). The "organizational domain" is taken to be the last two labels of a
name, which is right for the names players choose (mail.example.lan -> example.lan) without a public-suffix list.
  local r = dmarc.check(mail, "example.lan", { result = "pass", domain = "example.lan" }, { result = "none" })
Returns { result = "pass" | "fail" | "none" | "temperror", policy = "none" | "quarantine" | "reject", apply = bool, reason = "...", record = "..." }.

## `M.check(mail, fromDomain, spf, dkim)`

fromDomain: the domain of the From header. spf = { result, domain } (domain that was checked), dkim = { result, domain } (domain of the deciding signature).
