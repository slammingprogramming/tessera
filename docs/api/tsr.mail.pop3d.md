# tsr.mail.pop3d

Package: `mail`

The POP3 server (RFC 1939, with CAPA from RFC 2449, STLS from RFC 2595 and UIDL/TOP): lets a user fetch the mail in the INBOX of their mailbox.
Like the SMTP server it is a Session state machine (easy to test line by line) with serve() for a socket.
  AUTHORIZATION: USER / PASS (only on an encrypted connection unless allowPlainAuth), CAPA, STLS, QUIT
  TRANSACTION:   STAT, LIST [n], RETR n, DELE n, NOOP, RSET, TOP n lines, UIDL [n], QUIT
  UPDATE:        on QUIT the messages marked with DELE are removed (and only then)
One session per mailbox at a time (the maildrop lock of the RFC). Too many wrong passwords from one address lock it out for ten minutes, the same as for SMTP.

## `Session:line(line)`

One command line. Returns the reply, an action ("close", "starttls") and, for multi-line replies, the list of body lines.

## `M.serve(mail, conn, opts)`

Serve one connection.

## `M.workers(mail, n)`

Worker functions: listeners for POP3 (110) and, with TLS credentials, POP3S (995).
