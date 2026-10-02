# tsr.crypto.yield

Package: `crypto`

Cooperative yielding for long computations. CC's watchdog kills a program that runs for seconds without yielding, and
a cooperative scheduler needs the CPU back now and then: heavy loops call `maybe()` and it hands control back
at most once per `interval` seconds of CPU time.

## `M.maybe()`

Yield to the scheduler if it has been a while. Safe to call anywhere a coroutine can yield.
