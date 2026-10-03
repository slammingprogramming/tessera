# tsr.mail.spam.spf

Package: `mail-spam`

SPF (RFC 7208): which servers may send mail for a domain. The policy is a TXT record "v=spf1 ..." on the domain. Supported: all, ip4, a, mx, include,
redirect, exists and the qualifiers + - ~ ?; the macros %{i} %{s} %{l} %{o} %{d} %{h} (no transformers); the limit of 10 DNS-querying terms. ip6 and ptr are
parsed and ignored (the game's network is IPv4).
  local result, why = spf.check(mail, "10.0.0.5", "mail.example.lan", "alice@example.lan")
result: "pass", "fail", "softfail", "neutral", "none", "temperror", "permerror".

## `M.check(mail, ip, helo, sender)`

Check one connection. sender is the envelope sender ("" for a bounce: the HELO name is checked instead).
