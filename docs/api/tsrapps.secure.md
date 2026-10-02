# tsrapps.secure

Package: `app-kit`

Authenticated request/reply messaging over rednet (or any transport with send/receive), shared by the turtle remote
and file sync. Every request carries HMAC-SHA256(passphrase, counter|command|arguments); a receiver accepts only a
counter higher than the last one seen from that sender (so captured messages cannot be replayed) and stays silent for
anything that does not verify. Replies are signed too, so the caller knows who answered.

## `S.request(secret, cmd, arg, n)`

Build a request. `n` must increase with every request from this sender (default: the current time in ms).

## `S.reply(secret, msg, ok, data)`

Build a signed reply to `msg`.

## `S.verifyReply(secret, reply, n)`

Check a reply. Returns true or false + reason.

## `S.gate(secret, state, sender, msg)`

Receiver-side check. state = { last = { [sender] = counter } } (mutated on success).
Returns the message when it is well-formed, correctly signed and fresh; otherwise nil (say nothing).

## `S.call(secret, net, target, cmd, arg, timeout)`

One request/response round trip. Returns reply.data (true when there is none), or nil + error.

## `S.rednetNet(protocol)`

The default network: rednet on the first modem found, for `protocol`.

## `S.secret(io, path, force)`

The passphrase: read from `path`, or asked for (and saved) when missing or `force` is set.

## `S.loadState(path)`

Persisted replay counters.
