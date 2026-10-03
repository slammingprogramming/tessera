# tsr.modbus.server

Package: `modbus`

A Modbus/TCP slave: makes the redstone ports and machines of this computer readable and settable by numbers, so that a control room (or a SCADA display) can
supervise a plant. The map says which address means what:
  units = { [1] = {
    coils     = { [0] = { rs = "back:red" },                       -- an output you can switch                (functions 1, 5, 15)
                  [1] = { dev = "smelter", read = "machine.running", on = "machine.start", off = "machine.stop" } },
    inputs    = { [0] = { rs = "left" } },                          -- an on/off sensor                        (function 2)
    registers = { [0] = { dev = "tank", read = "fluid.percent", scale = 100 } },   -- a measurement 0..65535    (function 4)
    holding   = { [0] = { var = "setpoint", init = 50 },            -- a value stored here, or an analog output (functions 3, 6, 16)
                  [1] = { rs = "right", analog = true } },
  } }
A point is { rs = port } (redstone), { dev = name, read = reading, on/off/act = action, scale = factor } (a HAL device), { var = name, init = value } (a stored value),
{ const = value } (read only) or { read = function() ... end, write = function(value) ... end } (your own code).
Safety: allow = { "10.0.0.0/24" } lets only those networks in; readonly = true refuses every write.

## `M.new(cfg, env)`

cfg: units, readonly, allow, maxConnections, onWrite(unit, table, address, value). env (optional): rsio, rsEnv, devices.

## `Server:permits(ip)`

May this client address talk to us?

## `Server:request(unitId, pdu)`

Handle one request PDU for a unit. Returns the answer PDU.

## `Server:serve(conn)`

Serve one TCP connection until it ends.
