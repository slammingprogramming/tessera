-- SPDX-License-Identifier: AGPL-3.0-or-later
-- fetch [-o file] [-I] [-X METHOD] [-d data] [-H "Name: value"] [-u user:password] [-L|--no-follow] [-v] <url>
-- Gets a page from the in-game web: prints the body (or saves it with -o). -I shows only the response headers, -v shows them with the body.
local client = require("tsr.inet.http.client")
local msg = require("tsr.inet.http.message")
local vfs = require("tsr.vfs")

local M = {}

function M.fetch(args, ctx)
  ctx = ctx or { say = print, err = print }
  local opts, url = { headers = {} }, nil
  local out, headOnly, verbose = nil, false, false
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "-o" then i = i + 1 out = args[i]
    elseif a == "-I" then headOnly = true opts.method = "HEAD"
    elseif a == "-X" then i = i + 1 opts.method = args[i]
    elseif a == "-d" then i = i + 1 opts.body = args[i] opts.method = opts.method or "POST"
    elseif a == "-H" then
      i = i + 1
      local k, v = tostring(args[i]):match("^([^:]+):%s*(.*)$")
      if k then opts.headers[k:lower()] = v end
    elseif a == "-u" then i = i + 1 opts.user, opts.password = tostring(args[i]):match("^([^:]*):?(.*)$")
    elseif a == "--no-follow" then opts.follow = false
    elseif a == "-v" then verbose = true
    else url = a end
    i = i + 1
  end
  if not url then ctx.err("usage: fetch [-o file] [-I] [-X METHOD] [-d data] [-H 'Name: value'] [-u user:password] [-v] <url>") return false end
  if not url:match("^%a[%w+.-]*://") then url = "http://" .. url end
  opts.url = url
  opts.stack = ctx.stack
  local r, err = client.request(opts)
  if not r then ctx.err("fetch: " .. tostring(err)) return false end
  if headOnly or verbose then
    ctx.say(("HTTP/%s %d %s"):format(r.version or "1.1", r.status, r.reason or ""))
    local names = {}
    for k in pairs(r.headers) do names[#names + 1] = k end
    table.sort(names)
    for _, k in ipairs(names) do ctx.say(k .. ": " .. r.headers[k]) end
    if headOnly then return r.status < 400 end
    ctx.say("")
  end
  if out then
    local ok, werr = vfs.writeFile(vfs.normalize(out), r.body, true)
    if not ok then ctx.err("fetch: cannot write " .. out .. ": " .. tostring(werr)) return false end
    ctx.say(("%d %s, %d bytes saved to %s"):format(r.status, r.reason or "", #r.body, out))
  else
    ctx.say(r.body)
  end
  return r.status < 400
end

function M.www(args)
  local www = require("tsr.inet.http.www")
  local ok, err = www.browse(args[1])
  if not ok and err then print(err) return false end
  return true
end

return M
