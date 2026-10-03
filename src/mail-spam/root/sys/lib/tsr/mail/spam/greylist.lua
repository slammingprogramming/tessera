-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Greylisting: a server we have never heard from is told "try again later" (a temporary 451). Real mail servers retry (they have a queue); most spam software does not.
-- The first contact of a (sender network, sender, recipient) triplet is refused; after `delay` seconds the same triplet is let through and remembered; a sender network
-- that has passed `trustAfter` triplets is let through at once from then on. Mail from trusted networks and logged-in users is never delayed.
--   local g = greylist.new(mail, { delay = 300, window = 14400, keep = 3 * 86400, trustAfter = 3 })
--   mail.policy.rcpt = g:hook()
local B = require("tsr.inet.bytes")

local M = {}
local Grey = {}
Grey.__index = Grey

function M.new(mail, opts)
  opts = opts or {}
  return setmetatable({
    mail = mail, delay = opts.delay or 300, window = opts.window or 14400, keep = opts.keep or 3 * 86400, trustAfter = opts.trustAfter or 3,
    triplets = {}, nets = {}, stats = { delayed = 0, passed = 0 }, allow = opts.allow or {}, count = 0,
  }, Grey)
end

local function netOf(ip)
  local n = type(ip) == "number" and ip or B.ip(ip or "")
  if not n then return tostring(ip) end
  return B.ipStr(n - n % 256)
end

--- Decide for one recipient. Returns nil to accept, or the SMTP reply { code, text }.
function Grey:check(ip, sender, rcpt)
  local now = self.mail:now()
  local net = netOf(ip)
  sender = (sender or ""):lower()
  rcpt = (rcpt or ""):lower()
  for _, a in ipairs(self.allow) do
    if sender == a or sender:sub(-#a - 1) == "@" .. a then return nil end
  end
  local netRec = self.nets[net]
  if netRec and netRec.passed >= self.trustAfter then self.stats.passed = self.stats.passed + 1 return nil end
  local key = net .. "|" .. sender .. "|" .. rcpt
  local rec = self.triplets[key]
  if rec and rec.ok then
    rec.seen = now
    self.stats.passed = self.stats.passed + 1
    return nil
  end
  if not rec or now - rec.first > self.window then
    self.triplets[key] = { first = now, seen = now }
    self.count = self.count + 1
    self.stats.delayed = self.stats.delayed + 1
    self:expire(now)
    return { 451, ("4.7.1 Greylisted: please try again in %d seconds"):format(self.delay) }
  end
  if now - rec.first < self.delay then
    self.stats.delayed = self.stats.delayed + 1
    return { 451, ("4.7.1 Greylisted: please try again in %d seconds"):format(math.ceil(self.delay - (now - rec.first))) }
  end
  rec.ok, rec.seen = true, now
  self.nets[net] = self.nets[net] or { passed = 0 }
  self.nets[net].passed = self.nets[net].passed + 1
  self.stats.passed = self.stats.passed + 1
  return nil
end

--- Forget old triplets (called now and then; bounded memory matters on a small computer).
function Grey:expire(now)
  if self.count < 500 then return end
  local n = 0
  for k, rec in pairs(self.triplets) do
    if now - rec.seen > (rec.ok and self.keep or self.window) then self.triplets[k] = nil else n = n + 1 end
  end
  self.count = n
end

--- A function for mail.policy.rcpt.
function Grey:hook()
  return function(session, parsed) return self:check(session.ip, session.sender, parsed.addr) end
end

return M
