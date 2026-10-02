-- SPDX-License-Identifier: AGPL-3.0-or-later
local F = dofile("/tests/lib/fakes.lua")
local shop = require("tsr.shop")

local DIR = "/tmp-shop"
local function slurp(path)
  local h = fs.open(path, "r")
  local text = h.readAll()
  h.close()
  return text
end

local COIN = "minecraft:diamond"
local IRON = "minecraft:iron_ingot"

--- A shop over fake chests. Returns shop, chests, per.
local function world(opts)
  opts = opts or {}
  if fs.exists(DIR) then fs.delete(DIR) end
  fs.makeDir(DIR)
  shop.CFG_PATH = DIR .. "/shop.cfg"
  local chests = F.inventories({ inbox = 9, till = 9, outbox = opts.outSize or 9, stock1 = 9, stock2 = 9 })
  chests.stock1.put(IRON, opts.iron1 or 64)
  chests.stock2.put(IRON, opts.iron2 or 0)
  chests.stock1.put("minecraft:coal", 10)
  local per = F.peripheralApi(chests)
  local cfg = {
    name = "Test Shop", currency = COIN, input = "inbox", till = "till", output = "outbox", stock = { "stock1", "stock2" },
    items = { { id = IRON, label = "Iron x8", price = 2, per = 8 }, { id = "minecraft:coal", label = "Coal", price = 1, per = 1 } },
  }
  local s = shop.new(cfg, { peripheral = per, logPath = DIR .. "/shop.log", clock = function() return "12:00" end })
  return s, chests, per, cfg
end

test("balance and stock are counted across chests", function()
  local s, chests = world({ iron1 = 30, iron2 = 20 })
  eq(s:balance(), 0)
  chests.inbox.put(COIN, 5)
  chests.inbox.put("minecraft:dirt", 100)
  eq(s:balance(), 5)
  eq(s:stock(IRON), 50)
  eq(s:stock("minecraft:coal"), 10)
  eq(s:stock("minecraft:gold"), 0)
end)

test("a purchase moves payment to the till and goods to the output", function()
  local s, chests = world()
  chests.inbox.put(COIN, 5)
  local ok1, msg = s:buy(1, 1)
  ok(ok1, msg)
  eq(msg, "Bought 8 x Iron x8")
  eq(chests.inbox.total(COIN), 3)
  eq(chests.till.total(COIN), 2)
  eq(chests.outbox.total(IRON), 8)
  eq(chests.stock1.total(IRON), 56)
  eq(s.sold, 1)
  eq(s.income, 2)
  local log = slurp(DIR .. "/shop.log")
  ok(log:find("SOLD 1x " .. IRON, 1, true), log)
  -- quantity
  ok(s:buy(1, 1))
  eq(chests.outbox.total(IRON), 16)
  eq(chests.till.total(COIN), 4)
end)

test("goods come from several stock chests", function()
  local s, chests = world({ iron1 = 5, iron2 = 10 })
  chests.inbox.put(COIN, 2)
  ok(s:buy(1, 1))
  eq(chests.outbox.total(IRON), 8)
  eq(chests.stock1.total(IRON) + chests.stock2.total(IRON), 7)
end)

test("not enough money or stock changes nothing", function()
  local s, chests = world({ iron1 = 4 })
  chests.inbox.put(COIN, 1)
  local ok1, why = s:buy(1, 1)
  ok(ok1 == false and why:find("need 2"), why)
  chests.inbox.put(COIN, 5)
  ok1, why = s:buy(1, 1)
  ok(ok1 == false and why == "out of stock", why)
  eq(chests.inbox.total(COIN), 6)
  eq(chests.till.total(COIN), 0)
  eq(chests.outbox.total(IRON), 0)
  local bad, w2 = s:buy(9, 1)
  ok(bad == false and w2 == "no such item")
  -- quantities are sanitised
  ok(s:buy(2, -5))
  eq(chests.outbox.total("minecraft:coal"), 1)
  ok(s:buy(2, "2"))
  eq(chests.outbox.total("minecraft:coal"), 3)
end)

test("a full output chest refunds what could not be delivered", function()
  local s, chests = world({ outSize = 1 })
  chests.outbox.put("minecraft:dirt", 64)       -- the only slot is taken
  chests.inbox.put(COIN, 4)
  local ok1, why = s:buy(1, 1)
  ok(ok1 == false and why:find("2 refunded", 1, true) == nil or why:find("refunded", 1, true), why)
  eq(chests.inbox.total(COIN) + chests.till.total(COIN) + chests.outbox.total(COIN), 4, "no currency is lost")
  eq(chests.till.total(COIN), 0, "the whole price is refunded when nothing was delivered")
  local log = slurp(DIR .. "/shop.log")
  ok(log:find("PARTIAL", 1, true))
end)

test("refund returns the balance", function()
  local s, chests = world()
  chests.inbox.put(COIN, 7)
  eq(s:refund(), 7)
  eq(chests.outbox.total(COIN), 7)
  eq(s:balance(), 0)
  eq(s:refund(), 0)
end)

test("configuration problems are listed", function()
  local s, _, _, cfg = world()
  ok(s:check())
  cfg.till = "ghost"
  cfg.stock = {}
  cfg.currency = nil
  local good, problems = s:check()
  ok(good == nil)
  local text = table.concat(problems, "; ")
  ok(text:find("till chest 'ghost' not found", 1, true) and text:find("no stock chests", 1, true) and text:find("no currency", 1, true), text)
end)

test("the shop screen lists items, prices and stock", function()
  local s, chests = world()
  chests.inbox.put(COIN, 3)
  local mon = F.monitor(40, 10)
  local rows, bottom = s:draw(mon)
  local t = mon.text()
  ok(t:find("Test Shop", 1, true) and t:find("Balance: 3 diamond", 1, true), t)
  ok(t:find("1. Iron x8", 1, true) and t:find("(64 left)", 1, true), t)
  ok(t:find("[ Refund ]", 1, true))
  eq(rows[4], 1)
  eq(rows[5], 2)
  eq(bottom, 10)
end)

test("the run loop sells on key presses and monitor taps", function()
  local s, chests, per, cfg = world()
  cfg.monitor = "screen"
  local mon = F.monitor(40, 10)
  mon._type = "monitor"
  per = F.peripheralApi({ inbox = chests.inbox, till = chests.till, outbox = chests.outbox, stock1 = chests.stock1, stock2 = chests.stock2, screen = mon })
  chests.inbox.put(COIN, 10)
  parallel.waitForAll(
    function()
      local ok1 = shop.run(cfg, { peripheral = per, maxEvents = 3, logPath = DIR .. "/shop.log", clock = function() return "t" end })
      ok(ok1)
    end,
    function()
      sleep(0.1)
      os.queueEvent("char", "1")                           -- buy item 1 by key
      os.queueEvent("monitor_touch", "screen", 5, 5)       -- tap item 2 (row 5)
      os.queueEvent("monitor_touch", "screen", 3, 10)      -- tap [ Refund ]
      os.queueEvent("char", "x")
    end)
  eq(chests.outbox.total(IRON), 8)
  eq(chests.outbox.total("minecraft:coal"), 1)
  eq(chests.outbox.total(COIN), 10 - 2 - 1, "refund returns what is left")
  ok(mon.text():find("Refunded", 1, true), mon.text())
end)

test("the run loop refuses to start with a broken setup", function()
  local s, chests, per, cfg = world()
  cfg.till = "ghost"
  local ok1, problems = shop.run(cfg, { peripheral = per })
  ok(ok1 == nil and problems[1]:find("till chest"))
end)

test("the shop command configures everything", function()
  local s, chests, per = world()
  local function run(...)
    local io = { said = {}, errs = {} }
    function io.say(t) io.said[#io.said + 1] = t end
    function io.err(t) io.errs[#io.errs + 1] = t end
    local r = shop.cli({ ... }, io, { peripheral = per })
    return r, table.concat(io.said, "\n"), table.concat(io.errs, "\n")
  end
  ok(run("set", "name", "My", "Little", "Shop"))
  ok(run("set", "currency", COIN))
  ok(run("set", "input", "inbox"))
  ok(run("set", "till", "till"))
  ok(run("set", "output", "outbox"))
  ok(run("stock", "add", "stock1"))
  ok(run("stock", "add", "stock2"))
  ok(run("stock", "remove", "stock2"))
  ok(run("add", IRON, "2", "8", "Iron", "pack"))
  ok(run("add", "minecraft:coal", "1"))
  local cfg = shop.loadConfig()
  eq(cfg.name, "My Little Shop")
  eq(cfg.stock, { "stock1" })
  eq(cfg.items[1], { id = IRON, price = 2, per = 8, label = "Iron pack" })
  eq(cfg.items[2].label, "coal")
  local r, text = run("status")
  ok(r and text:find("My Little Shop", 1, true) and text:find("2 for 8x", 1, true), text)
  ok(run("remove", "2"))
  eq(#shop.loadConfig().items, 1)
  eq(run("remove", "9"), false)
  eq(run("add", "x", "0"), false)
  eq(run("set", "colour", "red"), false)
  eq(run("stock", "add"), false)
  local bad, _, err = run("set", "till", "ghost")
  ok(bad)
  r, text, err = run("status")
  ok(r == false and err:find("till chest 'ghost' not found", 1, true), err)
  eq(run("bogus"), false)
end)
