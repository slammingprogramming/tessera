-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Fake peripherals and APIs shared by app tests. Usage: local F = dofile("/tests/lib/fakes.lua")
local F = {}

--- A fake redstone API (also usable as a redstone_relay peripheral). Records every output change in `.log`.
function F.redstone()
  local rs = { out = {}, bundled = {}, inp = {}, binp = {}, log = {} }
  local function rec(side, what, value) rs.log[#rs.log + 1] = side .. ":" .. what .. "=" .. tostring(value) end
  function rs.setAnalogOutput(side, v) rs.out[side] = v rec(side, "analog", v) end
  function rs.getAnalogOutput(side) return rs.out[side] or 0 end
  function rs.setOutput(side, on) rs.out[side] = on and 15 or 0 rec(side, "out", on) end
  function rs.getOutput(side) return (rs.out[side] or 0) > 0 end
  function rs.getAnalogInput(side) return rs.inp[side] or 0 end
  function rs.getInput(side) return (rs.inp[side] or 0) > 0 end
  function rs.setBundledOutput(side, mask) rs.bundled[side] = mask rec(side, "bundled", mask) end
  function rs.getBundledOutput(side) return rs.bundled[side] or 0 end
  function rs.testBundledInput(side, mask) return bit32.band(rs.binp[side] or 0, mask) == mask end
  return rs
end

--- A fake `peripheral` API over a table name -> object (objects may carry ._type).
function F.peripheralApi(devices)
  local api = {}
  function api.getNames() local out = {} for n in pairs(devices) do out[#out + 1] = n end table.sort(out) return out end
  function api.wrap(name) return devices[name] end
  function api.getType(name) return devices[name] and devices[name]._type end
  function api.find(kind)
    local found = {}
    for _, name in ipairs(api.getNames()) do
      if devices[name]._type == kind then found[#found + 1] = devices[name] end
    end
    return table.unpack(found)
  end
  function api.getMethods(name) local m = {} for k, v in pairs(devices[name] or {}) do if type(v) == "function" then m[#m + 1] = k end end return m end
  function api.call(name, method, ...) return devices[name][method](...) end
  return api
end

--- A fake clock + sleep: sleep() advances `.now` instead of waiting, and records durations.
function F.clock()
  local c = { now = 0, sleeps = {} }
  function c.sleep(s) c.now = c.now + s c.sleeps[#c.sleeps + 1] = s end
  return c
end

--- Recording io for apps: said/warned/errs arrays, scripted prompt answers, yes/no answers.
function F.io(inputs, answers)
  local io = { said = {}, warned = {}, errs = {}, queue = inputs or {}, answers = answers or {} }
  function io.say(t) io.said[#io.said + 1] = t end
  function io.warn(t) io.warned[#io.warned + 1] = t end
  function io.err(t) io.errs[#io.errs + 1] = t end
  function io.prompt(_, d) if #io.queue > 0 then return table.remove(io.queue, 1) end return d end
  function io.secret(_) if #io.queue > 0 then return table.remove(io.queue, 1) end end
  function io.ask(_, d) if #io.answers > 0 then return table.remove(io.answers, 1) end return d ~= false end
  function io.waitInventory() end
  return io
end

return F
