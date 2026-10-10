# tsr.mail

Package: `mail`

The mail system of one computer: which domains it serves, where mail for them goes (mailboxes, aliases, lists), the queue of mail waiting to be
delivered to other servers with retries and bounce messages, and the chain of filters (anti-spam, anti-virus) that every incoming message passes.

  local mail = require("tsr.mail").new(stack, {
    hostname = "mail.example.lan", domains = { "example.lan" },
    aliases = { postmaster = "alice", ["team@example.lan"] = { "alice", "bob", "carol@other.lan" } },
    relayNetworks = { "10.0.0.0/8" },          -- computers here may send mail to anywhere without logging in
    maxSize = 1048576, retryDelays = { 300, 900, 3600, 14400 }, maxAge = 432000,
  })

## `Mail:setRouting(domains, relayNetworks, aliases)`

Which domains this server accepts mail for, which client networks may send anywhere, and the aliases (replaces the previous settings; the server calls it again
when the administrator changes them).

## `Mail:now()`

The time that queue ages and retries are counted in (seconds; wall-clock when the game offers it). cfg.now replaces it in tests.

## `Mail:failureRecord(ip)`

The record of failed logins for a client address (shared by SMTP and POP3). Records with nothing to remember are dropped now and then, so that addresses which
tried once do not accumulate for ever.

## `Mail:mayRelay(ip)`

May this client address send mail to any domain without authenticating?

## `Mail:expand(addr, depth, seen)`

Expand a recipient address into what it delivers to: { { mailbox = "alice" }, { remote = "carol@other.lan" } }, or nil + reason when it is unknown.
Handles local mailboxes, +tag addresses, aliases and lists (which may point to remote addresses), with a limit against loops.

## `Mail:deliverLocal(mailbox, raw, folder, sender, rcpt)`

Put a message into a local mailbox. folder defaults to INBOX (Spam for tagged mail). Returns true or nil + reason.

## `Mail:enqueue(sender, rcpts, raw, opts)`

Queue a message for delivery. rcpts: addresses (local and remote). Returns the queue id.

## `M.queueList(dir)`

The entries of a queue folder, oldest first (also used by mailctl, which has no running server object).

## `Mail:dnsMx(name)`

MX records as { { preference, exchange } } sorted by preference.

## `Mail:bounce(meta, failures, raw)`

Tell the sender that delivery failed. Bounces of bounces are dropped.

## `Mail:processEntry(meta)`

Try to deliver one queue entry. Returns "done", "retry" or "failed".

## `Mail:processQueue(force)`

Deliver everything in the queue that is due (all of it with force). Returns counts.

## `Mail:queueWorker(interval)`

The queue worker: delivers due mail every few seconds, forever.

## `Mail:addFilter(name, fn, order)`

Add a filter to the incoming chain: fn(ctx) returns nil to pass, or a verdict { "reject", code, text } / { "spam", reason }. Lower order runs first.
ctx: ip, helo, sender, rcpts, raw, message (parsed), authUser, add (list of header lines to add), results (table for notes like spf = "pass").

## `Mail:addOutboundFilter(name, fn)`

Filters for mail that users send: fn(ctx) with ctx = { session, user, sender, rcpts, raw }; may return { "reject", code, text }.

## `Mail:runFilters(ctx)`

Run the filters. Returns verdict: { "accept" }, { "spam", reason, score }, or { "reject", code, text }.
