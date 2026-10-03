# tsr.mail.spam.greylist

Package: `mail-spam`

Greylisting: a server we have never heard from is told "try again later" (a temporary 451). Real mail servers retry (they have a queue); most spam software does not.
The first contact of a (sender network, sender, recipient) triplet is refused; after `delay` seconds the same triplet is let through and remembered; a sender network
that has passed `trustAfter` triplets is let through at once from then on. Mail from trusted networks and logged-in users is never delayed.
  local g = greylist.new(mail, { delay = 300, window = 14400, keep = 3 * 86400, trustAfter = 3 })
  mail.policy.rcpt = g:hook()

## `Grey:check(ip, sender, rcpt)`

Decide for one recipient. Returns nil to accept, or the SMTP reply { code, text }.

## `Grey:expire(now)`

Forget old triplets (called now and then; bounded memory matters on a small computer).

## `Grey:hook()`

A function for mail.policy.rcpt.
