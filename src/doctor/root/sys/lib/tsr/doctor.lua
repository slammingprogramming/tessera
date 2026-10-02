-- SPDX-License-Identifier: AGPL-3.0-or-later
-- doctor: checks a Tessera computer from the inside and writes a report. It exists because most of this system was developed in an
-- emulator: run it in the real game (any ComputerCraft version) to find out what behaves differently, how fast the cryptography really is
-- on that server, and what is wrong, then send the report file to the project. The report never contains keys, passwords or user names.
--
--   doctor                 all checks (the benchmarks take a few seconds)
--   doctor --quick         skip the benchmarks and network checks
--   doctor --out <file>    where the report goes (default /var/log/doctor.txt)
--   doctor <check> ...     only the named checks (see `doctor --list`)
--
-- Each check returns "ok", "warn", "fail" or "skip" and a sentence of detail. A check that crashes is reported as a failure (with the error):
-- that is information too.
local M = {}

M.REPORT = "/var/log/doctor.txt"

local checks = {}
M.checks = checks

local function add(id, title, opts, fn)
  if type(opts) == "function" then fn, opts = opts, {} end
  checks[#checks + 1] = { id = id, title = title, slow = opts.slow, net = opts.net, fn = fn }
end

local function try(fn, ...)
  local ok, a, b, c = pcall(fn, ...)
  return ok, a, b, c
end

local function ms(f)
  local t = os.epoch and os.epoch("utc") or 0
  local c = os.clock()
  f()
  local dt = (os.epoch and os.epoch("utc") or 0) - t
  if dt <= 0 then dt = math.floor((os.clock() - c) * 1000) end
  return dt
end

---------------------------------------------------------------------------------------------------------------------
-- Environment
---------------------------------------------------------------------------------------------------------------------

add("host", "ComputerCraft and Minecraft version", function()
  local host = rawget(_G, "_HOST") or "unknown"
  local ver = os.version and os.version() or "?"
  local tess = rawget(_G, "tsr") and tsr.version and (tsr.version.name .. " " .. tsr.version.version) or "Tessera not running"
  return "ok", ("%s | %s | %s"):format(ver, host, tess)
end)

add("terminal", "terminal", function()
  local w, h = term.getSize()
  local color = term.isColor and term.isColor()
  return "ok", ("%dx%d, %s%s"):format(w, h, color and "colour" or "black and white", rawget(_G, "pocket") and ", pocket computer" or (rawget(_G, "turtle") and ", turtle" or ""))
end)

add("vm", "Lua VM behaviour that differs between emulators and the game", function()
  local notes, warn = {}, false
  local okFmt = pcall(string.format, "%d", 2 ^ 40)
  notes[#notes + 1] = "string.format('%d') of 2^40 " .. (okFmt and "works" or "errors (use %.0f: Tessera does)")
  notes[#notes + 1] = "bit32 " .. (rawget(_G, "bit32") and "present" or "MISSING")
  if not rawget(_G, "bit32") then warn = true end
  notes[#notes + 1] = "load " .. (rawget(_G, "load") and "present" or "MISSING")
  notes[#notes + 1] = "loadstring " .. (rawget(_G, "loadstring") and "present (not on CC:T)" or "absent (as CC:T)")
  notes[#notes + 1] = "string.pack " .. (string.pack and "present" or "absent")
  notes[#notes + 1] = "math.frexp " .. (math.frexp and "present" or "absent")
  local okCombine, combined = pcall(fs.combine, "/../x")
  notes[#notes + 1] = "fs.combine('/../x') = " .. tostring(okCombine and combined)
  local label = (function(...) return select("#", ...) end)(os.getComputerLabel())
  notes[#notes + 1] = "getComputerLabel returns " .. label .. " value(s) when unset"
  local escape = rawget(_G, "keys") and keys.escape
  notes[#notes + 1] = "keys.escape = " .. tostring(escape)
  if not (math.frexp and rawget(_G, "bit32")) then warn = true end
  return warn and "warn" or "ok", table.concat(notes, "; ")
end)

add("disk", "disk space", function()
  local free = fs.getFreeSpace("/")
  local capacity = fs.getCapacity and fs.getCapacity("/") or nil
  if type(free) ~= "number" then return "warn", "free space is reported as " .. tostring(free) end
  local text = ("%.0f bytes free"):format(free) .. (capacity and (" of " .. ("%.0f"):format(capacity)) or "")
  if free < 50000 then return "fail", text .. " - almost full" end
  if free < 200000 then return "warn", text end
  return "ok", text
end)

add("http", "HTTP access", { net = true }, function()
  if not rawget(_G, "http") then return "warn", "HTTP is disabled on this computer/server (use a LAN mirror or an offline bundle)" end
  local okCheck, why = http.checkURL("https://example.com")
  if not okCheck then return "warn", "HTTP is on but blocked for the web: " .. tostring(why) end
  return "ok", "enabled; the server allows outside web addresses"
end)

add("peripherals", "peripherals", function()
  local names = peripheral.getNames()
  local kinds = {}
  for _, n in ipairs(names) do
    local t = peripheral.getType(n)
    kinds[t] = (kinds[t] or 0) + 1
  end
  local parts = {}
  for t, c in pairs(kinds) do parts[#parts + 1] = t .. (c > 1 and (" x" .. c) or "") end
  table.sort(parts)
  return "ok", #names == 0 and "none attached" or table.concat(parts, ", ")
end)

---------------------------------------------------------------------------------------------------------------------
-- Cryptography: known answers and real speed
---------------------------------------------------------------------------------------------------------------------

add("crypto", "cryptography known-answer tests", function()
  local ok, crypto = pcall(require, "tsr.crypto")
  if not ok then return "skip", "the crypto package is not installed" end
  local bad = {}
  local function expect(name, got, want) if got ~= want then bad[#bad + 1] = name end end
  expect("sha512", crypto.sha512.hex("abc"):sub(1, 32), "ddaf35a193617abacc417349ae204131")
  expect("sha256", crypto.toHex(crypto.kdf.sha256("abc")):sub(1, 32), "ba7816bf8f01cfea414140de5dae2223")
  local key = crypto.fromHex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b")
  expect("poly1305", crypto.toHex(crypto.chacha.poly1305(key, "Cryptographic Forum Research Group")), "a8061dc1305136c6c22b8baf0c0127a9")
  local a = crypto.fromHex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
  expect("x25519", crypto.toHex(crypto.x25519.publicKey(a)), "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
  local seed = crypto.fromHex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
  local pub = crypto.ed25519.publicKey(seed)
  expect("ed25519 key", crypto.toHex(pub), "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
  local sig = crypto.ed25519.sign(seed, "")
  expect("ed25519 signature", crypto.toHex(sig):sub(1, 32), "e5564300c360ac729086e2cc806e828a")
  if not crypto.ed25519.verify(pub, "", sig) then bad[#bad + 1] = "ed25519 verify" end
  if #bad > 0 then return "fail", "WRONG results for: " .. table.concat(bad, ", ") .. " (this VM computes arithmetic differently!)" end
  return "ok", "SHA-256, SHA-512, Poly1305, X25519 and Ed25519 give the published answers"
end)

add("crypto-speed", "cryptography speed on this server", { slow = true }, function()
  local ok, crypto = pcall(require, "tsr.crypto")
  if not ok then return "skip", "the crypto package is not installed" end
  local seed = string.rep("\1", 32)
  local pub = crypto.ed25519.publicKey(seed)
  local sig = crypto.ed25519.sign(seed, "bench")
  local data = string.rep("x", 8192)
  local t = {
    verify = ms(function() crypto.ed25519.verify(pub, "bench", sig) end),
    sign = ms(function() crypto.ed25519.sign(seed, "bench") end),
    x25519 = ms(function() crypto.x25519.shared(seed, crypto.x25519.publicKey(string.rep("\2", 32))) end),
    sha256 = ms(function() crypto.kdf.sha256(data) end),
    chacha = ms(function() crypto.chacha.seal(seed, string.rep("\0", 12), data, "") end),
  }
  local text = ("Ed25519 verify %d ms, sign %d ms, X25519 key exchange %d ms (two multiplications), SHA-256 of 8 KB %d ms, ChaCha20-Poly1305 of 8 KB %d ms"):format(
    t.verify, t.sign, t.x25519, t.sha256, t.chacha)
  if t.verify > 20000 then return "fail", text .. " - far too slow for signature checking" end
  if t.verify > 5000 then return "warn", text .. " - slow, but usable" end
  return "ok", text
end)

---------------------------------------------------------------------------------------------------------------------
-- Tessera itself
---------------------------------------------------------------------------------------------------------------------

add("tessera", "Tessera boot state", function()
  if not rawget(_G, "tsr") then return "warn", "Tessera is not the running system (stage 0 skipped, disabled, or not installed)" end
  local parts = {}
  local okCfg, config = pcall(require, "tsr.config")
  if okCfg and config.problems and #config.problems > 0 then
    return "warn", #config.problems .. " damaged configuration file(s) were ignored at boot (see *.damaged)"
  end
  local h = fs.open("/var/lib/tsr/boot.count", "r")
  local count = h and tonumber(h.readAll()) or 0
  if h then h.close() end
  if count and count >= 2 then return "warn", "the boot counter is " .. count .. ": recent boots did not finish (3 in a row disables Tessera for one boot)" end
  parts[#parts + 1] = "profile " .. tostring(tsr.profile and tsr.profile() or "?")
  return "ok", table.concat(parts, ", ")
end)

add("packages", "installed files match their hashes", function()
  local ok, pkg = pcall(require, "tsr.pkg")
  if not ok then return "skip", "the package manager is not installed" end
  local problems = pkg.verify()
  local n = #pkg.list()
  if #problems == 0 then return "ok", n .. " package(s), every file matches" end
  local first = problems[1]
  return "fail", ("%d problem(s), e.g. %s: %s %s"):format(#problems, first.package, first.path, first.problem)
end)

add("signatures", "registry signatures", function()
  local ok, trust = pcall(require, "tsr.pkg.trust")
  if not ok then return "skip", "the package manager is not installed" end
  local policy = trust.policy()
  local keys = trust.list()
  if policy == "off" then return "warn", "no registry key is trusted: package descriptions are not signature-checked" end
  local names = {}
  for _, k in ipairs(keys) do names[#names + 1] = k.name end
  return "ok", ("policy %s, %d trusted key(s): %s"):format(policy, #keys, table.concat(names, ", "))
end)

add("registry", "reaching the package registry", { net = true }, function()
  local ok, source = pcall(require, "tsr.pkg.source")
  if not ok then return "skip", "the package manager is not installed" end
  local srcs = source.list()
  if #srcs == 0 then return "warn", "no package source is configured" end
  local lines, bad = {}, false
  for _, src in ipairs(srcs) do
    local idx, status = source.getIndex(src, true)
    if idx then
      local n = 0
      for _ in pairs(idx.packages or {}) do n = n + 1 end
      lines[#lines + 1] = ("%s: %d packages (%s)"):format(src.name, n, tostring(status))
    else
      bad = true
      lines[#lines + 1] = ("%s: %s"):format(src.name, tostring(status))
    end
  end
  return bad and "warn" or "ok", table.concat(lines, "; ")
end)

add("services", "services", function()
  local ok, svc = pcall(require, "tsr.svc")
  if not ok then return "skip", "the service manager is not installed" end
  local running, failed = 0, {}
  for _, st in ipairs(svc.list()) do
    if st.state == "running" then running = running + 1
    elseif st.state == "failed" or st.state == "crashed" then failed[#failed + 1] = st.name end
  end
  if #failed > 0 then return "warn", running .. " running; failed: " .. table.concat(failed, ", ") end
  return "ok", running .. " running, none failed"
end)

add("log", "errors in the system log", function()
  local h = fs.open("/var/log/tsr.log", "r")
  if not h then return "skip", "no log file" end
  local text = h.readAll() or ""
  h.close()
  local errors, warns, last = 0, 0, {}
  for line in text:gmatch("[^\n]+") do
    if line:find("[ERROR]", 1, true) then errors = errors + 1 last[#last + 1] = line
    elseif line:find("[WARN]", 1, true) then warns = warns + 1 end
  end
  while #last > 3 do table.remove(last, 1) end
  if errors > 0 then return "warn", ("%d error(s), %d warning(s); latest: %s"):format(errors, warns, table.concat(last, " | "):sub(1, 400)) end
  return "ok", ("no errors, %d warning(s)"):format(warns)
end)

add("time", "clock", function()
  local ok, time = pcall(require, "tsr.time")
  if not ok then return "skip", "the ntp package is not installed" end
  local s = time.state()
  return "ok", ("%s (zone %s, %s)"):format(time.stamp(time.now()), time.zoneName(), s.mode == "manual" and "set by hand" or (s.source and ("synced to " .. tostring(s.source)) or "host clock"))
end)

add("network", "network", { net = true }, function()
  local modems = {}
  for _, n in ipairs(peripheral.getNames()) do if peripheral.getType(n) == "modem" then modems[#modems + 1] = n end end
  if #modems == 0 then return "skip", "no modem attached" end
  local open = false
  for _, n in ipairs(modems) do if rednet.isOpen(n) then open = true end end
  local okNet, net = pcall(require, "tsr.net")
  if not okNet then return "ok", #modems .. " modem(s); the net package is not installed" end
  local node = net.default()
  local found = node:lookup(nil, 1)
  return "ok", ("%d modem(s)%s, %d computer(s) answered a broadcast"):format(#modems, open and " (open)" or " (closed)", #found)
end)

add("turtle", "turtle", function()
  if not rawget(_G, "turtle") then return "skip", "not a turtle" end
  local fuel = turtle.getFuelLevel()
  local parts = { "fuel " .. tostring(fuel) .. "/" .. tostring(turtle.getFuelLimit()) }
  parts[#parts + 1] = "crafting table " .. (turtle.craft and "equipped" or "not equipped")
  if fuel ~= "unlimited" and type(fuel) == "number" and fuel < 100 then return "warn", table.concat(parts, ", ") .. " - low fuel" end
  return "ok", table.concat(parts, ", ")
end)

---------------------------------------------------------------------------------------------------------------------
-- Running and reporting
---------------------------------------------------------------------------------------------------------------------

--- Run checks. opts: only (list of ids), quick (skip slow and network checks). Returns a list of { id, title, status, detail }.
function M.run(opts)
  opts = opts or {}
  local wanted
  if opts.only and #opts.only > 0 then wanted = {} for _, id in ipairs(opts.only) do wanted[id] = true end end
  local results = {}
  for _, c in ipairs(checks) do
    if (not wanted or wanted[c.id]) and not (opts.quick and (c.slow or c.net)) then
      local ok, status, detail = pcall(c.fn)
      if not ok then status, detail = "fail", "the check crashed: " .. tostring(status) end
      results[#results + 1] = { id = c.id, title = c.title, status = status or "skip", detail = tostring(detail or "") }
      if opts.onResult then opts.onResult(results[#results]) end
    end
  end
  return results
end

--- The report text: system line, one line per check, counts.
function M.report(results)
  local lines = { "Tessera doctor report", ("generated: %s"):format(os.date and os.date("%Y-%m-%d %H:%M:%S") or "?") }
  local counts = { ok = 0, warn = 0, fail = 0, skip = 0 }
  for _, r in ipairs(results) do
    counts[r.status] = (counts[r.status] or 0) + 1
    lines[#lines + 1] = ("[%s] %s: %s"):format(r.status:upper(), r.title, r.detail)
  end
  lines[#lines + 1] = ("summary: %d ok, %d warnings, %d failures, %d skipped"):format(counts.ok, counts.warn, counts.fail, counts.skip)
  return table.concat(lines, "\n") .. "\n", counts
end

function M.main(args, io)
  local color = function(c) if term.isColor and term.isColor() then term.setTextColor(c) end end
  io = io or {
    say = function(t, c) color(c or colors.white) print(t) color(colors.white) end,
  }
  local opts = { only = {} }
  local out = M.REPORT
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--quick" then opts.quick = true
    elseif a == "--out" then out = args[i + 1] i = i + 1
    elseif a == "--list" then
      for _, c in ipairs(checks) do io.say(("%-14s %s%s"):format(c.id, c.title, (c.slow and " (slow)" or "") .. (c.net and " (network)" or ""))) end
      return true
    else opts.only[#opts.only + 1] = a end
    i = i + 1
  end
  local shades = { ok = colors.lime, warn = colors.orange, fail = colors.red, skip = colors.lightGray }
  opts.onResult = function(r) io.say(("[%s] %s: %s"):format(r.status:upper(), r.title, r.detail), shades[r.status]) end
  local results = M.run(opts)
  local text, counts = M.report(results)
  local h = fs.open(out, "w")
  if h then h.write(text) h.close() io.say("Report written to " .. out .. " - send it along with any bug report.", colors.lightGray) end
  return counts.fail == 0
end

return M
