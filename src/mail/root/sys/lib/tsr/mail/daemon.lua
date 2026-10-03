-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The maild service: SMTP (25 and 587, with 465 when TLS is set up), POP3 (110, 995), the delivery queue, the anti-spam checks and the anti-virus scan,
-- all in one process (they share the mailbox indexes). Settings: /etc/tsr/mail/mail.lua and /etc/tsr/mail/routing.db (see tsr.mail.config).
local socket = require("tsr.inet.socket")
local config = require("tsr.mail.config")
local mailMod = require("tsr.mail")
local smtpd = require("tsr.mail.smtpd")
local pop3d = require("tsr.mail.pop3d")
local storeMod = require("tsr.mail.store")
local vfs = require("tsr.vfs")
local log = require("tsr.log").get("maild")

local M = {}

--- Make the DKIM key files into the table the spam module expects.
local function prepareSpam(spamCfg)
  spamCfg = spamCfg or {}
  if spamCfg.dkim then
    for domain, k in pairs(spamCfg.dkim) do
      if type(k) == "table" and not k.seed and k.keyFile then
        local seed, why = require("tsr.mail.spam").loadDkimKey(k.keyFile)
        if seed then k.seed = seed else log.warn("%s", "DKIM key for " .. domain .. ": " .. tostring(why)) end
      end
    end
  end
  return spamCfg
end

function M.main()
  local stack
  while true do
    local ok, s = pcall(socket.default)
    if ok then stack = s break end
    os.sleep(1)
  end
  local cfg, err = config.load()
  if not cfg then log.error("%s", "mail.lua: " .. tostring(err)) return end
  if not cfg.hostname then
    cfg.hostname = stack.hostname or "localhost"
  end
  if #cfg.domains == 0 then log.warn("%s", "no mail domain is configured (mailctl domain add <domain>)") end
  local store = storeMod.new({ root = cfg.root, users = cfg.users, iterations = cfg.passwordIterations })
  local mail = mailMod.new(stack, cfg, store)
  M.mail = mail
  mail.stack.logger = function(text) log.info("%s", text) end
  if cfg.spam ~= false then
    local okS, spam = pcall(require, "tsr.mail.spam")
    if okS then mail.spamControl = spam.install(mail, prepareSpam(cfg.spam)) end
  end
  if cfg.av ~= false then
    local okA, av = pcall(require, "tsr.av")
    if okA and av.installMail then pcall(av.installMail, mail, type(cfg.av) == "table" and cfg.av or {}) end
  end
  local jobs = smtpd.workers(mail, 3)
  if cfg.pop3 ~= false then
    for _, j in ipairs(pop3d.workers(mail, 2)) do jobs[#jobs + 1] = j end
  end
  -- settings changed by mailctl, and requests from it
  jobs[#jobs + 1] = function()
    local lastBayes
    while mail.running do
      local okW = pcall(function()
        local domains, relay, aliases = config.liveRouting()
        if domains then mail:setRouting(domains, relay, aliases) end
        if vfs.fs.exists(config.FLUSH) then
          vfs.fs.delete(config.FLUSH)
          mail:processQueue(true)
        end
        local S = mail.spamControl
        if S and S.bayes and S.bayes.path then
          local a = vfs.fs.attributes and vfs.fs.attributes(S.bayes.path)
          local stamp = a and (tostring(a.modified) .. ":" .. tostring(a.size))
          if stamp ~= lastBayes then
            if lastBayes ~= nil then S.bayes = require("tsr.mail.spam.bayes").new(S.bayes.path, { maxTokens = S.cfg.bayesTokens }) end
            lastBayes = stamp
          end
        end
      end)
      if not okW then mail:note("housekeeping failed") end
      stack.wait(function() return not mail.running end, 5)
    end
  end
  log.info("%s", ("mail server %s for %s"):format(cfg.hostname, table.concat(cfg.domains, ", ")))
  parallel.waitForAny(table.unpack(jobs))
end

function M.stop()
  if M.mail then
    smtpd.stop(M.mail)
    pop3d.stop(M.mail)
  end
end

return M
