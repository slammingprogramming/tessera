-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Commands:
--   tar -c[z]f <archive> <paths...>     create (z = gzip)           tar -x[z]f <archive> [-C <folder>]   unpack (gzip is detected)
--   tar -t[z]f <archive>                list the contents           (flags combine like real tar: tar czf x.tgz /home)
--   gzip <file>   compress to <file>.gz (the original is kept with -k, otherwise removed)      gunzip <file.gz>   and   zcat <file.gz>
local tar = require("tsr.archive.tar")
local deflate = require("tsr.archive.deflate")
local vfs = require("tsr.vfs")

local M = {}

local function defaultIO()
  local io = {}
  function io.say(t) print(t) end
  function io.err(t) if term.isColor and term.isColor() then term.setTextColor(colors.red) end print(t) term.setTextColor(colors.white) end
  return io
end

local function resolve(path)
  if shell and shell.resolve then return "/" .. shell.resolve(path) end
  return vfs.normalize(path)
end

local function parseTarFlags(args)
  local mode, gz, file, dest, rest, keep = nil, false, nil, nil, {}, false
  local i = 1
  local first = true
  while i <= #args do
    local a = args[i]
    if (first or a:sub(1, 1) == "-") and a:match("^%-?[cxtzfv]+$") and not (a == "-C") then
      local letters = a:gsub("^%-", "")
      for ch in letters:gmatch(".") do
        if ch == "c" or ch == "x" or ch == "t" then mode = ch
        elseif ch == "z" then gz = true
        elseif ch == "f" then i = i + 1 file = args[i]
        end
      end
    elseif a == "-C" then
      i = i + 1
      dest = args[i]
    elseif a == "--gzip" then gz = true
    elseif a == "-k" then keep = true
    else rest[#rest + 1] = a end
    first = false
    i = i + 1
  end
  return mode, gz, file, dest, rest, keep
end

function M.tar(args, io)
  io = io or defaultIO()
  local mode, gz, file, dest, rest = parseTarFlags(args)
  if not mode or not file then io.err("usage: tar -c[z]f <archive> <paths...> | tar -x[z]f <archive> [-C <folder>] | tar -t[z]f <archive>") return false end
  file = resolve(file)
  if mode == "c" then
    if #rest == 0 then io.err("tar: nothing to archive") return false end
    local paths = {}
    for _, p in ipairs(rest) do paths[#paths + 1] = resolve(p) end
    local bytes, err = tar.create(paths, { gzip = gz })
    if not bytes then io.err("tar: " .. tostring(err)) return false end
    local ok, werr = vfs.writeFile(file, bytes, true)
    if not ok then io.err("tar: cannot write " .. file .. ": " .. tostring(werr)) return false end
    io.say(("%s: %d bytes"):format(file, #bytes))
    return true
  end
  local bytes = vfs.readFile(file, true)
  if not bytes then io.err("tar: cannot read " .. file) return false end
  if mode == "t" then
    local list, err = tar.list(bytes)
    if not list then io.err("tar: " .. tostring(err)) return false end
    for _, e in ipairs(list) do io.say(e.isDir and e.name or ("%s  (%d bytes)"):format(e.name, e.size)) end
    return true
  end
  local r, err = tar.extract(bytes, dest and resolve(dest) or resolve("."), { overwrite = false })
  if not r then io.err("tar: " .. tostring(err)) return false end
  io.say(("unpacked %d file(s) and %d folder(s)"):format(r.files, r.dirs))
  return true
end

function M.gzip(args, io)
  io = io or defaultIO()
  local keep, files = false, {}
  for _, a in ipairs(args) do if a == "-k" then keep = true else files[#files + 1] = a end end
  if #files == 0 then io.err("usage: gzip [-k] <file...>") return false end
  local all = true
  for _, f in ipairs(files) do
    local path = resolve(f)
    local data = vfs.readFile(path, true)
    if not data then io.err("gzip: cannot read " .. path) all = false
    else
      local out = deflate.gzip(data, { name = vfs.basename(path) })
      local ok, err = vfs.writeFile(path .. ".gz", out, true)
      if not ok then io.err("gzip: " .. tostring(err)) all = false
      else
        if not keep then vfs.fs.delete(path) end
        io.say(("%s.gz: %d -> %d bytes"):format(path, #data, #out))
      end
    end
  end
  return all
end

function M.gunzip(args, io, toScreen)
  io = io or defaultIO()
  local keep, files = false, {}
  for _, a in ipairs(args) do if a == "-k" then keep = true else files[#files + 1] = a end end
  if #files == 0 then io.err("usage: " .. (toScreen and "zcat" or "gunzip [-k]") .. " <file.gz...>") return false end
  local all = true
  for _, f in ipairs(files) do
    local path = resolve(f)
    local bytes = vfs.readFile(path, true)
    if not bytes then io.err("gunzip: cannot read " .. path) all = false
    else
      local data, name = deflate.gunzip(bytes)
      if not data then io.err("gunzip: " .. path .. ": " .. tostring(name)) all = false
      elseif toScreen then io.say(data)
      else
        local target = path:match("^(.*)%.gz$") or path:match("^(.*)%.tgz$") and (path:match("^(.*)%.tgz$") .. ".tar") or (path .. ".out")
        if vfs.fs.exists(target) then io.err("gunzip: " .. target .. " exists already") all = false
        else
          vfs.writeFile(target, data, true)
          if not keep then vfs.fs.delete(path) end
          io.say(("%s: %d bytes"):format(target, #data))
        end
      end
    end
  end
  return all
end

return M
