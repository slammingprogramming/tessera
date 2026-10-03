# Devices, smart homes and industrial control

Minecraft bases are full of things that have no network: a lamp, a door, a furnace bank, a tank gauge, a reactor. Tessera connects them with the
protocols that real homes and factories use, adapted to the game. All of it runs on the in-game internet ([NETWORKING.md](NETWORKING.md)); the hardware
side (what a "device" is, redstone as the universal fallback, mod integrations) is the `hal` package.

> Status: built and tested in CraftOS-PC with simulated devices and a simulated network. Not run in real Minecraft yet.

| You want to | Use | Package |
|---|---|---|
| Let sensors, switches and displays exchange messages | an **MQTT** broker and clients | `mqtt` |
| Let a control room read and switch machines | a **Modbus/TCP** slave | `modbus` |
| Give lamps and doors names, rooms, scenes and a schedule | the **smart-home hub** | `smarthome` |
| Show a page on a screen for ever | `www --board` and the `tv` kiosk | `web`, `tv` |
| Make a computer do one of these from the first boot | the installer's use cases | `installer` |

## Devices (the base layer)

`hal` turns every attached peripheral and every redstone-only machine into a **device** with named readings (`machine.running`, `fluid.percent`, `sensor.value`) and
actions (`machine.start`, `redstone.set`). Declare something that has no ComputerCraft interface in `/etc/tsr/hal.devices` (or `hal virtual add ...`):

```lua
["smelter"]    = { kind = "switch", port = "back:red", label = "furnace bank" }
["tank-gauge"] = { kind = "sensor", port = "left", scale = 100 / 15, unit = "%", label = "tank fill (comparator)" }
```

Everything below talks to devices through this layer, so it works the same for a redstone lamp, a Create machine or a Mekanism tank.

## MQTT: messages for things

MQTT 3.1.1 is the standard way small devices report and are told what to do. A device **publishes** a message to a topic (`home/kitchen/light/state`);
everyone who **subscribed** to a matching filter (`home/+/light/state`, `home/#`) gets it. The broker also keeps the last value of a topic (**retained**), announces a device that vanished
(**will**), and can queue messages for a device that is offline (**persistent session**).

```
mqttctl init                                # writes /etc/tsr/mqtt/mqtt.lua
mqttctl user add thermostat                 # asks for a password
svc enable mqttd && svc start mqttd
mqtt pub 10.0.0.5 home/hall/temp 21.5 -r -u thermostat -P secret      # publish, retained
mqtt sub 10.0.0.5 'home/#' -u panel -P secret                         # print what arrives
```

* QoS 0 and 1 (QoS 2 is not supported and a client asking for it is disconnected).
* Accounts with salted passwords, **access lists** per user (`acl = { sensor = { pub = { "home/+/+/state" }, sub = {} } }`), a limit on devices and subscriptions.
* In a program: `local c = require("tsr.mqtt").connect(stack, host, { username = ..., password = ... })`, then `c:subscribe(filter)`, `c:publish(topic, payload, { retain = true })`, `c:receive(timeout)`.

## Modbus/TCP: a PLC for the plant

Modbus is the old, simple protocol of industrial control. A master reads and writes numbered **coils** (on/off outputs), **discrete inputs** (on/off sensors), **holding registers** (numbers
it may set) and **input registers** (measurements) of a slave. The `modbus` package makes a computer a slave whose map says what each address means:

```lua
-- /etc/tsr/modbus.lua   (modbusctl init writes an example)
return { port = 502, allow = { "10.0.0.0/24" }, readonly = false, units = { [1] = {
  coils     = { [0] = { rs = "back:red" }, [1] = { dev = "smelter", read = "machine.running", on = "machine.start", off = "machine.stop" } },
  inputs    = { [0] = { rs = "left" } },
  registers = { [0] = { dev = "tank-gauge", read = "sensor.value", scale = 100 } },       -- 12.5 % is read as 1250
  holding   = { [0] = { var = "setpoint", init = 50 }, [1] = { rs = "right", analog = true } },
} } }
```

From the control room: `modbus read 10.0.0.7 coils 0 8`, `modbus write 10.0.0.7 coil 1 on`, `modbus poll 10.0.0.7 registers 0 4 -n 20 -i 2`. Function codes 1–6, 15 and 16, the standard
exceptions (illegal address, illegal value, device failure) and the 2000/125-point limits are implemented.

**Modbus has no security.** The slave therefore refuses clients that are not in `allow`, and `readonly = true` refuses every write. Put it behind the firewall use case, and let only the control room
reach it. Automatic control (switch the pump when the tank is low) is the `rules` package; supervising reactors is `scada`; dashboards are `power-monitor` and `display`.

## The smart-home hub

`home` gives devices friendly names, rooms and kinds, scenes and a schedule. Settings in `/etc/tsr/home.lua` (`home init` writes an example):

```lua
return {
  devices = {
    ["kitchen-light"] = { room = "kitchen", kind = "light", dev = "lamp1" },
    ["front-door"]    = { room = "hall", kind = "door", dev = "doorrelay", on = { "redstone.set", "top", 15 }, off = { "redstone.set", "top", 0 } },
    ["cellar-tank"]   = { room = "cellar", kind = "sensor", dev = "gauge", read = "sensor.value", unit = "%" },
  },
  scenes   = { night = { ["kitchen-light"] = "off", ["front-door"] = "closed" } },
  schedule = { { at = "22:30", scene = "night" }, { at = "07:00", scene = "morning", days = "mon,tue,wed,thu,fri" } },
  mqtt     = { host = "10.0.0.5", username = "home", password = "secret", prefix = "home" },
}
```

```
home                      # every device with its room and state
home on kitchen-light     # also: off, open, close, lock, unlock, toggle
home scene night
```

Kinds: `light`, `switch`, `outlet` (on/off), `door`, `gate`, `trapdoor` (open/closed), `lock` (unlocked/locked), `sensor` (a value). The schedule uses the **Minecraft clock** by default
(`clock = "local"` for the real one). With `mqtt` set, the `homed` service publishes `home/<room>/<device>/state` (retained) whenever something changes and obeys
`home/<room>/<device>/set` and `home/scene/<name>/set`, so a wall panel (another computer running `mqtt`) or a phone-style pocket computer can control the house.

## Kiosks and information boards

`www --board http://info.lan/ --monitor monitor_0 --every 30` shows a page from the in-game web on a monitor, reloads it and turns the pages of a long one. Make it permanent with
`kiosk set www --board ...`: it restarts after a crash and Ctrl+T does not stop it. To get out, stop the service from another computer (`svc stop kioskd`). Serve the page yourself with
the web server use case (pages in `/srv/www`, even Lua routes that print live values).

## Honest limits

* Real-world devices (a physical thermostat) cannot connect; this is a game system.
* MQTT and Modbus here are the real wire formats, so tools written for the game can be ported, but there is no TLS inside MQTT yet (use the network's own protection) and no QoS 2.
* The hub polls device states every couple of seconds; fast events should use `rules` or redstone directly.
* Tested in simulation only.
