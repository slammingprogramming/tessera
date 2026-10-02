-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The fw command:
--   fw status                     is the firewall on, rule hit counts, how much was dropped
--   fw list                       the rules, numbered              fw log      the most recent dropped messages
--   fw add <rule...>              e.g.  fw add allow type ssh from paired        fw del <number>
--   fw default allow|deny         what happens to messages no rule matches
--   fw preset open|lockdown|server      replace the rules with a ready-made set
--   fw test <from> <type>         what would happen to a message of that type from that computer
--   fw reload                     re-read /etc/tsr/firewall.rules
local fw = require("tsr.fw")
local vfs = require("tsr.vfs")

local M = {}

local PRESETS = {
  open = "default allow\n",
  lockdown = "# only computers you paired with, replies to our own requests and discovery/ping from anybody\ndefault deny\nallow from paired\nallow type ping,disco.q,time.q from any\n",
  server = "# a server: paired computers do anything, strangers may discover and ping and use the time and package services, floods are cut\ndefault deny\nallow from paired\nallow type ping,disco.q,time.q,ntp.q from any\nlimit 30/min type p2p from any\nallow type p2p from any\n",
}

local function defaultIO()
  local io = {}
  function io.say(t) print(t) end
  function io.err(t) if term.isColor and term.isColor() then term.setTextColor(colors.red) end print(t) term.setTextColor(colors.white) end
  return io
end

local function needAdmin(io)
  local okAuth, auth = pcall(require, "tsr.auth")
  if not okAuth or not auth.hasUsers() then return true end
  local me = auth.current()
  if me == nil or auth.can(me, "auth.manage") then return true end
  io.err("only administrators can change the firewall")
  return false
end

local function lines()
  local out = {}
  for line in ((vfs.readFile(fw.RULES) or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do out[#out + 1] = line end
  while #out > 0 and out[#out] == "" do out[#out] = nil end
  return out
end

local function save(list, node)
  vfs.writeFile(fw.RULES, table.concat(list, "\n") .. (#list > 0 and "\n" or ""))
  return node and fw.reload(node) or {}
end

--- Numbered rules (not counting comments and the default line): list of { number, text, line }.
local function numbered()
  local out = {}
  for i, line in ipairs(lines()) do
    local rule = fw.parseLine(line)
    if rule and rule.action ~= "default" then out[#out + 1] = { number = #out + 1, text = rule.text, line = i } end
  end
  return out
end

function M.run(args, io, node)
  io = io or defaultIO()
  node = node or (function() local ok, net = pcall(require, "tsr.net") return ok and net.default() or nil end)()
  local sub = args[1] or "status"

  if sub == "status" then
    local state = node and node.firewallState
    local set, problems = fw.load()
    io.say(state and "firewall: ON" or "firewall: off (the fwd service is not running: svc start fwd)")
    io.say(("default policy: %s, %d rule(s)"):format(set.default, #set.list))
    if state then io.say(("allowed %d, dropped %d messages since it started"):format(state.allowed, state.denied)) end
    for i, rule in ipairs(set.list) do
      io.say(("%2d  %-50s %s"):format(i, rule.text, state and ("(" .. (state.hits[i] or 0) .. " hits)") or ""))
    end
    for _, p in ipairs(problems) do io.err("rules file: " .. p) end
    return true
  elseif sub == "list" then
    for _, r in ipairs(numbered()) do io.say(("%2d  %s"):format(r.number, r.text)) end
    return true
  elseif sub == "log" then
    local state = node and node.firewallState
    if not state or #state.recent == 0 then io.say("nothing was dropped") return true end
    for _, e in ipairs(state.recent) do io.say(("computer %-5s %-12s dropped by rule %s"):format(tostring(e.from), e.type, tostring(e.rule))) end
    return true
  elseif sub == "add" then
    if not needAdmin(io) then return false end
    local text = table.concat(args, " ", 2)
    local rule, err = fw.parseLine(text)
    if not rule then io.err(err or "usage: fw add allow|deny|limit ...") return false end
    local list = lines()
    list[#list + 1] = text
    local problems = save(list, node)
    io.say("added: " .. text)
    for _, p in ipairs(problems) do io.err(p) end
    return true
  elseif sub == "del" then
    if not needAdmin(io) then return false end
    local n = tonumber(args[2])
    local rules = numbered()
    if not n or not rules[n] then io.err("usage: fw del <number from `fw list`>") return false end
    local list = lines()
    table.remove(list, rules[n].line)
    save(list, node)
    io.say("deleted: " .. rules[n].text)
    return true
  elseif sub == "default" then
    if not needAdmin(io) then return false end
    local policy = args[2]
    if policy ~= "allow" and policy ~= "deny" then io.err("usage: fw default allow|deny") return false end
    local out, found = {}, false
    for _, line in ipairs(lines()) do
      local rule = fw.parseLine(line)
      if rule and rule.action == "default" then out[#out + 1] = "default " .. policy found = true else out[#out + 1] = line end
    end
    if not found then table.insert(out, 1, "default " .. policy) end
    save(out, node)
    io.say("default policy: " .. policy .. (policy == "deny" and " (make sure `allow from paired` or similar is there, or this computer will not hear anybody)" or ""))
    return true
  elseif sub == "preset" then
    if not needAdmin(io) then return false end
    local text = PRESETS[args[2] or ""]
    if not text then io.err("usage: fw preset open|lockdown|server") return false end
    vfs.writeFile(fw.RULES, text)
    if node then fw.reload(node) end
    io.say("rules replaced by the '" .. args[2] .. "' preset")
    return true
  elseif sub == "reload" then
    local problems = node and fw.reload(node) or select(2, fw.load())
    for _, p in ipairs(problems) do io.err(p) end
    io.say(#problems == 0 and "rules reloaded" or "rules reloaded with problems")
    return #problems == 0
  elseif sub == "test" then
    local from, kind = tonumber(args[2]), args[3]
    if not (from and kind) then io.err("usage: fw test <computer id> <message type>   (e.g. fw test 15 ssh)") return false end
    local set = fw.load()
    local state = fw.new(set)
    local t, k = kind:match("^([^.]+)%.(.+)$")
    local allow, why = fw.decide(state, node or {}, from, { t = t or kind, k = k })
    io.say(("a '%s' message from computer %d would be %s (%s)"):format(kind, from, allow and "ALLOWED" or "DROPPED", tostring(why)))
    return true
  end
  io.err("usage: fw status | list | log | add <rule> | del <n> | default allow|deny | preset open|lockdown|server | test <id> <type> | reload")
  return false
end

function M.main(args) return M.run(args) end

return M
