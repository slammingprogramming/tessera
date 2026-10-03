# tsr.mail.spam

Package: `mail-spam`

Anti-spam for the mail server: puts the checks together and hangs them on the mail system.
  1. connection level: greylisting (mail.policy.rcpt), blocklists
  2. identity: SPF, DKIM, DMARC -> an Authentication-Results header, and a reject when the domain's own DMARC policy says so
  3. content: rules (each adds or removes points), the learning filter (bayes), blocklists of senders -> X-Spam-Status header; spam goes to the Spam folder,
     very high scores are refused at the SMTP level
  4. outgoing: DKIM signing of the mail users send
Mail from trusted networks (relayNetworks) and from users who logged in is never judged.
  local S = spam.install(mail, { greylist = { delay = 300 }, dnsbl = { "bl.example.lan" }, spamAt = 5, rejectAt = 12, bayes = "/var/lib/tsr/mail/bayes.lua",
                                 dkim = { ["example.lan"] = { selector = "mail1", seed = <32 bytes> } }, allow = { "friend@x.lan" }, deny = { "spammer.lan" } })

## `Spam:authFilter(ctx)`

The filter for incoming mail from other servers.

## `Spam:scoreFilter(ctx)`

The scoring filter.

## `Spam:learn(raw, isSpam)`

Teach the learning filter. raw: a whole message; isSpam: true / false.

## `Spam:test(raw, opts)`

Judge a message the way the server would for a connection from ip (for the `mailctl spam test` command). Returns the verdict, and ctx with results and headers.

## `M.makeDkimKey(path)`

Make a new signing key; the secret goes into path (base64, one line), and the DNS record to publish is returned.

## `M.install(mail, cfg)`

Hang the anti-spam checks on a mail system. Returns the control object (S.bayes, S.greylist, S:learn, S:test).
