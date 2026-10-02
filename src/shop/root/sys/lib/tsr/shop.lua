-- SPDX-License-Identifier: AGPL-3.0-or-later
-- A vending shop built from chests.
--   input   a chest next to the computer where customers drop the currency item (it stays there as their balance)
--   till    where payments go (your income)       output   where purchased goods appear (the customer takes them)
--   stock   one or more chests holding the goods
--   monitor optional: lists the goods; tap one to buy it. Without a monitor the terminal is used (keys 1-9, R = refund).
-- Configuration /etc/tsr/shop.cfg (edit with the `shop` command):
--   { name = "Spawn Shop", currency = "minecraft:diamond", input = "chest_0", till = "chest_1", output = "chest_2",
--     stock = { "chest_3", "chest_4" }, monitor = "monitor_0",
--     items = { { id = "minecraft:iron_ingot", label = "Iron x8", price = 1, per = 8 } } }
-- Every price is in whole currency items; `per` is how many goods one purchase gives.
local vfs = require("tsr.vfs")

local M = {}

M.CFG_PATH = "/etc/tsr/shop.cfg"
M.LOG_PATH = "/var/log/shop.log"

function M.loadConfig() return vfs.readTable(M.CFG_PATH) or { items = {}, stock = {} } end
function M.saveConfig(cfg) return vfs.writeTable(M.CFG_PATH, cfg) end

local Shop = {}
Shop.__index = Shop

--- env (all optional, for tests): peripheral, clock (function -> text), logPath
function M.new(cfg, env)
  env = env or {}
  cfg.items = cfg.items or {}
  cfg.stock = cfg.stock or {}
  return setmetatable({ cfg = cfg, per = env.peripheral or peripheral, logPath = env.logPath or M.LOG_PATH,
                        stamp = env.clock or function() return textutils.formatTime(os.time("local"), true) end,
                        sold = 0, income = 0, message = "" }, Shop)
end

local function wrap(self, name)
  local p = name and self.per.wrap(name)
  return p
end

--- Check that every configured chest exists. Returns true or nil + list of problems.
function Shop:check()
  local problems = {}
  for _, role in ipairs({ "input", "till", "output" }) do
    if not self.cfg[role] then problems[#problems + 1] = "no " .. role .. " chest set"
    elseif not wrap(self, self.cfg[role]) then problems[#problems + 1] = role .. " chest '" .. self.cfg[role] .. "' not found" end
  end
  if not self.cfg.currency then problems[#problems + 1] = "no currency item set" end
  if #self.cfg.stock == 0 then problems[#problems + 1] = "no stock chests" end
  for _, name in ipairs(self.cfg.stock) do
    if not wrap(self, name) then problems[#problems + 1] = "stock chest '" .. name .. "' not found" end
  end
  if #problems > 0 then return nil, problems end
  return true
end

local function countIn(chest, id)
  local n = 0
  for _, stack in pairs(chest.list()) do
    if stack.name == id then n = n + stack.count end
  end
  return n
end

--- How much currency the customer has put in.
function Shop:balance()
  local input = wrap(self, self.cfg.input)
  return input and countIn(input, self.cfg.currency) or 0
end

--- How many of `id` the stock chests hold.
function Shop:stock(id)
  local n = 0
  for _, name in ipairs(self.cfg.stock) do
    local c = wrap(self, name)
    if c then n = n + countIn(c, id) end
  end
  return n
end

--- Move up to `count` of `id` from chest `fromName` (in slot order) into `toName`. Returns how many moved.
local function transfer(self, fromName, toName, id, count)
  local from = wrap(self, fromName)
  if not from then return 0 end
  local moved = 0
  for slot, stack in pairs(from.list()) do
    if moved >= count then break end
    if stack.name == id then
      moved = moved + (from.pushItems(toName, slot, count - moved) or 0)
    end
  end
  return moved
end

local function log(self, text)
  local old = vfs.readFile(self.logPath) or ""
  local new = old .. self.stamp() .. " " .. text .. "\n"
  if #new > 20000 then new = new:sub(-20000) end
  vfs.writeFile(self.logPath, new)
end

--- Sell `qty` purchases of item number `index`. Returns true + message, or false + reason (nothing is lost in either case).
function Shop:buy(index, qty)
  qty = math.max(1, math.floor(tonumber(qty) or 1))
  local item = self.cfg.items[index]
  if not item then return false, "no such item" end
  local per = item.per or 1
  local price = (item.price or 1) * qty
  local want = per * qty
  if self:balance() < price then return false, ("need %d %s, you have %d"):format(price, self.cfg.currency:gsub("^.-:", ""), self:balance()) end
  if self:stock(item.id) < want then return false, "out of stock" end
  -- take the payment first, then hand over the goods; if the goods cannot be delivered the payment goes back
  local paid = transfer(self, self.cfg.input, self.cfg.till, self.cfg.currency, price)
  if paid < price then
    transfer(self, self.cfg.till, self.cfg.input, self.cfg.currency, paid)       -- undo the part that moved
    return false, "payment failed"
  end
  local given = 0
  for _, name in ipairs(self.cfg.stock) do
    if given >= want then break end
    given = given + transfer(self, name, self.cfg.output, item.id, want - given)
  end
  if given < want then
    -- the output chest was full or stock changed under us: refund proportionally
    local refund = price - math.floor(price * given / want)
    transfer(self, self.cfg.till, self.cfg.input, self.cfg.currency, refund)
    log(self, ("PARTIAL %s: gave %d of %d, refunded %d"):format(item.id, given, want, refund))
    return false, ("could only deliver %d of %d; %d refunded"):format(given, want, refund)
  end
  self.sold = self.sold + qty
  self.income = self.income + price
  log(self, ("SOLD %dx %s (%d items) for %d"):format(qty, item.id, want, price))
  return true, ("Bought %d x %s"):format(want, item.label or item.id)
end

--- Give the remaining balance back through the output chest. Returns the amount returned.
function Shop:refund()
  local n = transfer(self, self.cfg.input, self.cfg.output, self.cfg.currency, self:balance())
  if n > 0 then log(self, "REFUND " .. n) end
  return n
end

---------------------------------------------------------------------------------------------------------------------
-- Display
---------------------------------------------------------------------------------------------------------------------

--- Draw on terminal `t`. Returns the screen rows of each item: { [row] = itemIndex } and the refund row.
function Shop:draw(t)
  local w, h = t.getSize()
  t.setBackgroundColor(colors.black)
  t.clear()
  t.setTextColor(colors.yellow)
  t.setCursorPos(1, 1)
  t.write((self.cfg.name or "Shop"):sub(1, w))
  t.setTextColor(colors.white)
  t.setCursorPos(1, 2)
  t.write(("Balance: %d %s"):format(self:balance(), (self.cfg.currency or "?"):gsub("^.-:", "")):sub(1, w))
  local rows = {}
  local row = 4
  for i, item in ipairs(self.cfg.items) do
    if row >= h - 1 then break end
    local inStock = self:stock(item.id)
    local can = inStock >= (item.per or 1)
    t.setCursorPos(1, row)
    t.setTextColor(can and colors.white or colors.gray)
    local line = ("%d. %-14s %3d  (%d left)"):format(i, (item.label or item.id):sub(1, 14), item.price or 1, inStock)
    t.write(line:sub(1, w))
    rows[row] = i
    row = row + 1
  end
  t.setCursorPos(1, h - 1)
  t.setTextColor(colors.lightGray)
  t.write(self.message:sub(1, w))
  t.setCursorPos(1, h)
  t.setTextColor(colors.red)
  t.write("[ Refund ]")
  t.setTextColor(colors.white)
  return rows, h
end

--- The shop loop. env: term (default current or the configured monitor), maxEvents (tests).
function M.run(cfg, env)
  env = env or {}
  local shop = M.new(cfg, env)
  local per = env.peripheral or peripheral
  local ok, problems = shop:check()
  if not ok then return nil, problems end
  local t = env.term or (cfg.monitor and per.wrap(cfg.monitor)) or term.current()
  local count = 0
  local rows, refundRow
  local function redraw() rows, refundRow = shop:draw(t) end
  redraw()
  local timer = os.startTimer(2)
  while true do
    local ev = table.pack(os.pullEvent())
    local name = ev[1]
    local choice, wantRefund
    if name == "monitor_touch" and cfg.monitor and ev[2] == cfg.monitor then
      if ev[4] == refundRow then wantRefund = true else choice = rows[ev[4]] end
    elseif name == "mouse_click" and t == term.current() then
      if ev[4] == refundRow then wantRefund = true else choice = rows[ev[4]] end
    elseif name == "char" then
      if ev[2]:lower() == "r" then wantRefund = true elseif tonumber(ev[2]) then choice = tonumber(ev[2]) end
    elseif name == "timer" and ev[2] == timer then
      timer = os.startTimer(2)
      redraw()
    elseif name == "terminate" then
      break
    end
    if choice then
      local good, msg = shop:buy(choice, 1)
      shop.message = msg
      redraw()
      count = count + 1
    elseif wantRefund then
      local n = shop:refund()
      shop.message = n > 0 and ("Refunded " .. n) or "Nothing to refund"
      redraw()
      count = count + 1
    end
    if env.maxEvents and count >= env.maxEvents then break end
  end
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- Command
---------------------------------------------------------------------------------------------------------------------

local function defaultIO()
  local io = {}
  function io.say(t) print(t) end
  function io.err(t) if term.isColor() then term.setTextColor(colors.red) end print(t) term.setTextColor(colors.white) end
  return io
end

--- shop status | set <input|till|output|currency|monitor|name> <value> | stock add|remove <chest> |
---      add <item id> <price> [per] [label] | remove <n> | run
function M.cli(args, io, env)
  io = io or defaultIO()
  local cfg = M.loadConfig()
  local cmd = args[1] or "status"
  if cmd == "status" then
    local shop = M.new(cfg, env)
    local ok, problems = shop:check()
    io.say(("%s - currency %s"):format(cfg.name or "Shop", tostring(cfg.currency)))
    io.say(("input %s  till %s  output %s  monitor %s"):format(tostring(cfg.input), tostring(cfg.till), tostring(cfg.output), tostring(cfg.monitor)))
    io.say("stock chests: " .. (#cfg.stock > 0 and table.concat(cfg.stock, ", ") or "none"))
    for i, it in ipairs(cfg.items) do io.say(("%d. %s  %d for %dx %s"):format(i, it.label or it.id, it.price or 1, it.per or 1, it.id)) end
    if not ok then for _, p in ipairs(problems) do io.err("problem: " .. p) end end
    return ok == true
  elseif cmd == "set" then
    local key, value = args[2], args[3]
    local allowed = { input = true, till = true, output = true, currency = true, monitor = true, name = true }
    if not allowed[key or ""] or not value then io.err("usage: shop set input|till|output|currency|monitor|name <value>") return false end
    cfg[key] = key == "name" and table.concat(args, " ", 3) or value
    M.saveConfig(cfg)
    io.say(key .. " = " .. cfg[key])
    return true
  elseif cmd == "stock" then
    local verb, chest = args[2], args[3]
    if (verb ~= "add" and verb ~= "remove") or not chest then io.err("usage: shop stock add|remove <chest>") return false end
    local kept = {}
    for _, c in ipairs(cfg.stock) do if c ~= chest then kept[#kept + 1] = c end end
    if verb == "add" then kept[#kept + 1] = chest end
    cfg.stock = kept
    M.saveConfig(cfg)
    io.say("Stock chests: " .. (#kept > 0 and table.concat(kept, ", ") or "none"))
    return true
  elseif cmd == "add" then
    local id, price = args[2], tonumber(args[3])
    if not id or not price or price < 1 then io.err("usage: shop add <item id> <price> [per] [label]") return false end
    local per = tonumber(args[4]) or 1
    local label = args[5] and table.concat(args, " ", 5) or (id:gsub("^.-:", "") .. (per > 1 and (" x" .. per) or ""))
    cfg.items[#cfg.items + 1] = { id = id, price = math.floor(price), per = math.max(1, math.floor(per)), label = label }
    M.saveConfig(cfg)
    io.say("Added: " .. label)
    return true
  elseif cmd == "remove" then
    local n = tonumber(args[2])
    if not n or not cfg.items[n] then io.err("usage: shop remove <item number>") return false end
    table.remove(cfg.items, n)
    M.saveConfig(cfg)
    io.say("Removed.")
    return true
  elseif cmd == "run" then
    local ok, problems = M.run(cfg, env)
    if not ok then for _, p in ipairs(problems) do io.err("problem: " .. p) end return false end
    return true
  end
  io.err("usage: shop status | set | stock | add | remove | run")
  return false
end

function M.main(args) return M.cli(args) end

--- The shopd service.
function M.daemon()
  local cfg = M.loadConfig()
  local ok, problems = M.run(cfg, {})
  if not ok then error("shop is not set up: " .. table.concat(problems or {}, "; "), 0) end
end

return M
