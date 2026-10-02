# tsrapps.rsio

Package: `redstone`

rsio: one way to talk to redstone, whatever provides it. A "port" names a signal:
    top                  a side of this computer, analog 0-15 (on/off are 15/0)
    back:red             one colour of a bundled cable on that side
    relay_0/left         a side of a redstone relay peripheral ("redstone_relay_0" also accepted)
    relay_0/left:blue    bundled colour on a relay side
Ports work the same for the app that uses them (rs, redseq, cannon, door controllers, chunk loaders ...), which is
Tessera's "redstone as the universal fallback" for machines that have no CC integration.

## `R.parse(spec, env)`

Parse a port spec into { side, color, relay }. Returns nil + reason for nonsense.

## `R.open(spec, env)`

Open a port. env (all optional, for tests): redstone, peripheral, sleep.

## `R.level(text)`

"on"/"off"/"true"/"false"/0-15 text to a value for set(). Returns nil for nonsense.
