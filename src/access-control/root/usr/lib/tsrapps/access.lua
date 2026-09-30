-- SPDX-License-Identifier: AGPL-3.0-or-later
-- access: keycard doors. A keycard is a floppy disk carrying a small file signed with the door's secret (HMAC-SHA256),
-- so cards cannot be forged or edited without the secret. Cards have a name, a level, and can be revoked.
--   access setup [--key <secret>]     redstone output, open time, minimum level (a new secret is generated unless given)
--   access issue <name> [level]       write a card to the disk in the drive
--   access revoke <name|id> | unrevoke | list | key | log
--   access run                        wait for cards and open the door
-- Piston doors: use `invert` in setup when the door is CLOSED by power (pistons extended = wall) or `toggle` mode.
local hash = require("tsr.hash")
local cli = require("tsrapps.cli")
local rsio = require("tsrapps.rsio")
local vfs = require("tsr.vfs")

local M = {}

M.CONFIG = "/etc/tsr/access.cfg"
M.LOG = "/var/log/access.log"
M.CARD_FILE = ".tsrcard"
M.SPEC = { key = "string" }

M.DEFAULTS = { output = "top", open_secs = 3, min_level = 1, invert = false, mode = "pulse", revoked = {} }

local function now(env) return (env and env.now) and env.now() or (os.epoch and os.epoch("utc") or 0) end

function M.load() return vfs.readTable(M.CONFIG) end
function M.save(cfg) return vfs.writeTable(M.CONFIG, cfg) end

function M.newSecret(env)
  local seed = tostring(now(env)) .. tostring(math.random(1, 2 ^ 30)) .. tostring(os.clock()) .. tostring(os.getComputerID())
  return hash.sha256(seed)
end

---------------------------------------------------------------------------------------------------------------------
-- Cards
---------------------------------------------------------------------------------------------------------------------

local function cardSig(secret, card)
  return hash.hmacSha256(secret, table.concat({ tostring(card.id), tostring(card.name), tostring(card.level) }, "|"))
end

--- Make a card table (not yet on a disk).
function M.makeCard(secret, name, level, env)
  local card = { v = 1, id = hash.sha256(name .. tostring(now(env)) .. tostring(math.random(1, 2 ^ 30))):sub(1, 12),
                 name = name, level = level, issued = now(env) }
  card.sig = cardSig(secret, card)
  return card
end

--- Check a card read from a disk. Returns true, card  or  false, reason.
function M.verify(cfg, card)
  if type(card) ~= "table" or card.v ~= 1 or type(card.id) ~= "string" or type(card.level) ~= "number" then
    return false, "not a Tessera card"
  end
  if card.sig ~= cardSig(cfg.secret, card) then return false, "forged or altered card" end
  if cfg.revoked[card.id] then return false, "card revoked" end
  if card.level < cfg.min_level then return false, ("level %d is below the required %d"):format(card.level, cfg.min_level) end
  return true, card
end

function M.writeCard(mount, card)
  return vfs.writeTable(mount .. "/" .. M.CARD_FILE, card)
end

function M.readCard(mount)
  return vfs.readTable(mount .. "/" .. M.CARD_FILE)
end

---------------------------------------------------------------------------------------------------------------------
-- Door
---------------------------------------------------------------------------------------------------------------------

local function log(line, env)
  local stamp = (env and env.stamp) and env.stamp() or (os.date and os.date("%Y-%m-%d %H:%M:%S") or "")
  local h = fs.open(M.LOG, "a")
  if h then h.writeLine(stamp .. " " .. line) h.close() end
end

--- Operate the door output. pulse: open for open_secs; toggle: flip. invert flips what "open" means.
function M.operate(cfg, env)
  local port = assert(rsio.open(cfg.output, env))
  local openLevel = not cfg.invert
  if cfg.mode == "toggle" then
    port.set(not ((port.getOutput() == true) or (type(port.getOutput()) == "number" and port.getOutput() > 0)))
    return
  end
  port.set(openLevel)
  local sleepFn = (env and env.sleep) or sleep
  local ok, err = pcall(sleepFn, cfg.open_secs)
  port.set(not openLevel)
  if not ok then error(err, 0) end
end

--- A card was inserted on `side`. Returns true if the door opened, or false + reason.
function M.handleCard(cfg, side, env)
  local d = (env and env.disk) or disk
  if not d.isPresent(side) then return false, "no disk" end
  local mount = d.getMountPath(side)
  if not mount then return false, "the disk has no data" end
  local card = M.readCard(mount)
  local ok, res = M.verify(cfg, card)
  if not ok then
    log("DENIED " .. tostring(card and card.name or "?") .. " (" .. res .. ")", env)
    return false, res
  end
  log("OPENED " .. res.name .. " level " .. res.level .. " id " .. res.id, env)
  M.operate(cfg, env)
  return true, res
end

function M.run(cfg, io, env)
  env = env or {}
  local pull = env.pullEvent or os.pullEvent
  io.say("Door armed. Insert a card. (Ctrl+T to stop)")
  local handled = 0
  while true do
    local ev, side = pull("disk")
    local ok, res = M.handleCard(cfg, side, env)
    if ok then io.say("Welcome, " .. res.name .. ".") else io.warn("Denied: " .. tostring(res)) end
    local d = env.disk or disk
    if d.eject then pcall(d.eject, side) end
    handled = handled + 1
    if env.maxCards and handled >= env.maxCards then return handled end
  end
end

function M.findDrive(env)
  local per = (env and env.peripheral) or peripheral
  local d = per.find("drive")
  if not d then return nil end
  return per.getName and per.getName(d) or nil
end

function M.main(args, io, env)
  io = io or cli.io()
  local pos, opts = cli.parse(args, M.SPEC)
  if not pos then io.err(opts) return false end
  local cmd = pos[1]
  local cfg = M.load()
  if cmd == "setup" then
    cfg = cfg or {}
    for k, v in pairs(M.DEFAULTS) do if cfg[k] == nil then cfg[k] = v end end
    cfg.secret = opts.key or cfg.secret or M.newSecret(env)
    cfg.output = io.prompt("Redstone output that opens the door", cfg.output)
    local p, err = rsio.parse(cfg.output, env)
    if not p then io.err(err) return false end
    cfg.mode = io.prompt("Mode (pulse or toggle)", cfg.mode)
    if cfg.mode ~= "pulse" and cfg.mode ~= "toggle" then io.err("mode must be pulse or toggle") return false end
    cfg.open_secs = tonumber(io.prompt("Seconds the door stays open", cfg.open_secs))
    cfg.min_level = tonumber(io.prompt("Minimum card level", cfg.min_level))
    if not (cfg.open_secs and cfg.open_secs > 0 and cfg.min_level and cfg.min_level >= 0) then
      io.err("open time must be positive and the level must be a number") return false
    end
    cfg.invert = io.ask and io.ask("Is the door CLOSED by power (piston door)?", cfg.invert) or cfg.invert
    M.save(cfg)
    io.say("Saved. Doors that should accept the same cards need the same key: run `access key` here and `access setup --key <key>` there.")
    return true
  end
  if not cfg then io.err("Not set up yet: run `access setup`.") return false end
  if cmd == "issue" then
    local name = pos[2]
    local level = tonumber(pos[3] or "1")
    if not name or not level then io.err("usage: access issue <name> [level]") return false end
    local d = (env and env.disk) or disk
    local side = env and env.driveSide or M.findDrive(env)
    if not side or not d.isPresent(side) then io.err("Put a blank floppy disk in a disk drive first.") return false end
    local mount = d.getMountPath(side)
    if not mount then io.err("The disk cannot store data.") return false end
    local card = M.makeCard(cfg.secret, name, level, env)
    local ok, err = M.writeCard(mount, card)
    if not ok then io.err("Could not write the card: " .. tostring(err)) return false end
    if d.setLabel then pcall(d.setLabel, side, "Card: " .. name) end
    io.say(("Issued %s (level %d, id %s)."):format(name, level, card.id))
    return true
  elseif cmd == "revoke" or cmd == "unrevoke" then
    local id = pos[2]
    if not id then io.err("usage: access " .. cmd .. " <card id>") return false end
    cfg.revoked[id] = (cmd == "revoke") or nil
    M.save(cfg)
    io.say((cmd == "revoke" and "Revoked " or "Restored ") .. id)
    return true
  elseif cmd == "list" then
    local n = 0
    for id in pairs(cfg.revoked) do io.say("revoked: " .. id) n = n + 1 end
    if n == 0 then io.say("No revoked cards.") end
    return true
  elseif cmd == "key" then
    io.say(cfg.secret)
    return true
  elseif cmd == "log" then
    local h = fs.open(M.LOG, "r")
    if not h then io.say("The log is empty.") return true end
    local lines = {}
    for line in h.readAll():gmatch("[^\n]+") do lines[#lines + 1] = line end
    h.close()
    for i = math.max(1, #lines - 19), #lines do io.say(lines[i]) end
    return true
  elseif cmd == "run" then
    M.run(cfg, io, env)
    return true
  end
  io.say("usage: access setup | issue <name> [level] | revoke <id> | unrevoke <id> | list | key | log | run")
  return false
end

return M
