-- SPDX-License-Identifier: AGPL-3.0-or-later
-- A learning spam filter (naive Bayes over word counts, in the style of Paul Graham's "A Plan for Spam" with Robinson's smoothing). It starts knowing nothing and
-- says "unknown" until it has seen a few spam and a few good messages; users teach it by moving mail to or from the Spam folder (mailctl spam learn / mail spam / mail ham).
-- The database is a Lua table file that stays small: only the commonest tokens are kept (default 6000).
--   local b = bayes.new("/var/lib/tsr/mail/bayes.lua")
--   b:train(rawMessage, true)    -- this was spam
--   local p, why = b:classify(rawMessage)    -- 0 (surely good) .. 1 (surely spam), or nil when it has not learned enough
local vfs = require("tsr.vfs")
local msg = require("tsr.mail.message")

local M = {}
local Bayes = {}
Bayes.__index = Bayes

M.MIN_LEARNED = 3
M.MAX_TOKENS = 6000
M.INTERESTING = 15

function M.new(path, opts)
  opts = opts or {}
  local self = setmetatable({ path = path, maxTokens = opts.maxTokens or M.MAX_TOKENS, spam = 0, ham = 0, tokens = {}, dirty = false }, Bayes)
  local saved = path and vfs.readTable(path)
  if saved then
    self.spam, self.ham, self.tokens = saved.spam or 0, saved.ham or 0, saved.tokens or {}
  end
  return self
end

--- The words of a message plus a few markers (sender domain, attachment types, link hosts).
function M.tokens(raw)
  local m = msg.parse(raw)
  local seen, list = {}, {}
  local function add(t)
    if #t >= 3 and #t <= 24 and not seen[t] then seen[t] = true list[#list + 1] = t end
  end
  local subject = m:subject():lower()
  for w in subject:gmatch("[%w'$!]+") do add("s:" .. w) end
  local from = m:from()
  if from then add("from:" .. from.domain) end
  local text = m:text():lower()
  if #text > 6000 then text = text:sub(1, 6000) end
  for w in text:gmatch("[%w'$!]+") do add(w) end
  for host in text:gmatch("https?://([%w%.%-]+)") do add("url:" .. host) end
  for _, a in ipairs(m:attachments()) do
    local ext = (a.name or ""):match("%.(%w+)$")
    if ext then add("attach:" .. ext:lower()) end
  end
  if raw:find("[Cc]ontent%-[Tt]ype:%s*text/html") then add("html:yes") end
  return list
end

function Bayes:train(raw, isSpam)
  for _, t in ipairs(M.tokens(raw)) do
    local rec = self.tokens[t]
    if not rec then rec = { 0, 0 } self.tokens[t] = rec end
    rec[isSpam and 1 or 2] = rec[isSpam and 1 or 2] + 1
  end
  if isSpam then self.spam = self.spam + 1 else self.ham = self.ham + 1 end
  self.dirty = true
  self:prune()
end

--- Take back a training (the user moved a message the other way).
function Bayes:untrain(raw, wasSpam)
  for _, t in ipairs(M.tokens(raw)) do
    local rec = self.tokens[t]
    if rec then
      local i = wasSpam and 1 or 2
      rec[i] = math.max(0, rec[i] - 1)
      if rec[1] + rec[2] == 0 then self.tokens[t] = nil end
    end
  end
  if wasSpam then self.spam = math.max(0, self.spam - 1) else self.ham = math.max(0, self.ham - 1) end
  self.dirty = true
end

--- Keep the table below the limit by dropping the rarest tokens.
function Bayes:prune()
  local n = 0
  for _ in pairs(self.tokens) do n = n + 1 end
  if n <= self.maxTokens then return end
  local list = {}
  for t, rec in pairs(self.tokens) do list[#list + 1] = { t, rec[1] + rec[2] } end
  table.sort(list, function(a, b) if a[2] ~= b[2] then return a[2] < b[2] end return a[1] < b[1] end)
  for i = 1, n - math.floor(self.maxTokens * 0.8) do self.tokens[list[i][1]] = nil end
end

function Bayes:learned() return self.spam, self.ham end

--- Probability that the message is spam, or nil + reason without enough training.
function Bayes:classify(raw)
  if self.spam < M.MIN_LEARNED or self.ham < M.MIN_LEARNED then return nil, "not trained enough yet (" .. self.spam .. " spam, " .. self.ham .. " good)" end
  local probs = {}
  for _, t in ipairs(M.tokens(raw)) do
    local rec = self.tokens[t]
    if rec then
      local s, h = rec[1] / self.spam, rec[2] / self.ham
      local p = s / (s + h)
      -- Robinson's correction for words seen only a few times
      local n = rec[1] + rec[2]
      p = (0.5 + n * p) / (1 + n)
      probs[#probs + 1] = math.min(0.99, math.max(0.01, p))
    end
  end
  if #probs == 0 then return 0.5, "no known words" end
  table.sort(probs, function(a, b) return math.abs(a - 0.5) > math.abs(b - 0.5) end)
  local logSpam, logHam = 0, 0
  for i = 1, math.min(M.INTERESTING, #probs) do
    logSpam = logSpam + math.log(probs[i])
    logHam = logHam + math.log(1 - probs[i])
  end
  local d = logHam - logSpam
  if d > 30 then return 0, "good" end
  if d < -30 then return 1, "spam" end
  return 1 / (1 + math.exp(d)), "classified"
end

function Bayes:save()
  if not self.path or not self.dirty then return true end
  vfs.mkdirp(self.path:match("^(.*)/[^/]*$") or "/")
  local ok, err = vfs.writeTable(self.path, { spam = self.spam, ham = self.ham, tokens = self.tokens })
  if ok then self.dirty = false end
  return ok, err
end

function Bayes:reset()
  self.spam, self.ham, self.tokens, self.dirty = 0, 0, {}, true
end

return M
