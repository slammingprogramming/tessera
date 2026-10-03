-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Settings of the mail server. Two places:
--   /etc/tsr/mail/mail.lua   written by hand (a Lua table): host name, TLS, limits, anti-spam, anti-virus. `mailctl init` writes a commented template.
--   /etc/tsr/mail/routing.db changed by `mailctl`: the domains, relay networks, aliases and the allow/deny lists. The server reads it again when it changes.
-- Both are merged into one table by load().
local vfs = require("tsr.vfs")

local M = {}

M.STATIC = "/etc/tsr/mail/mail.lua"
M.ROUTING = "/etc/tsr/mail/routing.db"
M.FLUSH = "/var/spool/mail/flush"
M.DKIM_DIR = "/etc/tsr/mail/dkim"

M.TEMPLATE = [[
-- Mail server settings (Tessera). After changing this file run: svc restart maild
return {
  hostname = "%s",                  -- the name this server gives in greetings; it should have an A record in DNS
  domains = { "%s" },               -- mail for these domains is delivered here (more with: mailctl domain add)
  relayNetworks = {},               -- client networks that may send to any domain without logging in, e.g. { "10.0.0.0/24" } (or: mailctl relay add)

  -- limits
  maxSize = 1048576,                -- largest message in bytes
  maxRecipients = 50,
  -- retryDelays = { 300, 900, 3600, 14400, 43200 },   -- seconds between delivery attempts of mail that could not be delivered yet
  -- maxAge = 432000,                                   -- give up after this many seconds and send a bounce message

  -- encrypted connections: the name of a certificate made with tlsctl (STARTTLS, port 465 and 995 follow from it)
  -- tls = "%s",
  allowPlainAuth = false,           -- allow passwords on connections that are not encrypted (a trusted LAN only)

  -- which services to run
  pop3 = true,

  -- anti-spam (see docs/MAIL.md). Remove the table or set spam = false to switch everything off.
  spam = {
    spamAt = 5,                     -- from this score on mail goes to the Spam folder
    rejectAt = 12,                  -- from this score on mail is refused while the sender is still connected
    bayes = "/var/lib/tsr/mail/bayes.lua",   -- the learning filter (false = off)
    greylist = false,               -- { delay = 300 } makes unknown senders retry once
    dnsbl = {},                     -- blocklist zones, e.g. { { zone = "bl.example.lan", score = 4 } }
    -- dkim = { ["%s"] = { selector = "mail1", keyFile = "/etc/tsr/mail/dkim/mail1.key" } },   -- sign outgoing mail (mailctl dkim key mail1)
  },

  -- anti-virus: scan attachments (needs the av package). false = off.
  av = true,
}
]]

local ENV = function() return { os = { epoch = os.epoch, time = os.time, clock = os.clock }, string = string, table = table, math = math, tostring = tostring, tonumber = tonumber, ipairs = ipairs, pairs = pairs } end

function M.loadStatic()
  local text = vfs.readFile(M.STATIC)
  if not text then return {} end
  local chunk, err = load(text, "=mail.lua", "t", ENV())
  if not chunk then return nil, err end
  local ok, value = pcall(chunk)
  if not ok then return nil, tostring(value) end
  if type(value) ~= "table" then return nil, "mail.lua must return a table" end
  return value
end

function M.routing()
  local r = vfs.readTable(M.ROUTING) or {}
  r.domains, r.relay, r.aliases, r.allow, r.deny = r.domains or {}, r.relay or {}, r.aliases or {}, r.allow or {}, r.deny or {}
  return r
end

function M.saveRouting(r)
  vfs.mkdirp("/etc/tsr/mail")
  return vfs.writeTable(M.ROUTING, r)
end

local function union(a, b)
  local out, seen = {}, {}
  for _, list in ipairs({ a or {}, b or {} }) do
    for _, v in ipairs(list) do
      local k = tostring(v):lower()
      if not seen[k] then seen[k] = true out[#out + 1] = v end
    end
  end
  return out
end

--- The settings the server runs with: the file plus the routing data.
function M.load()
  local cfg, err = M.loadStatic()
  if not cfg then return nil, err end
  local r = M.routing()
  cfg.domains = union(cfg.domains, r.domains)
  cfg.relayNetworks = union(cfg.relayNetworks, r.relay)
  local aliases = {}
  for k, v in pairs(cfg.aliases or {}) do aliases[k] = v end
  for k, v in pairs(r.aliases) do aliases[k] = v end
  cfg.aliases = aliases
  if type(cfg.spam) == "table" then
    cfg.spam.allow = union(cfg.spam.allow, r.allow)
    cfg.spam.deny = union(cfg.spam.deny, r.deny)
  end
  return cfg
end

--- The part that the server re-reads while it runs (no restart needed).
function M.liveRouting()
  local cfg, err = M.load()
  if not cfg then return nil, err end
  return cfg.domains, cfg.relayNetworks, cfg.aliases, cfg.spam
end

function M.writeTemplate(hostname, domain, force)
  if vfs.fs.exists(M.STATIC) and not force then return nil, M.STATIC .. " exists already (use --force to replace it)" end
  vfs.mkdirp("/etc/tsr/mail")
  hostname = hostname or "mail.example.lan"
  domain = domain or (hostname:match("^[^.]+%.(.+)$") or "example.lan")
  return vfs.writeFile(M.STATIC, M.TEMPLATE:format(hostname, domain, hostname, domain))
end

return M
