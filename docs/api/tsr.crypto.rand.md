# tsr.crypto.rand

Package: `crypto`

Random bytes for keys, nonces and challenges.

HONEST LIMITS: ComputerCraft has no real random number source. This pool mixes everything a computer can observe
(millisecond clock, CPU clock, object addresses, timers, the world time, the computer's id, event timings you feed in with
`addEntropy`) and a seed file that survives reboots, and runs it through SHA-512. That is good enough to keep other players
from guessing keys, but a serious key (a registry signing key, a server's host key) should be generated on a real
computer with real randomness or with `collect`, which stirs in the timing of your own key presses.

## `M.addEntropy(...)`

Mix more entropy into the pool (anything: event timings, text a person typed, a peer's nonce).

## `M.bytes(n)`

n random bytes as a binary string.

## `M.saveSeed()`

Write a fresh seed file so the next boot starts from a different pool state (best effort).

## `M.collect(count, show, wait)`

Interactive collection for important keys: asks `count` times for a key press (via `wait`, default a keypress) and stirs in
the millisecond timing between the presses. `show(i, count)` may draw progress.
