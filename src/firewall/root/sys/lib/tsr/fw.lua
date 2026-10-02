-- SPDX-License-Identifier: AGPL-3.0-or-later
-- A packet filter for the in-game network, in the spirit of iptables / Windows Defender Firewall. It looks at every message a computer
-- receives (before any service sees it) and decides by rules whether to let it in. Rules live in /etc/tsr/firewall.rules:
--
--     default deny                          # what happens when no rule matches: allow (the default) or deny
--     allow from paired                     # computers you paired with
--     allow type ping,disco.q from any      # anybody may ping and ask who offers what
--     deny  from 15                         # computer 15 is shut out completely
--     allow type ssh from 11,12,alpha       # computer ids or peer names
--     limit 20/min type p2p from any        # at most 20 such messages per minute from each computer, the rest is dropped
--
-- Rules are checked top to bottom, the first match wins. `type` is the message type (ping, disco.q, time.q, rpc, ssh, ntp.q, p2p, pair.1 ...);
-- "p2p.find" narrows a type to one kind of message. `from` is any, paired (peers you paired with), computer ids or peer/host names.
-- Replies to something this computer sent a moment ago (or to its broadcast) always pass: closing the door to strangers must not
-- deafen the computer. Stateless apart from that, no deep inspection: a filter against noise and nuisances, not a defence against someone
-- who controls a modem.
local vfs = require("tsr.vfs")
local log = require("tsr.log").get("fw")

local M = {}

M.RULES = "/etc/tsr/firewall.rules"
M.REPLY_WINDOW = 30          -- seconds after we sent to a computer during which its replies are expected
M.BROADCAST_WINDOW = 3
M.LOG_SIZE = 40

local PERIODS = { s = 1, sec = 1, m = 60, min = 60, h = 3600, hour = 3600 }

-- messages that answer a request (never filtered as long as they are expected)
local RESPONSE_KINDS = {
  ssh = { reply = true, rep = true, refuse = true },
  p2p = { has = true, meta = true, piece = true, no = true, bhas = true, bdata = true, peers = true, scrape = true },
}
local RESPONSE_TYPES = { ["ping.r"] = true, ["disco.r"] = true, ["time.r"] = true, ["rpc.r"] = true, ["pair.2"] = true, ["ntp.r"] = true }

local function isResponse(msg)
  if RESPONSE_TYPES[msg.t] then return true end
  local kinds = RESPONSE_KINDS[msg.t]
  return kinds ~= nil and kinds[msg.k] == true
end
M.isResponse = isResponse

---------------------------------------------------------------------------------------------------------------------
-- Rules
---------------------------------------------------------------------------------------------------------------------

local function splitList(s)
  local out = {}
  for item in tostring(s):gmatch("[^,]+") do out[#out + 1] = item end
  return out
end

--- Parse one line. Returns rule, nil | false (blank or comment) | nil + reason.
function M.parseLine(line)
  line = line:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if line == "" then return false end
  local words = {}
  for w in line:gmatch("%S+") do words[#words + 1] = w end
  local action = words[1]:lower()
  if action == "default" then
    local policy = (words[2] or ""):lower()
    if policy ~= "allow" and policy ~= "deny" then return nil, "default must be allow or deny" end
    return { action = "default", policy = policy, text = line }
  end
  if action ~= "allow" and action ~= "deny" and action ~= "limit" then return nil, "unknown rule '" .. words[1] .. "' (allow, deny, limit, default)" end
  local rule = { action = action, types = nil, from = { "any" }, text = line }
  local i = 2
  if action == "limit" then
    local n, unit = (words[2] or ""):match("^(%d+)/(%a+)$")
    if not n or not PERIODS[unit] then return nil, "limit needs a rate such as 20/min" end
    rule.rate, rule.period = tonumber(n), PERIODS[unit]
    i = 3
  end
  while i <= #words do
    local key, value = words[i]:lower(), words[i + 1]
    if (key == "type" or key == "from") and value then
      if key == "type" then rule.types = splitList(value) else rule.from = splitList(value) end
      i = i + 2
    else
      return nil, "cannot read '" .. words[i] .. "' (expected type <list> or from <list>)"
    end
  end
  return rule
end

--- Parse a rules text. Returns { default = "allow"|"deny", list = rules }, problems.
function M.parse(text)
  local set, problems = { default = "allow", list = {} }, {}
  local n = 0
  for line in ((text or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    n = n + 1
    local rule, err = M.parseLine(line)
    if rule then
      if rule.action == "default" then set.default = rule.policy else set.list[#set.list + 1] = rule end
    elseif rule == nil then
      problems[#problems + 1] = ("line %d: %s"):format(n, err)
    end
  end
  return set, problems
end

function M.load()
  return M.parse(vfs.readFile(M.RULES) or "")
end

local function matchType(rule, msg)
  if not rule.types then return true end
  local full = msg.k and (tostring(msg.t) .. "." .. tostring(msg.k)) or nil
  for _, t in ipairs(rule.types) do
    if t == "any" or t == msg.t or (full and t == full) then return true end
  end
  return false
end

local function matchFrom(rule, node, from)
  for _, f in ipairs(rule.from) do
    if f == "any" then return true end
    if f == "paired" or f == "peers" then
      if node.peer and node:peer(from) then return true end
    elseif tonumber(f) then
      if tonumber(f) == from then return true end
    else
      local p = node.peer and node:peer(f)
      if p and p.id == from then return true end
    end
  end
  return false
end

---------------------------------------------------------------------------------------------------------------------
-- The filter
---------------------------------------------------------------------------------------------------------------------

--- Create the filter state for a rule set. opts: clock (function -> seconds).
function M.new(set, opts)
  opts = opts or {}
  return {
    set = set, clock = opts.clock or os.clock, hits = {}, buckets = {}, denied = 0, allowed = 0, dropped = {},
    recent = {},
  }
end

local function remember(state, entry)
  state.recent[#state.recent + 1] = entry
  while #state.recent > M.LOG_SIZE do table.remove(state.recent, 1) end
end

--- Decide about one message. Returns allow (boolean) and why (rule number, "reply", "default").
function M.decide(state, node, from, msg)
  local now = state.clock()
  if type(msg) == "table" and isResponse(msg) then
    local at = node.contacted and node.contacted[from]
    if (at and now - at <= M.REPLY_WINDOW) or (node.broadcastAt and now - node.broadcastAt <= M.BROADCAST_WINDOW) then
      state.allowed = state.allowed + 1
      return true, "reply"
    end
  end
  if type(msg) ~= "table" then return false, "malformed" end
  for i, rule in ipairs(state.set.list) do
    if matchType(rule, msg) and matchFrom(rule, node, from) then
      state.hits[i] = (state.hits[i] or 0) + 1
      local allow = rule.action == "allow"
      if rule.action == "limit" then
        local key = i .. ":" .. from
        local b = state.buckets[key]
        if not b or now - b.start >= rule.period then b = { start = now, count = 0 } state.buckets[key] = b end
        b.count = b.count + 1
        allow = b.count <= rule.rate
      end
      if allow then state.allowed = state.allowed + 1 else
        state.denied = state.denied + 1
        remember(state, { time = now, from = from, type = tostring(msg.t) .. (msg.k and ("." .. tostring(msg.k)) or ""), rule = i })
      end
      return allow, i
    end
  end
  local allow = state.set.default == "allow"
  if allow then state.allowed = state.allowed + 1 else
    state.denied = state.denied + 1
    remember(state, { time = now, from = from, type = tostring(msg.t) .. (msg.k and ("." .. tostring(msg.k)) or ""), rule = "default" })
  end
  return allow, "default"
end

--- Switch the firewall on for a node (rules read from the rules file unless `set` is given). Returns the state.
function M.install(node, set, opts)
  local problems
  if not set then set, problems = M.load() end
  local state = M.new(set, opts)
  state.problems = problems or {}
  node.firewall = function(n, from, msg) return (M.decide(state, n, from, msg)) end
  node.firewallState = state
  return state
end

function M.uninstall(node) node.firewall, node.firewallState = nil, nil end

--- Re-read the rules into the running filter (counters are kept). Returns problems.
function M.reload(node)
  local set, problems = M.load()
  if node.firewallState then node.firewallState.set = set node.firewallState.problems = problems end
  return problems
end

--- The firewall service: install on the default node and re-read the rules when the file changes.
function M.daemon()
  local node = require("tsr.net").default()
  local state = M.install(node)
  for _, p in ipairs(state.problems) do log.warn("firewall rules: %s", p) end
  log.info("firewall on: %d rule(s), default %s", #state.set.list, state.set.default)
  local last = fs.exists(M.RULES) and fs.attributes and fs.attributes(M.RULES).modified or nil
  while true do
    sleep(30)
    local ok, attrs = pcall(fs.attributes, M.RULES)
    local stamp = ok and type(attrs) == "table" and attrs.modified or nil
    if stamp ~= last then
      last = stamp
      local problems = M.reload(node)
      log.info("firewall rules reloaded (%d problem(s))", #problems)
    end
  end
end

return M
