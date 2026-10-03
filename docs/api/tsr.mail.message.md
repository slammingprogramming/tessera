# tsr.mail.message

Package: `mail`

Internet messages (RFC 5322) and MIME (RFC 2045-2049): headers (folding, encoded words), addresses, multipart bodies with attachments, base64 and
quoted-printable, building new messages. Messages are kept as text with CRLF line ends, exactly as they travel between mail servers.

## `M.parseAddress(text)`

"Alice Example <alice@example.lan>", "alice@example.lan", "<a@b>" -> { name, addr, localPart, domain } or nil.

## `M.parseAddressList(text)`

A header value with several addresses -> list of parsed addresses (commas inside quotes and angle brackets do not split).

## `M.decodeWords(s)`

Encoded words in headers (RFC 2047): =?UTF-8?B?...?= and =?...?Q?...?= are decoded to plain text (non-ASCII characters become "?").

## `M.parseHeaders(text)`

Split text into the header block and the body at the first empty line. Returns headers (list of { name, value } in order) and body.

## `Message:header(name)`

The first header of that name (case-insensitive), decoded; or nil.

## `M.parse(text)`

Parse a complete message. Returns a message object: headers, body (raw), :header(), :parts() ...

## `Message:parts()`

The parts of a message as a flat list: { { type, name, data, disposition } }; a message without MIME structure is a single text/plain part.

## `Message:text()`

The text of the message: the first text/plain part (or text/html with tags removed), line ends as LF.

## `M.newId(host)`

A Message-ID of the form <time.random@host>.

## `M.build(m)`

Build a message. m: from (address text), to / cc (list of address texts or one string), subject, body (text), attachments = { { name, data, type } },
headers = { Name = value }, date (ms), messageId, host (for the Message-ID).

## `M.prepend(text, lines)`

Put header lines in front of a message (Received, X-Spam-..., Authentication-Results).

## `M.dotStuff(text)`

Dot-stuffing for SMTP DATA (RFC 5321 4.5.2).
