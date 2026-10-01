-- SPDX-License-Identifier: AGPL-3.0-or-later
-- An in-memory network for tests: transports for several nodes inside one Lua VM, delivered through os events.
-- bus:transport(id) -> transport; bus.log lists every message that crossed the wire (with from/to);
-- bus.filter(from, to, msg) may return false to drop a message or a replacement table to tamper with it.
local B = {}

local function copy(msg) return textutils.unserialize(textutils.serialize(msg)) end

function B.new()
  local bus = { ids = {}, log = {} }

  local function deliver(from, to, msg)
    local m = copy(msg)
    if bus.filter then
      local r = bus.filter(from, to, m)
      if r == false then return end
      if type(r) == "table" then m = r end
    end
    bus.log[#bus.log + 1] = { from = from, to = to, msg = copy(m) }
    os.queueEvent("netbus", to, from, m)
  end
  bus.deliver = deliver

  function bus:transport(id)
    self.ids[id] = true
    local t = {}
    function t.send(to, msg) deliver(id, to, msg) end
    function t.broadcast(msg)
      for other in pairs(bus.ids) do
        if other ~= id then deliver(id, other, msg) end
      end
    end
    function t.receive(timeout)
      local timer = timeout and os.startTimer(timeout)
      while true do
        local ev, a, b, c = os.pullEvent()
        if ev == "netbus" and a == id then
          if timer then os.cancelTimer(timer) end
          return b, c
        elseif ev == "timer" and a == timer then
          return nil
        end
      end
    end
    return t
  end

  return bus
end

return B
