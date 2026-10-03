# tsr.mail.pop3

Package: `mail`

The POP3 client: fetch mail from a server's mailbox.
  local c, err = pop3.connect(stack, "mail.lan", { user = "alice", pass = "...", port = 110, tls = "opportunistic" | "starttls" | "pop3s", store = trustStore })
  local count, bytes = c:stat()   local list = c:list()   local raw = c:retr(1)   c:dele(1)   c:quit()
  local mails = pop3.fetch(stack, "mail.lan", { user, pass, delete = true })   -- everything, optionally removing it from the server

## `Client:command(text)`

Send a command and read the status line. Returns true + the text, or nil + the error text.

## `Client:body()`

The body of a multi-line reply, with dot-stuffing removed.

## `Client:list(uidl)`

{ { n, size } } (or with uid when uidl is true: { n, uid }).

## `Client:quit()`

Ends the session; messages marked with dele disappear now.

## `M.connect(stack, host, opts)`

Connect and log in. opts: user, pass, port, tls ("opportunistic", "starttls", "pop3s"), store, tlsName, timeout.

## `M.fetch(stack, host, opts)`

Download all messages. Returns a list of { n, uid, raw } or nil + reason. With delete = true they are removed from the server after a clean download.
