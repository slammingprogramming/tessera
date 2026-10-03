# tsr.mail.smtpd

Package: `mail`

The SMTP server (RFC 5321): receives mail from other servers (port 25) and from users' mail programs (port 587, which requires logging in).
Each connection is a Session, a small state machine that can be driven line by line (so it is easy to test); serve() puts it on a socket.

Rules it enforces:  no relaying for strangers (only logged-in users and the relayNetworks may send to other domains); a logged-in user may only send
as their own address; unknown local users are refused while the sender still waits (no bounces for mail we accepted by mistake: "backscatter");
size, recipient and error limits; loops are cut; login needs an encrypted connection unless allowPlainAuth is set; every message goes through the
filter chain (anti-spam, anti-virus) before it is stored.

## `Session:line(line)`

One command line. Returns the reply text and an optional action: "close", "starttls", "data" (the next lines are the message).
During AUTH LOGIN the session asks for more input: it returns the prompt and the action "auth".

## `Session:dataLine(line)`

One line of the message in DATA mode. Returns nil while the message goes on, or the final reply when the end marker came.

## `Session:finish(raw)`

Process a complete message. Returns the reply line.

## `M.serve(mail, conn, opts)`

Serve one connection. conn: a TCP socket (or a TLS session for the smtps port). opts: kind ("mx" | "submission"), secure, creds (TLS server credentials for STARTTLS).

## `M.workers(mail, n)`

Worker functions: listeners for the mx port (25), the submission port (587) and the secure submission port (465, TLS from the first byte).
