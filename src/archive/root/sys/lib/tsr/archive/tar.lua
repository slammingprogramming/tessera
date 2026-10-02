-- SPDX-License-Identifier: AGPL-3.0-or-later
-- tar archives (POSIX ustar, the format every tar reads) of files and folders on this computer, with optional gzip.
--   tar.create(paths, opts)    -> bytes        paths: files and folders; opts: gzip (bool), base (strip this prefix), mtime
--   tar.list(bytes)            -> { { name, size, isDir, mode } }
--   tar.extract(bytes, dest, opts) -> { files, dirs }      refuses absolute and ".." paths (opts.overwrite to replace existing files)
-- Long names use the ustar prefix field (up to 255 characters). Links, devices and extended headers of other tools are skipped.
local deflate = require("tsr.archive.deflate")
local vfs = require("tsr.vfs")
local F = vfs.fs

local M = {}

local floor = math.floor
local sbyte, schar = string.byte, string.char

local function octal(n, width) return ("%0" .. (width - 1) .. "o\0"):format(n) end
local function pad(s, n) return s .. string.rep("\0", n - #s) end

local function checksum(header)
  local sum = 0
  for i = 1, 512 do
    if i >= 149 and i <= 156 then sum = sum + 32 else sum = sum + sbyte(header, i) end
  end
  return sum
end

local function splitName(name)
  if #name <= 100 then return name, "" end
  -- find a slash so that the prefix fits in 155 and the rest in 100
  for i = #name - 100, math.min(#name, 156) do
    if name:sub(i, i) == "/" and i - 1 <= 155 and #name - i <= 100 then return name:sub(i + 1), name:sub(1, i - 1) end
  end
  return nil
end

local function header(name, size, isDir, mtime)
  local short, prefix = splitName(name)
  if not short then return nil, "name too long for tar: " .. name end
  local h = pad(short, 100) .. octal(isDir and 493 or 420, 8) .. octal(0, 8) .. octal(0, 8) .. octal(size, 12) .. octal(mtime, 12)
    .. "        " .. (isDir and "5" or "0") .. pad("", 100) .. "ustar\0" .. "00" .. pad("", 32) .. pad("", 32) .. octal(0, 8) .. octal(0, 8)
    .. pad(prefix, 155) .. pad("", 12)
  local sum = checksum(h)
  return h:sub(1, 148) .. ("%06o\0 "):format(sum) .. h:sub(157)
end

local function addPath(out, path, base, mtime)
  local rel = path
  if base and base ~= "" and path:sub(1, #base + 1) == base .. "/" then rel = path:sub(#base + 2) end
  rel = rel:gsub("^/+", "")
  if F.isDir(path) then
    local h, err = header(rel .. "/", 0, true, mtime)
    if not h then return nil, err end
    out[#out + 1] = h
    for _, name in ipairs(F.list(path)) do
      local ok, e = addPath(out, path .. "/" .. name, base, mtime)
      if not ok then return nil, e end
    end
    return true
  end
  local data = vfs.readFile(path, true)
  if not data then return nil, "cannot read " .. path end
  local h, err = header(rel, #data, false, mtime)
  if not h then return nil, err end
  out[#out + 1] = h
  out[#out + 1] = data
  if #data % 512 ~= 0 then out[#out + 1] = string.rep("\0", 512 - #data % 512) end
  return true
end

--- Build a tar archive. Returns bytes or nil + reason.
function M.create(paths, opts)
  opts = opts or {}
  local out = {}
  local mtime = opts.mtime or floor((os.epoch and os.epoch("utc") or 0) / 1000)
  for _, p in ipairs(paths) do
    p = "/" .. fs.combine(p, "")
    if not F.exists(p) then return nil, "no such file or folder: " .. p end
    local base = opts.base or p:match("^(.*)/[^/]+$") or ""
    local ok, err = addPath(out, p, base, mtime)
    if not ok then return nil, err end
  end
  out[#out + 1] = string.rep("\0", 1024)
  local tar = table.concat(out)
  if opts.gzip then return deflate.gzip(tar, { level = opts.level }) end
  return tar
end

local function field(h, from, to)
  local s = h:sub(from, to)
  local z = s:find("\0", 1, true)
  return z and s:sub(1, z - 1) or s
end

--- Entries of a tar (or tar.gz) as { name, size, isDir, mode, data (the file bytes) }. Returns the list or nil + reason.
local function parse(bytes)
  if bytes:sub(1, 2) == "\31\139" then
    local tar, err = deflate.gunzip(bytes)
    if not tar then return nil, err end
    bytes = tar
  end
  local entries, pos = {}, 1
  while pos + 511 <= #bytes do
    local h = bytes:sub(pos, pos + 511)
    if h == string.rep("\0", 512) then break end
    local sum = tonumber(field(h, 149, 156):gsub("%s", ""), 8)
    if sum ~= checksum(h) then return nil, "tar header checksum mismatch at byte " .. pos .. " (not a tar file, or it is damaged)" end
    local name = field(h, 1, 100)
    local prefix = field(h, 346, 500)
    if prefix ~= "" then name = prefix .. "/" .. name end
    local size = tonumber(field(h, 125, 136):gsub("%s", ""), 8) or 0
    local kind = h:sub(157, 157)
    local entry = { name = name, size = size, isDir = kind == "5" or name:sub(-1) == "/", mode = tonumber(field(h, 101, 108):gsub("%s", ""), 8) or 420 }
    pos = pos + 512
    if kind == "0" or kind == "\0" or kind == "" then
      entry.data = bytes:sub(pos, pos + size - 1)
      if #entry.data < size then return nil, "the archive is truncated in " .. name end
      entries[#entries + 1] = entry
    elseif kind == "5" then
      entries[#entries + 1] = entry
    end
    pos = pos + math.ceil(size / 512) * 512
  end
  return entries
end

function M.list(bytes)
  local entries, err = parse(bytes)
  if not entries then return nil, err end
  local out = {}
  for _, e in ipairs(entries) do out[#out + 1] = { name = e.name, size = e.size, isDir = e.isDir, mode = e.mode } end
  return out
end

local function safe(name)
  if name:sub(1, 1) == "/" then return false end
  for part in name:gmatch("[^/]+") do if part == ".." then return false end end
  return true
end

--- Unpack into the folder `dest`. Returns { files = n, dirs = n } or nil + reason. Unsafe names abort before anything is written.
function M.extract(bytes, dest, opts)
  opts = opts or {}
  local entries, err = parse(bytes)
  if not entries then return nil, err end
  for _, e in ipairs(entries) do
    if not safe(e.name) then return nil, "refusing to unpack an unsafe path: " .. e.name end
    local target = dest .. "/" .. e.name:gsub("/$", "")
    if not e.isDir and F.exists(target) and not opts.overwrite then return nil, target .. " exists already (use overwrite)" end
  end
  local files, dirs = 0, 0
  vfs.mkdirp(dest)
  for _, e in ipairs(entries) do
    local target = dest .. "/" .. e.name:gsub("/$", "")
    if e.isDir then
      vfs.mkdirp(target)
      dirs = dirs + 1
    else
      vfs.mkdirp(vfs.dirname(target))
      local ok, werr = vfs.writeFile(target, e.data, true)
      if not ok then return nil, "cannot write " .. target .. ": " .. tostring(werr) end
      files = files + 1
    end
  end
  return { files = files, dirs = dirs }
end

return M
