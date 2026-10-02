# tsr.profile

Package: `core`

Device profile detection. A profile is chosen from what the computer physically is; the user may override it with
config key `system.profile` (e.g. "server", "tv", "node"). Colour vs. monochrome is NOT a profile: it is a runtime
capability (see M.capabilities) so one code base serves both.

## `M.detect()`

What the hardware alone suggests.

## `M.get()`

The active profile: user override if valid, otherwise detected.

## `M.capabilities()`

Runtime capability flags used by UI and driver selection.
