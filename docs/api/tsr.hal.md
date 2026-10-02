# tsr.hal

Package: `hal`

Hardware abstraction layer (HAL). Every attached peripheral (and every declared "virtual" device, such as a machine that is
only switched by redstone) becomes a device with
  caps     what it can do: "energy", "fluid", "inventory", "machine", "redstone", "reactor", "display", "audio", "sensor"...
  read     named readings:  device:get("energy.percent")
  act      named actions:   device:act("machine.stop")
Drivers translate between a device's own API and these names. Core drivers live in tsr/hal/drivers/*.lua; integration packs
(Advanced Peripherals, Mekanism, Create...) ship more drivers in the same folder. A driver is a table:
  { id = "name", match = function(dev) -> adapter | nil }     dev = { name, types = {...}, per = <wrapped peripheral> }
  adapter = { caps = { "energy" }, read = { ["energy.stored"] = function(dev) return 5, "FE" end }, act = { ... } }
  optional  devices = function(env) -> { { name=, types=, adapter= } }  for devices that are not peripherals
All readings return value, unit (unit may be nil). Unknown readings return nil, "no such reading".

## `M.loadDrivers()`

Load every driver file from M.driverDir (idempotent per file: a driver with the same id is replaced).

## `M.scan(env)`

Look at everything attached. env (optional): peripheral, redstone, colors (tests). Returns an array of devices (sorted by
name); devices with no matching driver are left out unless env.all is set.

## `M.withCap(devices, cap)`

Devices with capability `cap` from a scan result.

## `M.get(name, env)`

Convenience: scan + lookup.

## `M.describe(dev)`

A short human description of a device: "name  [caps]  (driver)".
