-- SPDX-License-Identifier: AGPL-3.0-or-later
local msg = require("tsr.mail.message")
local storeMod = require("tsr.mail.store")
local mailMod = require("tsr.mail")
local smtp = require("tsr.mail.smtp")
local smtpd = require("tsr.mail.smtpd")
local spam = require("tsr.mail.spam")
local spf, dkim, dmarc, dnsbl, bayes = spam.spf, spam.dkim, spam.dmarc, spam.dnsbl, spam.bayes
local vfs = require("tsr.vfs")
local Sim = dofile("/tests/lib/inetsim.lua")

local ROOT = "/tmp/spam-test"

local function clean()
  if vfs.fs.exists(ROOT) then vfs.fs.delete(ROOT) end
  vfs.fs.makeDir(ROOT)
end

--- A mail system with fake DNS: txt[name] = { "..." }, a[name] = { "1.2.3.4" }, mx[name] = { { preference, exchange } }.
local function fakeMail(txt, a, mx, extra)
  clean()
  local sim = Sim.new()
  local h = sim:host("mx")
  local cfg = { hostname = "mx.example.lan", root = ROOT .. "/mb", users = ROOT .. "/users.db", queueDir = ROOT .. "/queue", domains = { "example.lan" },
    now = function() return 1000000 + sim.now end,
    dnsTxt = function(name) if txt == false then return nil, "timeout" end return txt[name] or {} end,
    dnsA = function(name) return (a or {})[name] or {} end,
    dnsMx = function(name) return (mx or {})[name] or {} end }
  for k, v in pairs(extra or {}) do cfg[k] = v end
  local st = storeMod.new({ root = cfg.root, users = cfg.users, iterations = 3 })
  assert(st:addUser("alice", "password-alice"))
  return mailMod.new(h, cfg, st), sim
end

test("SPF: mechanisms, qualifiers, include, redirect, macros, limits, errors", function()
  local txt = {
    ["a.lan"] = { "v=spf1 ip4:10.1.0.0/24 -all" },
    ["b.lan"] = { "v=spf1 a mx ~all" },
    ["c.lan"] = { "v=spf1 include:a.lan -all" },
    ["d.lan"] = { "v=spf1 redirect=a.lan" },
    ["e.lan"] = { "v=spf1 exists:%{i}.allow.e.lan -all" },
    ["f.lan"] = { "v=spf1 -all", "v=spf1 +all" },
    ["g.lan"] = { "v=spf1 ?all" },
    ["h.lan"] = { "v=spf1 ip6:::1 ptr a:other.lan/28 +all" },
    ["loop.lan"] = { "v=spf1 include:loop.lan -all" },
    ["bad.lan"] = { "v=spf1 frobnicate -all" },
    ["x.lan"] = { "some other text" },
    ["many.lan"] = { "v=spf1 a a a a a a a a a a a -all" },
    ["bounce.lan"] = { "v=spf1 ip4:10.5.5.5 -all" },
  }
  local a = { ["b.lan"] = { "10.2.0.5" }, ["mail.b.lan"] = { "10.2.0.9" }, ["10.1.0.5.allow.e.lan"] = { "127.0.0.2" }, ["other.lan"] = { "10.7.0.16" }, ["many.lan"] = { "10.9.9.9" } }
  local mx = { ["b.lan"] = { { preference = 10, exchange = "mail.b.lan" } } }
  local m = fakeMail(txt, a, mx)
  local function check(ip, sender, helo) return (spf.check(m, ip, helo or "client.lan", sender)) end
  eq(check("10.1.0.7", "u@a.lan"), "pass")
  eq(check("10.9.9.9", "u@a.lan"), "fail")
  eq(check("10.2.0.5", "u@b.lan"), "pass", "a")
  eq(check("10.2.0.9", "u@b.lan"), "pass", "mx")
  eq(check("10.2.0.77", "u@b.lan"), "softfail")
  eq(check("10.1.0.1", "u@c.lan"), "pass", "include that passes")
  eq(check("10.8.8.8", "u@c.lan"), "fail", "include that does not match continues")
  eq(check("10.1.0.1", "u@d.lan"), "pass", "redirect")
  eq(check("10.8.8.8", "u@d.lan"), "fail")
  eq(check("10.1.0.5", "u@e.lan"), "pass", "exists with a macro")
  eq(check("10.1.0.6", "u@e.lan"), "fail")
  eq(check("10.1.1.1", "u@f.lan"), "permerror", "two records")
  eq(check("10.1.1.1", "u@g.lan"), "neutral")
  eq(check("10.7.0.20", "u@h.lan"), "pass", "ip6 and ptr are ignored; a with a mask")
  eq(check("10.1.1.1", "u@nothing.lan"), "none")
  eq(check("10.1.1.1", "u@x.lan"), "none")
  eq(check("10.1.1.1", "u@loop.lan"), "permerror", "include loop")
  eq(check("10.1.1.1", "u@bad.lan"), "permerror", "unknown term")
  eq(check("10.1.1.1", "u@many.lan"), "permerror", "more than 10 lookups")
  eq(check("10.5.5.5", "", "bounce.lan"), "pass", "a bounce is checked by the HELO name")
  eq(check("not an ip", "u@a.lan"), "permerror")
  local broken = fakeMail(false)
  eq(check and spf.check(broken, "10.1.0.7", "c", "u@a.lan"), "temperror", "DNS down is a temporary error")
end)

local SEED = string.rep("k", 32)
local function sampleMail(extra)
  return msg.build({ from = "Alice <alice@example.lan>", to = "bob@other.lan", subject = "Hello  there", body = "line one\nline two  with   spaces\n", host = "example.lan", date = 1700000000000,
    messageId = "<fixed@example.lan>", headers = extra })
end

test("DKIM: sign, verify, tampering, canonicalisation, keys, expiry", function()
  local txt = { ["mail1._domainkey.example.lan"] = { dkim.dnsRecord(SEED) } }
  local m = fakeMail(txt)
  ok(dkim.dnsRecord(SEED):find("^v=DKIM1; k=ed25519; p=[%w+/=]+$"))
  local signed = assert(dkim.sign(sampleMail(), { domain = "example.lan", selector = "mail1", seed = SEED, now = 1000000 }))
  ok(signed:gsub("\r\n\t", " "):find("^DKIM%-Signature: v=1; a=ed25519%-sha256; c=relaxed/relaxed; d=example.lan; s=mail1; t=1000000;"), signed:sub(1, 200))
  local r, d, why = dkim.verify(m, signed)
  eq({ r, d }, { "pass", "example.lan" }, tostring(why))
  -- no signature
  eq((dkim.verify(m, sampleMail())), "none")
  -- the body changed
  local r2, _, w2 = dkim.verify(m, (signed:gsub("line one", "line 1")))
  eq(r2, "fail") ok(w2:find("body hash", 1, true), w2)
  -- a signed header changed
  eq((dkim.verify(m, (signed:gsub("Hello  there", "Different")))), "fail")
  eq((dkim.verify(m, (signed:gsub("bob@other.lan", "eve@other.lan")))), "fail")
  -- an unsigned header may change or be added (Received, X-Spam)
  eq((dkim.verify(m, "Received: from x\r\nX-Anything: 1\r\n" .. signed)), "pass")
  -- whitespace changes that relaxed canonicalisation ignores
  local spaced = signed:gsub("Hello  there", "Hello \t there"):gsub("line two  with   spaces", "line two with spaces  ")
  eq((dkim.verify(m, spaced)), "pass")
  local folded = signed:gsub("Subject: Hello  there", "Subject: Hello\r\n there")
  eq((dkim.verify(m, folded)), "pass", "folding is ignored")
  -- trailing empty lines of the body are ignored
  eq((dkim.verify(m, signed .. "\r\n\r\n")), "pass")
  -- the wrong key is published
  local other = fakeMail({ ["mail1._domainkey.example.lan"] = { dkim.dnsRecord(string.rep("z", 32)) } })
  eq((dkim.verify(other, signed)), "fail")
  -- no key / key lookup failing
  eq((dkim.verify(fakeMail({}), signed)), "permerror")
  eq((dkim.verify(fakeMail(false), signed)), "temperror")
  -- a revoked key (empty p=)
  eq((dkim.verify(fakeMail({ ["mail1._domainkey.example.lan"] = { "v=DKIM1; k=ed25519; p=" } }), signed)), "permerror")
  -- expiry
  local short = assert(dkim.sign(sampleMail(), { domain = "example.lan", selector = "mail1", seed = SEED, now = 1000000, expires = 100 }))
  eq((dkim.verify(m, short)), "pass")
  local late = fakeMail(txt, nil, nil, { now = function() return 1000200 end })
  local rl, _, wl = dkim.verify(late, short)
  eq(rl, "fail") ok(wl:find("expired", 1, true), wl)
  -- the From header has to be signed
  local nofrom = signed:gsub("h=from:", "h=")
  eq((dkim.verify(m, nofrom)), "permerror")
  -- a message without From cannot be signed
  ok(dkim.sign("Subject: x\r\n\r\nbody", { domain = "example.lan", selector = "mail1", seed = SEED, now = 1 }) == nil)
  -- several signatures: one good one is enough; headers are signed bottom-up
  local twice = assert(dkim.sign(signed, { domain = "example.lan", selector = "mail1", seed = SEED, now = 1000001 }))
  eq((dkim.verify(m, twice)), "pass")
  local dup = msg.build({ from = "a@example.lan", to = "b@o.lan", subject = "s", body = "b", host = "example.lan", date = 1700000000000, messageId = "<m@e>", headers = { Received = "from a" } })
  local sd = assert(dkim.sign(dup, { domain = "example.lan", selector = "mail1", seed = SEED, now = 5, headers = { "from", "received", "received", "to" } }))
  eq((dkim.verify(m, sd)), "pass")
end)

test("DMARC: alignment, policies, subdomains, strict mode", function()
  local txt = {
    ["_dmarc.example.lan"] = { "v=DMARC1; p=reject; sp=quarantine" },
    ["_dmarc.strict.lan"] = { "v=DMARC1; p=quarantine; adkim=s; aspf=s" },
    ["_dmarc.none.lan"] = { "v=DMARC1; p=none" },
    ["_dmarc.half.lan"] = { "v=DMARC1; p=reject; pct=0" },
  }
  local m = fakeMail(txt)
  local fail, none = { result = "fail" }, { result = "none" }
  local r = dmarc.check(m, "example.lan", { result = "pass", domain = "example.lan" }, none)
  eq({ r.result, r.policy, r.apply }, { "pass", "reject", false })
  r = dmarc.check(m, "example.lan", { result = "pass", domain = "bounce.other.lan" }, none)
  eq({ r.result, r.policy, r.apply }, { "fail", "reject", true }, "SPF passed for another domain: not aligned")
  r = dmarc.check(m, "example.lan", fail, { result = "pass", domain = "mail.example.lan" })
  eq(r.result, "pass", "a DKIM signature of a subdomain is aligned (relaxed)")
  r = dmarc.check(m, "news.example.lan", fail, none)
  eq({ r.result, r.policy }, { "fail", "quarantine" }, "the subdomain policy")
  r = dmarc.check(m, "strict.lan", { result = "pass", domain = "mail.strict.lan" }, none)
  eq(r.result, "fail", "strict alignment wants the same domain")
  r = dmarc.check(m, "strict.lan", { result = "pass", domain = "strict.lan" }, none)
  eq(r.result, "pass")
  r = dmarc.check(m, "none.lan", fail, none)
  eq({ r.result, r.policy, r.apply }, { "fail", "none", false }, "a policy of none only reports")
  r = dmarc.check(m, "half.lan", fail, none)
  eq({ r.result, r.apply }, { "fail", false }, "pct=0 applies to nobody")
  r = dmarc.check(m, "nodmarc.lan", fail, none)
  eq(r.result, "none")
  eq(dmarc.check(fakeMail(false), "example.lan", fail, none).result, "temperror")
  eq(dmarc.orgDomain("a.b.example.lan"), "example.lan") eq(dmarc.orgDomain("example.lan"), "example.lan")
end)

test("blocklists in DNS", function()
  local m = fakeMail({}, { ["5.0.0.10.bl.example.lan"] = { "127.0.0.2" }, ["5.0.0.10.other.lan"] = { "10.0.0.1" }, ["scam.lan.uribl.lan"] = { "127.0.0.9" } })
  local hits = dnsbl.check(m, "10.0.0.5", { { zone = "bl.example.lan", score = 4 }, "other.lan", "none.lan" })
  eq(#hits, 1) eq(hits[1].zone, "bl.example.lan") eq(hits[1].score, 4) eq(hits[1].code, "127.0.0.2")
  eq(#dnsbl.check(m, "10.0.0.6", { "bl.example.lan" }), 0)
  eq(#dnsbl.check(m, "garbage", { "bl.example.lan" }), 0)
  eq(#dnsbl.checkDomain(m, "scam.lan", { "uribl.lan" }), 1)
  eq(dnsbl.reversed("10.0.0.5"), "5.0.0.10")
end)

test("the learning filter", function()
  clean()
  local path = ROOT .. "/bayes.lua"
  local b = bayes.new(path)
  local function mk(subject, body, from) return msg.build({ from = from or "x@y.lan", to = "alice@example.lan", subject = subject, body = body, host = "y.lan" }) end
  local p, why = b:classify(mk("hello", "world"))
  ok(p == nil and why:find("not trained"), tostring(why))
  local spams = { "cheap pills viagra buy now", "buy cheap pills now limited offer", "win free money now click", "free money click here winner", "cheap viagra winner offer" }
  local hams = { "meeting tomorrow about the redstone clock", "the turbine design is ready for review", "can you review my quarry turtle code", "lunch at the base tomorrow", "redstone meeting notes attached" }
  for _, t in ipairs(spams) do b:train(mk("offer", t, "spam@bad.lan"), true) end
  for _, t in ipairs(hams) do b:train(mk("notes", t, "friend@good.lan"), false) end
  local ps = assert(b:classify(mk("offer", "free pills winner click now", "spam@bad.lan")))
  local ph = assert(b:classify(mk("notes", "review the redstone turbine design tomorrow", "friend@good.lan")))
  ok(ps > 0.9, "spam scored " .. ps)
  ok(ph < 0.1, "ham scored " .. ph)
  eq(select(1, b:classify(mk("zzz", "qqq xxx", "nobody@nowhere.lan"))) > 0.2 and select(1, b:classify(mk("zzz", "qqq xxx", "nobody@nowhere.lan"))) < 0.8, true, "unknown words are undecided")
  -- saved and loaded again
  ok(b:save())
  local b2 = bayes.new(path)
  local s, h = b2:learned()
  eq({ s, h }, { 5, 5 })
  near = math.abs(b2:classify(mk("offer", "free pills winner click now", "spam@bad.lan")) - ps)
  ok(near < 1e-9)
  -- taking a training back
  b2:untrain(mk("offer", spams[1], "spam@bad.lan"), true)
  eq(select(1, b2:learned()), 4)
  -- the table stays small
  local small = bayes.new(nil, { maxTokens = 50 })
  for i = 1, 40 do small:train(mk("s" .. i, "word" .. i .. " token" .. i .. " another" .. i .. " thing" .. i, "u" .. i .. "@d.lan"), i % 2 == 0) end
  local n = 0
  for _ in pairs(small.tokens) do n = n + 1 end
  ok(n <= 50, "tokens: " .. n)
end)

test("greylisting: delay, retry, trust, allow list", function()
  local m, sim = fakeMail({})
  local g = spam.greylist.new(m, { delay = 100, window = 1000, trustAfter = 2, allow = { "friends.lan" } })
  local r = g:check("10.9.0.5", "a@far.lan", "alice@example.lan")
  eq(r[1], 451) ok(r[2]:find("try again in 100 seconds", 1, true))
  sim.now = sim.now + 50
  r = g:check("10.9.0.5", "a@far.lan", "alice@example.lan")
  eq(r[1], 451) ok(r[2]:find("50 seconds", 1, true), r[2])
  -- another address of the same network is a new triplet
  eq(g:check("10.9.0.6", "a@far.lan", "bob@example.lan")[1], 451)
  sim.now = sim.now + 60
  eq(g:check("10.9.0.7", "a@far.lan", "alice@example.lan"), nil, "the same /24 network counts")
  eq(g:check("10.9.0.5", "a@far.lan", "alice@example.lan"), nil, "remembered")
  -- after two passed triplets the network is trusted
  g:check("10.9.0.5", "b@far.lan", "alice@example.lan")
  sim.now = sim.now + 101
  eq(g:check("10.9.0.5", "b@far.lan", "alice@example.lan"), nil)
  eq(g:check("10.9.0.99", "new@far.lan", "zed@example.lan"), nil, "trusted network: no delay")
  -- a different network starts again
  eq(g:check("10.77.0.1", "a@far.lan", "alice@example.lan")[1], 451)
  -- too late: the first attempt is forgotten and the clock starts again
  sim.now = sim.now + 5000
  eq(g:check("10.77.0.1", "a@far.lan", "alice@example.lan")[1], 451)
  -- allow list
  eq(g:check("10.88.0.1", "x@friends.lan", "alice@example.lan"), nil)
  eq(g:check("10.88.0.1", "x@sub.far.lan", "alice@example.lan")[1], 451)
  ok(g.stats.delayed >= 5 and g.stats.passed >= 4)
end)

local function mailFrom(sender, subject, body, opts)
  opts = opts or {}
  return msg.build({ from = opts.from or sender, to = "alice@example.lan", subject = subject, body = body, host = "far.lan", attachments = opts.attachments, headers = opts.headers })
end

test("the anti-spam pipeline: headers, scores, lists and verdicts", function()
  local txt = {
    ["good.lan"] = { "v=spf1 ip4:10.8.0.0/24 -all" },
    ["signed.lan"] = { "v=spf1 -all" },
    ["_dmarc.signed.lan"] = { "v=DMARC1; p=reject" },
    ["sel._domainkey.signed.lan"] = { dkim.dnsRecord(SEED) },
    ["_dmarc.strict.lan"] = { "v=DMARC1; p=reject" },
    ["strict.lan"] = { "v=spf1 ip4:10.4.4.4 -all" },
  }
  local m = fakeMail(txt, { ["7.0.8.10.bl.lan"] = { "127.0.0.2" } })
  local S = spam.install(m, { bayes = false, dnsbl = { { zone = "bl.lan", score = 4 } }, deny = { "banned.lan" }, allow = { "vip@odd.lan" }, spamAt = 5, rejectAt = 12 })
  local function judge(raw, ip, sender, helo) local v, ctx = S:test(raw, { ip = ip, sender = sender, helo = helo or "client.lan" }) return v, ctx end
  -- an ordinary message from a server that SPF allows
  local v, ctx = judge(mailFrom("bob@good.lan", "Meeting", "See you at the base at noon."), "10.8.0.5", "bob@good.lan")
  eq(v[1], "accept")
  local joined = table.concat(ctx.add, "\n")
  ok(joined:find("Authentication-Results: mx.example.lan; spf=pass smtp.mailfrom=bob@good.lan; dkim=none; dmarc=none header.from=good.lan", 1, true), joined)
  ok(joined:find("X-Spam-Status: No, score=-0.5 required=5.0 tests=SPF_PASS=-0.5", 1, true), joined)
  -- trusted clients are not judged
  m.relayNets = { { require("tsr.inet.bytes").ip("10.8.0.0"), 24 } }
  local vt, ct = judge(mailFrom("bob@good.lan", "FREE MONEY!!!", "x"), "10.8.0.9", "x@y.lan")
  eq(vt[1], "accept") eq(#ct.add, 0) ok(ct.results.trusted)
  m.relayNets = {}
  -- spammy content scores into the spam folder
  local junk = mailFrom("prize@lottery.lan", "YOU HAVE WON $1000000!!!", "<p>Click here http://10.1.2.3/claim for your free money wire transfer</p>", { headers = { ["Content-Type"] = "text/html" } })
  local vs, cs = judge(junk, "10.3.3.3", "prize@lottery.lan")
  eq(vs[1], "spam")
  ok(vs[3] >= 5 and vs[3] < 12, tostring(vs[3]))
  ok(vs[2]:find("SUBJECT_SHOUTING", 1, true) and vs[2]:find("BAD_WORDS", 1, true) and vs[2]:find("RAW_IP_LINK", 1, true) and vs[2]:find("SUBJECT_DOLLARS", 1, true), vs[2])
  local spamHeaders = table.concat(cs.add, "\n")
  ok(spamHeaders:find("X-Spam-Status: Yes", 1, true) and spamHeaders:find("X-Spam-Level: *****", 1, true), spamHeaders)
  -- worse: a blocklisted sender with a dangerous attachment is refused outright
  local worse = mailFrom("prize@lottery.lan", "YOU HAVE WON $1000000!!!", "<p>Click here http://10.1.2.3/claim for your free money wire transfer</p>",
    { headers = { ["Content-Type"] = "text/html" }, attachments = { { name = "invoice.pdf.exe", data = "MZ", type = "application/octet-stream" } } })
  local vw = judge(worse, "10.8.0.7", "prize@lottery.lan")
  eq(vw[1], "reject") eq(vw[2], 554) ok(vw[3]:find("rejected as spam", 1, true), vw[3])
  -- the administrator's lists
  eq(judge(mailFrom("x@banned.lan", "hi", "hello there"), "10.3.3.4", "x@banned.lan")[1], "reject")
  eq(judge(mailFrom("a@sub.banned.lan", "hi", "hello there"), "10.3.3.4", "a@sub.banned.lan")[1], "reject", "subdomains of a denied domain")
  eq(judge(junk:gsub("lottery.lan", "odd.lan"):gsub("prize@", "vip@"), "10.3.3.3", "vip@odd.lan")[1], "accept", "allowed addresses skip the checks")
  -- DMARC reject: a forged From of a domain that publishes p=reject
  local forged = mailFrom("x@evil.lan", "Account", "Please verify", { from = "Boss <boss@strict.lan>" })
  local vf = judge(forged, "10.9.9.9", "x@evil.lan")
  eq(vf[1], "reject") eq(vf[2], 550) ok(vf[3]:find("DMARC", 1, true), vf[3])
  -- a signed message passes DMARC through DKIM even from an address SPF does not know
  local signed = assert(dkim.sign(mailFrom("a@signed.lan", "Signed", "A real message from the domain."), { domain = "signed.lan", selector = "sel", seed = SEED, now = 1000000 }))
  local vg, cg = judge(signed, "10.5.5.5", "a@signed.lan")
  eq(vg[1], "accept")
  ok(table.concat(cg.add, "\n"):find("spf=fail", 1, true) and table.concat(cg.add, "\n"):find("dkim=pass header.d=signed.lan", 1, true) and table.concat(cg.add, "\n"):find("dmarc=pass", 1, true), table.concat(cg.add, "\n"))
  -- blocklisted address alone is a few points, not a verdict
  local vb, cb = judge(mailFrom("p@good.lan", "Meeting", "Please read the attached notes about redstone."), "10.8.0.7", "p@good.lan")
  eq(vb[1], "accept")
  ok(table.concat(cb.add, "\n"):find("DNSBL_BL_LAN=4.0", 1, true))
  -- the learning filter changes scores once it has been taught
  local S2 = spam.install(m, { bayes = ROOT .. "/b2.lua", spamAt = 5, rejectAt = 12 })
  for i = 1, 4 do
    S2:learn(mailFrom("s@bad.lan", "offer " .. i, "cheap pills winner free click"), true)
    S2:learn(mailFrom("f@good.lan", "notes " .. i, "redstone turbine meeting tomorrow review"), false)
  end
  local v1, c1 = judge(mailFrom("s@bad.lan", "offer", "cheap pills winner free click now"), "10.3.3.9", "s@bad.lan")
  ok(table.concat(c1.add, "\n"):find("BAYES_SPAM=5.0", 1, true), table.concat(c1.add, "\n"))
  local v2, c2 = judge(mailFrom("f@good.lan", "notes", "redstone turbine review meeting"), "10.8.0.5", "f@good.lan")
  ok(table.concat(c2.add, "\n"):find("BAYES_HAM=%-2.5"), table.concat(c2.add, "\n"))
end)

--- Two servers on a simulated LAN with the anti-spam checks on the second one.
local function world(txt, spamCfg)
  clean()
  local sim = Sim.new()
  local seg = sim:segment("lan")
  local function server(name, ip, cfg, users)
    local h = sim:host(name)
    sim:plug(h, "eth0", seg, ip .. "/24")
    cfg.hostname = name .. ".lan"
    cfg.root, cfg.users, cfg.queueDir = ROOT .. "/" .. name .. "/mb", ROOT .. "/" .. name .. "/users.db", ROOT .. "/" .. name .. "/queue"
    cfg.allowPlainAuth = true
    cfg.retryDelays = { 5, 10, 20 }
    cfg.now = function() return 1000000 + sim.now end
    cfg.dnsTxt = function(name2) return txt[name2] or {} end
    cfg.dnsA = function() return {} end
    cfg.dnsMx = function() return {} end
    local st = storeMod.new({ root = cfg.root, users = cfg.users, iterations = 3 })
    for _, u in ipairs(users) do assert(st:addUser(u, "password-" .. u)) end
    return h, mailMod.new(h, cfg, st)
  end
  local h1, m1 = server("mx1", "10.0.0.1", { domains = { "example.lan" }, relayNetworks = { "10.0.0.0/24" } }, { "alice" })
  local h2, m2 = server("mx2", "10.0.0.2", { domains = { "other.lan" }, relayNetworks = {} }, { "carol" })
  local pc = sim:host("pc")
  sim:plug(pc, "eth0", seg, "10.0.0.9/24")
  local resolve = function(domain) if domain == "example.lan" then return { "10.0.0.1" } elseif domain == "other.lan" then return { "10.0.0.2" } end return nil, "no such domain" end
  m1.resolveMx, m2.resolveMx = resolve, resolve
  for _, m in ipairs({ m1, m2 }) do
    for _, job in ipairs(assert(smtpd.workers(m, 2))) do local t = sim:spawn(job) t.daemon = true end
  end
  local S1 = spam.install(m1, { bayes = false, dkim = { ["example.lan"] = { selector = "mail1", seed = SEED } } })
  local S2 = spam.install(m2, spamCfg)
  sim:run(0.2)
  return sim, { m1 = m1, m2 = m2, pc = pc, S1 = S1, S2 = S2 }
end

test("mail between servers with greylisting, SPF, DKIM and DMARC", function()
  local txt = {
    ["example.lan"] = { "v=spf1 ip4:10.0.0.1 -all" },
    ["_dmarc.example.lan"] = { "v=DMARC1; p=reject" },
    ["mail1._domainkey.example.lan"] = { dkim.dnsRecord(SEED) },
  }
  local sim, w = world(txt, { bayes = false, greylist = { delay = 20, trustAfter = 100 } })
  local function submit()
    return smtp.deliver(w.pc, "10.0.0.1", { from = "alice@example.lan", rcpts = { "carol@other.lan" }, helo = "pc.lan", port = 587, auth = { user = "alice", pass = "password-alice" },
      data = msg.build({ from = "Alice <alice@example.lan>", to = "carol@other.lan", subject = "Greylisted hello", body = "Hello across the LAN", host = "example.lan" }) })
  end
  local first = submit()
  ok(first.ok, tostring(first.error) .. " " .. tostring(first.rejected["carol@other.lan"] and first.rejected["carol@other.lan"].text))
  -- the first attempt is told to come back
  local q = w.m1:queueList()
  eq(#q, 1) eq(q[1].tries, 1) ok(q[1].last:find("Greylisted", 1, true), tostring(q[1].last))
  eq(#w.m2.store:list("carol"), 0)
  -- retries before the delay are refused again; after it the mail is accepted
  sim:run(6) w.m1:processQueue(false)
  eq(#w.m2.store:list("carol"), 0)
  for _ = 1, 8 do
    sim:run(12)
    w.m1:processQueue(false)
    if #w.m2.store:list("carol") > 0 then break end
  end
  eq(#w.m2.store:list("carol"), 1, "delivered after the greylist delay")
  eq(#w.m1:queueList(), 0)
  local raw = w.m2.store:get("carol", "INBOX", 1)
  ok(raw:find("Authentication-Results: mx2.lan; spf=pass smtp.mailfrom=alice@example.lan; dkim=pass header.d=example.lan; dmarc=pass header.from=example.lan", 1, true), raw:sub(1, 900))
  ok(raw:find("X-Spam-Status: No", 1, true) and raw:find("DKIM-Signature:", 1, true))
  eq(w.S2.greylist.stats.delayed >= 2, true)
end)

test("mail between servers: forgeries are refused, junk goes to the Spam folder", function()
  local txt = {
    ["example.lan"] = { "v=spf1 ip4:10.0.0.1 -all" },
    ["_dmarc.example.lan"] = { "v=DMARC1; p=reject" },
    ["mail1._domainkey.example.lan"] = { dkim.dnsRecord(SEED) },
  }
  local sim, w = world(txt, { bayes = false })
  -- the pc is not example.lan's server: SPF fails and the DKIM signature is missing -> refused by the domain's own DMARC policy
  local forged = smtp.deliver(w.pc, "10.0.0.2", { from = "alice@example.lan", rcpts = { "carol@other.lan" }, helo = "pc.lan", port = 25,
    data = msg.build({ from = "alice@example.lan", to = "carol@other.lan", subject = "Hello", body = "I am Alice, really", host = "pc.lan" }) })
  ok(not forged.ok and not forged.tempfail, tostring(forged.error))
  ok(forged.error:find("DMARC", 1, true), tostring(forged.error))
  eq(#w.m2.store:list("carol"), 0)
  -- junk from a domain without any policy lands in the Spam folder
  local junk = smtp.deliver(w.pc, "10.0.0.2", { from = "prize@lottery.lan", rcpts = { "carol@other.lan" }, helo = "pc.lan", port = 25,
    data = msg.build({ from = "prize@lottery.lan", to = "carol@other.lan", subject = "YOU HAVE WON $1000000!!!", body = "Click here: free money, wire transfer, claim your prize http://10.1.2.3/x", host = "lottery.lan" }) })
  ok(junk.ok, tostring(junk.error))
  eq(#w.m2.store:list("carol"), 0)
  local sp = w.m2.store:list("carol", "Spam")
  eq(#sp, 1)
  ok(w.m2.store:get("carol", "Spam", sp[1].uid):find("X-Spam-Flag: YES", 1, true))
  eq(w.m2.stats.spam, 1)
  -- mail from the signing server arrives intact and signed
  local good = smtp.deliver(w.pc, "10.0.0.1", { from = "alice@example.lan", rcpts = { "carol@other.lan" }, helo = "pc.lan", port = 587, auth = { user = "alice", pass = "password-alice" },
    data = msg.build({ from = "alice@example.lan", to = "carol@other.lan", subject = "Hello", body = "A normal note", host = "example.lan" }) })
  ok(good.ok)
  sim:run(1)
  eq(#w.m2.store:list("carol"), 1)
end)

test("DKIM keys on disk", function()
  clean()
  local record, seed = spam.makeDkimKey(ROOT .. "/dkim/mail1.key")
  ok(record:find("^v=DKIM1; k=ed25519; p="))
  eq(#seed, 32)
  eq(spam.loadDkimKey(ROOT .. "/dkim/mail1.key"), seed)
  ok(spam.loadDkimKey(ROOT .. "/dkim/none.key") == nil)
  eq(record, dkim.dnsRecord(seed))
end)
