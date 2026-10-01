-- SPDX-License-Identifier: AGPL-3.0-or-later
local bot = require("tsr.chatbot")
local svc = require("tsr.svc")

local DIR = "/tmp-chatbot"

--- A fake chat box recording what the bot says.
local function fakeBox(opts)
  opts = opts or {}
  local box = { said = {} }
  if not opts.noPlayerMessage then
    function box.sendMessageToPlayer(msg, user, prefix) box.said[#box.said + 1] = { to = user, text = msg, prefix = prefix } end
  end
  function box.sendMessage(msg, prefix) box.said[#box.said + 1] = { to = "*", text = msg, prefix = prefix } end
  return box
end

local function setup()
  if fs.exists(DIR) then fs.delete(DIR) end
  fs.makeDir(DIR)
  bot.CFG_PATH = DIR .. "/cfg"
  bot.DIR = DIR .. "/extra"
  bot.resetCooldowns()
end

local CFG = { prefix = "!", name = "Bot", admins = { "Boss" }, admin_uuids = { "uuid-admin" } }

test("only prefixed messages are commands", function()
  setup()
  local box = fakeBox()
  eq(bot.handle(box, CFG, "Alice", "hello there", "u1", 0), false)
  eq(bot.handle(box, CFG, "Alice", "!", "u1", 10), false)
  eq(bot.handle(box, CFG, "Alice", nil, "u1", 20), false)
  eq(#box.said, 0)
  eq(bot.handle(box, CFG, "Alice", "!time", "u1", 30), true)
  eq(#box.said, 1)
  eq(box.said[1].to, "Alice")
  eq(box.said[1].prefix, "Bot")
  ok(box.said[1].text:find("Day", 1, true), box.said[1].text)
end)

test("help lists what the player may use", function()
  setup()
  local box = fakeBox()
  bot.handle(box, CFG, "Alice", "!help", "u1", 0)
  ok(box.said[1].text:find("!status", 1, true))
  ok(not box.said[1].text:find("!svc", 1, true), "admin commands are hidden from players")
  bot.handle(box, CFG, "Boss", "!help", "u2", 0)
  ok(box.said[2].text:find("!svc", 1, true))
end)

test("unknown commands get a hint, and the cooldown stops spam", function()
  setup()
  local box = fakeBox()
  bot.handle(box, CFG, "Alice", "!nothing", "u1", 0)
  ok(box.said[1].text:find("Unknown command", 1, true))
  bot.handle(box, CFG, "Alice", "!nothing", "u1", 0.5)
  eq(#box.said, 1, "second command inside the cooldown is ignored")
  bot.handle(box, CFG, "Alice", "!nothing", "u1", 5)
  eq(#box.said, 2)
  -- other players are independent
  bot.handle(box, CFG, "Bob", "!nothing", "u2", 5.1)
  eq(#box.said, 3)
end)

test("administrators are recognised by name (any case) or uuid", function()
  setup()
  svc.reset()
  svc.define({ name = "demo", run = function() while true do os.pullEvent("never") end end })
  local box = fakeBox()
  bot.handle(box, CFG, "Alice", "!svc list", "u1", 0)
  ok(box.said[1].text:find("Only administrators", 1, true))
  bot.handle(box, CFG, "boss", "!svc list", "u2", 0)
  ok(box.said[2].text:find("demo=stopped", 1, true), box.said[2].text)
  bot.handle(box, CFG, "Renamed", "!svc start demo", "uuid-admin", 0)
  ok(box.said[3].text:find("start demo: ok", 1, true), box.said[3].text)
  bot.handle(box, CFG, "Boss", "!svc stop demo", "u2", 5)
  ok(box.said[4].text:find("stop demo: ok", 1, true))
  bot.handle(box, CFG, "Boss", "!svc start ghost", "u2", 10)
  ok(box.said[5].text:find("no such service", 1, true))
  bot.handle(box, CFG, "Boss", "!svc dance", "u2", 15)
  ok(box.said[6].text:find("usage", 1, true))
  svc.reset()
end)

test("a crashing command is reported, not fatal", function()
  setup()
  bot.register("crash", { run = function() error("kaboom", 0) end })
  local box = fakeBox()
  bot.handle(box, CFG, "Alice", "!crash", "u1", 0)
  ok(box.said[1].text:find("That failed: kaboom", 1, true), box.said[1].text)
  bot.commands.crash = nil
end)

test("long replies are cut into a few chat lines", function()
  setup()
  bot.register("long", { run = function() return string.rep("word ", 400) end })
  local box = fakeBox()
  bot.handle(box, CFG, "Alice", "!long", "u1", 0)
  eq(#box.said, bot.MAX_LINES)
  for _, s in ipairs(box.said) do ok(#s.text <= bot.MAX_LINE) end
  ok(box.said[#box.said].text:sub(-3) == "...")
  bot.register("multi", { run = function() return { "a", "b" } end })
  bot.handle(box, CFG, "Alice", "!multi", "u1", 10)
  eq(box.said[#box.said].text, "a | b")
  bot.commands.long, bot.commands.multi = nil, nil
end)

test("falls back to public messages when the box cannot whisper", function()
  setup()
  local box = fakeBox({ noPlayerMessage = true })
  bot.handle(box, CFG, "Alice", "!time", "u1", 0)
  eq(box.said[1].to, "*")
  ok(box.said[1].text:find("@Alice", 1, true))
end)

test("extra command files are loaded", function()
  setup()
  fs.makeDir(bot.DIR)
  local h = fs.open(bot.DIR .. "/hello.lua", "w")
  h.write([[return { hello = { help = "greet", run = function(ctx, args) return "Hello " .. ctx.user .. " " .. (args[1] or "") end },
                     broken = "not a table" }]])
  h.close()
  local h2 = fs.open(bot.DIR .. "/bad.lua", "w")
  h2.write("return {")
  h2.close()
  eq(bot.loadExtras(), 1)
  local box = fakeBox()
  bot.handle(box, CFG, "Alice", "!hello world", "u1", 0)
  eq(box.said[1].text, "Hello Alice world")
  bot.commands.hello = nil
end)

test("the chatbot command edits the configuration", function()
  setup()
  local function run(...)
    local io = { said = {}, errs = {} }
    function io.say(t) io.said[#io.said + 1] = t end
    function io.err(t) io.errs[#io.errs + 1] = t end
    local r = bot.cli({ ... }, io)
    return r, table.concat(io.said, " / "), table.concat(io.errs, " / ")
  end
  local r, text = run("status")
  ok(r and text:find("nobody", 1, true), text)
  r, text = run("admin", "add", "Steve")
  ok(r and text:find("Steve", 1, true))
  r, text = run("admin", "add", "Alex")
  eq(bot.loadConfig().admins, { "Steve", "Alex" })
  run("admin", "remove", "steve")
  eq(bot.loadConfig().admins, { "Alex" })
  ok(run("prefix", "?"))
  eq(bot.loadConfig().prefix, "?")
  eq(run("prefix", "toolong"), false)
  eq(run("admin", "promote", "x"), false)
  eq(run("nonsense"), false)
end)
