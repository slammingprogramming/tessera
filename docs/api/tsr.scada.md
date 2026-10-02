# tsr.scada

Package: `int-mekanism`

Reactor safety supervision (SCADA-lite) for Mekanism fission reactors. The scada service watches every reactor the HAL finds
and SCRAMs it (emergency stop) as soon as a reading leaves its safe range. A SCRAM is latched: the reactor stays off until a
person checks it and runs `scada reset <name>`.

/etc/tsr/scada.cfg (all optional):
  { max_temperature = 1000,   -- kelvin
    max_damage = 20,          -- percent
    min_coolant = 20,         -- percent filled
    max_waste = 90,           -- percent filled
    poll = 2,                 -- seconds between checks
    alarm = "top",            -- redstone port switched on while any reactor is latched (siren, lamp...) }

The defaults are deliberately cautious guesses for Mekanism 10.x; check them against your build in-game. A reading the machine
does not provide is ignored, EXCEPT that a reactor that cannot be read at all (chunk unloaded, error) is treated as unsafe.

## `M.assess(dev, cfg)`

Why this reactor is unsafe, or nil when it is fine. dev is a HAL device with the reactor capability.

## `M.check(env, cfg)`

Check every fission reactor once. Returns a list of { name, ok, reason, scrammed }.

## `M.reset(name)`

Clear the latch of a reactor (a person has checked it).

## `M.daemon()`

The scada service.

## `M.cli(args, io, env)`

scada status | reset <reactor> | config
