# tsr.mail.client

Package: `mail`

A mail program's engine: one account on a mail server, a local copy of the mail (folders in the user's home), fetching by POP3 and sending by SMTP
(submission port 587 with the account's login). It talks to servers only over the network, so it works for ordinary users and for mail servers anywhere.
  local c = client.open({ home = "/home/alice/.mail", stack = stack, account = { address = "alice@example.lan", server = "10.0.0.1", user = "alice", pass = "..." } })
  local n = c:fetch()           local list = c:list("INBOX")           c:send({ to = "bob@other.lan", subject = "Hi", body = "..." })

## `M.loadAccount(home)`

The account file of a home folder, as a table (empty when there is none).

## `M.open(opts)`

opts: home (folder for the local mail), stack, account (table; default: read from home), tlsStore (trust store for TLS).

## `Client:fetch()`

Download new mail by POP3 into the local INBOX. Returns the number of new messages, or nil + reason.

## `Client:read(folder, n)`

The raw message with number n of a folder (marks it as read).

## `Client:delete(folder, n)`

Move to Trash; from Trash the message is deleted for good.

## `Client:replyTo(raw, all)`

A reply to a message: { to, cc, subject, body, headers } ready for send(). all = reply to everybody.

## `Client:send(m)`

Send a message. m: to (text or list), cc, subject, body, attachments = { { name, data, type } }, headers. Returns true, or nil + reason.

## `Client:saveAttachment(raw, i, path)`

Save attachment number i of a message to path.
