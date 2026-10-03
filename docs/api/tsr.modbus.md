# tsr.modbus

Package: `modbus`

Modbus/TCP: the plain, old protocol of industrial control. A master (a control room computer) reads and writes numbered coils (on/off outputs), discrete inputs
(on/off sensors), holding registers (16-bit values it may set) and input registers (16-bit measurements) of slave devices ("units").
This file: the message format (MBAP header + PDU) and a client. tsr.modbus.server makes a computer a slave that exposes redstone and machines.
  local c = modbus.connect(stack, "10.0.0.7", { unit = 1 })
  c:readCoils(0, 8)  c:readInputRegisters(0, 2)  c:writeCoil(3, true)  c:writeRegister(0, 1500)   -- each returns a value / table, or nil + reason

## `M.frame(tid, unit, pdu)`

A TCP frame: transaction id, unit, PDU (function code + data).

## `M.readFrame(sock, timeout)`

Read one frame from a socket. Returns tid, unit, pdu — or nil + reason.

## `M.connect(stack, host, opts)`

Connect. opts: port (502), unit (1), timeout.

## `Client:request(pdu)`

Send a request PDU and return the answer PDU (or nil + reason; a Modbus exception becomes an error text).
