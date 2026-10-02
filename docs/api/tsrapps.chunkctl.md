# tsrapps.chunkctl

Package: `chunkctl`

chunkctl: drive a redstone-powered chunk loader (or any always-on machine) by rules.
  chunkctl setup | status | on | off | run
  modes:  always      on all the time
          schedule    on between two times of day (in-game hours, e.g. 6 and 22)
          players     on only while a player is within range of an Advanced Peripherals "playerDetector"
          manual      whatever `chunkctl on|off` last set
`chunkctl run` keeps the output in line with the mode every few seconds; put it in startup or /etc/tsr/init.d.

## `M.desired(cfg, ctx)`

Should the loader be on? ctx: hour (0-24 in-game time), playersNear (bool or nil when unknown).

## `M.playersNear(range, per)`

Is any player within `range` blocks of the detector? Returns true/false, or nil without a detector.

## `M.tick(cfg, env)`

Apply the mode once. Returns the state that was set.
