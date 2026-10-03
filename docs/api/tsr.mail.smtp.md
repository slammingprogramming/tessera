# tsr.mail.smtp

Package: `mail`

The SMTP client (RFC 5321): hands one message to one mail server. Used by the mail transfer agent to deliver the queue and by mail clients to submit
messages (port 587 with authentication, or port 25 to the next server).
  smtp.deliver(stack, "mail.lan", { from = "a@x.lan", rcpts = { "b@y.lan" }, data = rawMessage, helo = "x.lan", port = 25,
                                    tls = "opportunistic" | "starttls" (required) | "smtps" (TLS from the first byte), auth = { user = "a", pass = "..." } })
Returns { ok, accepted = { rcpt... }, rejected = { rcpt = { code, text, permanent } }, error, tempfail, secure }.

## `M.readReply(conn, timeout)`

Read a (possibly multi-line) reply. Returns code, lines or nil + reason.

## `M.deliver(stack, host, opts)`

opts: from ("" for a bounce), rcpts, data, helo, port (25), tls, auth, timeout, store (TLS trust store), tlsName (the name the certificate must carry; default: host), size limit is taken from the server.
