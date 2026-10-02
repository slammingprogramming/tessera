-- SPDX-License-Identifier: AGPL-3.0-or-later
-- A deterministic network simulator for the tests of the IP stack: virtual time, Ethernet segments (hubs/cables) with latency and loss,
-- hosts that are real tsr.inet stacks, and cooperative "threads" so that a server and a client can both block in socket calls.
--
--   local sim = Sim.new()
--   local lan = sim:segment("lan")
--   local a, b = sim:host("a"), sim:host("b")
--   sim:plug(a, "eth0", lan, "10.0.0.1/24")
--   sim:plug(b, "eth0", lan, "10.0.0.2/24")
--   sim:spawn(function() ... server code using sockets on b ... end)
--   sim:run(5)                         -- advance five simulated seconds
--   sim:wait(cond, timeout)            -- advance until cond() or timeout (from the test's own thread)
local B = require("tsr.inet.bytes")
local Stack = require("tsr.inet.stack")

local Sim = {}
Sim.__index = Sim

function Sim.new(opts)
  opts = opts or {}
  local self = setmetatable({
    now = 0, step = opts.step or 0.01, queue = {}, stacks = {}, segments = {}, threads = {}, seed = opts.seed or 12345, macs = 0,
    log = {}, delivered = 0,
  }, Sim)
  return self
end

function Sim:rand(n)
  self.seed = (self.seed * 1103515245 + 12345) % 2147483648
  local r = math.floor(self.seed / 65536) % 32768
  if n then return r % n + 1 end
  return r / 32768
end

---------------------------------------------------------------------------------------------------------------------
-- Segments
---------------------------------------------------------------------------------------------------------------------

--- opts: latency (seconds, 0.01), loss (0..1), dup (0..1), jitter (seconds added at random).
function Sim:segment(name, opts)
  opts = opts or {}
  local seg = { name = name, ports = {}, latency = opts.latency or 0.01, loss = opts.loss or 0, dup = opts.dup or 0, jitter = opts.jitter or 0, sim = self, frames = 0 }
  self.segments[#self.segments + 1] = seg
  return seg
end

function Sim:transmit(seg, from, frame)
  seg.frames = seg.frames + 1
  for _, port in ipairs(seg.ports) do
    if port ~= from and not port.down and not from.down then
      if seg.drop and seg.drop(frame, from, port) then
        -- dropped by a test's own filter
      elseif seg.loss > 0 and self:rand() < seg.loss then
        self.dropped = (self.dropped or 0) + 1
      else
        local at = self.now + seg.latency + (seg.jitter > 0 and self:rand() * seg.jitter or 0)
        self.queue[#self.queue + 1] = { at = at, port = port, frame = frame, n = #self.queue }
        if seg.dup > 0 and self:rand() < seg.dup then
          self.queue[#self.queue + 1] = { at = at + 0.005, port = port, frame = frame, n = #self.queue }
        end
      end
    end
  end
end

--- A raw port on a segment: onFrame(frame) is called for every frame that arrives; returns the port with :send(frame).
function Sim:port(seg, onFrame)
  local port = { seg = seg, onFrame = onFrame, down = false }
  function port.send(frame) self:transmit(seg, port, frame) end
  seg.ports[#seg.ports + 1] = port
  return port
end

---------------------------------------------------------------------------------------------------------------------
-- Hosts
---------------------------------------------------------------------------------------------------------------------

function Sim:host(name, opts)
  opts = opts or {}
  local sim = self
  local stack
  stack = Stack.new({
    clock = function() return sim.now end, hostname = name, forwarding = opts.forwarding,
    random = function(n) return sim:rand(n) end,
    wait = function(cond, timeout) return sim:waitFor(cond, timeout) end,
  })
  stack.daemon = true
  stack.name = name
  self.stacks[#self.stacks + 1] = stack
  return stack
end

--- Connect interface `ifname` of `stack` to `seg`, optionally with an address "10.0.0.1/24". Returns the interface.
function Sim:plug(stack, ifname, seg, cidr, opts)
  opts = opts or {}
  self.macs = self.macs + 1
  local mac = opts.mac or B.makeMac(math.floor(self.macs / 256), self.macs % 256, 1)
  local iface
  local port = self:port(seg, function(frame) stack:input(iface, frame) end)
  iface = stack:addInterface({ name = ifname, mac = mac, mtu = opts.mtu or 1500, send = function(frame) port.send(frame) end })
  iface.port = port
  if cidr then
    local addr, plen = cidr:match("^([%d%.]+)/(%d+)$")
    stack:setAddress(ifname, addr, tonumber(plen))
  end
  return iface
end

---------------------------------------------------------------------------------------------------------------------
-- Time and threads
---------------------------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------------------------
-- Radio: modems that hear each other when they are in range and have the channel open (like CC wireless modems)
---------------------------------------------------------------------------------------------------------------------

--- opts: range (blocks, 64), latency (0.01), loss.
function Sim:air(opts)
  opts = opts or {}
  local sim = self
  local air = { modems = {}, range = opts.range or 64, latency = opts.latency or 0.01, loss = opts.loss or 0, sim = self, sent = 0 }
  --- A wireless modem for `stack` at position pos = { x, y, z }; its peripheral name is `name`.
  function air:modem(name, stack, pos)
    local m = { name = name, stack = stack, opened = {}, pos = pos or { 0, 0, 0 }, wireless = true }
    function m.isWireless() return true end
    function m.open(ch) m.opened[ch] = true end
    function m.close(ch) m.opened[ch] = nil end
    function m.isOpen(ch) return m.opened[ch] == true end
    function m.transmit(ch, reply, msg)
      air.sent = air.sent + 1
      for _, other in ipairs(air.modems) do
        if other ~= m and other.opened[ch] and not other.off and not m.off then
          local dx, dy, dz = m.pos[1] - other.pos[1], m.pos[2] - other.pos[2], m.pos[3] - other.pos[3]
          local d = math.sqrt(dx * dx + dy * dy + dz * dz)
          if d <= air.range and not (air.loss > 0 and sim:rand() < air.loss) then
            local ev = { "modem_message", other.name, ch, reply, msg, d }
            sim.queue[#sim.queue + 1] = { at = sim.now + air.latency, n = #sim.queue, fn = function() require("tsr.inet.link").dispatch(ev, other.stack) end }
          end
        end
      end
    end
    air.modems[#air.modems + 1] = m
    return m
  end
  return air
end

--- Run fn(...) as a cooperative thread: it may call blocking socket functions, which suspend it while the simulation advances.
function Sim:spawn(fn, ...)
  local co = coroutine.create(fn)
  local t = { co = co, args = table.pack(...), name = "thread" .. (#self.threads + 1) }
  self.threads[co] = t
  self.threadList = self.threadList or {}
  self.threadList[#self.threadList + 1] = t
  return t
end

local function resume(self, t)
  local ok, a = coroutine.resume(t.co, table.unpack(t.args or {}, 1, t.args and t.args.n or 0))
  t.args = nil
  if not ok then t.error = a t.done = true self.errors = self.errors or {} self.errors[#self.errors + 1] = t.name .. ": " .. tostring(a) return end
  if coroutine.status(t.co) == "dead" then t.done = true t.result = a return end
  t.waitCond, t.waitDeadline = a and a.cond, a and a.deadline
end

--- One simulation step: deliver due frames, tick every stack, resume threads whose condition holds.
function Sim:advance()
  self.now = self.now + self.step
  -- deliver due frames in time order
  if #self.queue > 0 then
    local due, rest = {}, {}
    for _, f in ipairs(self.queue) do
      if f.at <= self.now then due[#due + 1] = f else rest[#rest + 1] = f end
    end
    self.queue = rest
    table.sort(due, function(a, b) if a.at ~= b.at then return a.at < b.at end return a.n < b.n end)
    for _, f in ipairs(due) do
      self.delivered = self.delivered + 1
      if f.fn then f.fn() elseif not f.port.down then f.port.onFrame(f.frame) end
    end
  end
  for _, s in ipairs(self.stacks) do s:tick() end
  for _, hook in ipairs(self.hooks or {}) do hook(self) end
  if self.threadList then
    for _, t in ipairs(self.threadList) do
      if not t.done then
        if t.args then resume(self, t)           -- first run
        elseif t.waitCond == nil or t.waitCond() or (t.waitDeadline and self.now >= t.waitDeadline) then resume(self, t) end
      end
    end
  end
end

--- Advance `seconds` of simulated time.
function Sim:run(seconds)
  local stop = self.now + seconds
  while self.now < stop - 1e-9 do self:advance() end
end

--- Block (from the test's own thread, or from a spawned thread) until cond() holds or the timeout passes.
function Sim:waitFor(cond, timeout)
  local co = coroutine.running()
  local deadline = timeout and (self.now + timeout) or math.huge
  if self.threads[co] then
    while true do
      if cond() then return true end
      if self.now >= deadline then return cond() end
      coroutine.yield({ cond = cond, deadline = deadline })
    end
  end
  local guard = 0
  while not cond() and self.now < deadline do
    self:advance()
    guard = guard + 1
    if guard > 5000000 then error("simulation did not finish", 0) end
  end
  return cond()
end

Sim.wait = Sim.waitFor

--- Run until every spawned thread has finished (or `limit` simulated seconds pass). Raises the first thread error.
function Sim:finish(limit)
  local stop = self.now + (limit or 60)
  while self.now < stop do
    local pending = false
    for _, t in ipairs(self.threadList or {}) do if not t.done and not t.daemon then pending = true end end
    if not pending then break end
    self:advance()
  end
  if self.errors then error(self.errors[1], 0) end
  for _, t in ipairs(self.threadList or {}) do if not t.done and not t.daemon then error(t.name .. " did not finish in " .. (limit or 60) .. " simulated seconds", 0) end end
end

return Sim
