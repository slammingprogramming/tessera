-- SPDX-License-Identifier: AGPL-3.0-or-later
-- tstatus: where the turtle thinks it is, its fuel, inventory and the job it is working on.
local req = (rawget(_G, "tsr") and tsr.require) or dofile("/sys/lib/tsr/loader.lua").require
if not turtle then return printError("tstatus only runs on a turtle.") end
local T = req("tsr.turtle")
local x, y, z, dir = T.pos()
print(("Position: %d, %d, %d facing %s"):format(x, y, z, T.NAMES[dir]))
local fuel, limit = turtle.getFuelLevel(), turtle.getFuelLimit()
print(("Fuel: %s / %s"):format(tostring(fuel), tostring(limit)))
local used = 16 - T.emptySlots()
print(("Inventory: %d of 16 slots used"):format(used))
for slot = 1, 16 do
  local d = turtle.getItemDetail(slot)
  if d then print(("  %2d  %3d x %s"):format(slot, d.count, d.name)) end
end
local j = T.job.get()
if j then
  print(("Job: %s (%s)"):format(j.name, textutils.serialize(j.params, { compact = true })))
  print(("  step %s, restart with: %s"):format(tostring(j.progress and j.progress.idx or 0), table.concat(j.cmd or {}, " ")))
  print("  run `tresume` to continue it, `tresume --cancel` to forget it")
else
  print("Job: none")
end
local st = T.state()
if st.recovered then print(("Recovered from %d interrupted move(s) since the state was created."):format(st.recovered)) end
