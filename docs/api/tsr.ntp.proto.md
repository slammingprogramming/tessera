# tsr.ntp.proto

Package: `ntp`

The in-game time protocol, after NTP: a client stamps a request (T1), the server stamps its arrival (T2) and its reply (T3), the
client stamps the arrival of the reply (T4). From the four times:
    offset = ((T2 - T1) + (T3 - T4)) / 2        delay = (T4 - T1) - (T3 - T2)
Several samples are taken and the one with the smallest delay wins (the least disturbed one, as in NTP's clock filter).

Servers answer in two ways: to computers PAIRED with them through the authenticated call "ntp.query" (forged or replayed answers are
impossible, see tsr.net), and, if `open` is on (default), to anybody through the plain message "ntp.q" (like classic NTP: fine for
a trusted base network, spoofable by a hostile one). A client uses the authenticated way whenever it is paired.
Accuracy in the game: Minecraft delivers network events once per game tick (50 ms), so expect an error of a few tens of milliseconds.

## `M.serve(node, opts)`

Serve time on `node`. opts: clock (function -> corrected UTC ms), stratum (function -> number), refid (function -> text), open (bool).

## `M.query(node, target, opts)`

Ask `target` (computer id, name or peer name) for the time once. opts: clock (function -> raw UTC ms), timeout, auth (true: only
authenticated, false: only plain, nil: authenticated when paired). Returns { offset, delay, stratum, refid, host, authenticated } or nil + reason.

## `M.measure(node, target, opts)`

Several queries, keep the one with the least delay. opts as for query plus samples (default 4), spacing (seconds, default 0.3).
