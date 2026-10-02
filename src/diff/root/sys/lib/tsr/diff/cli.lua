-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Commands:
--   diff [-U <lines>] [-r] <old> <new>      show the differences as a unified diff (files, or with -r two folders)
--   patch [-R] [-p <n>] [--dry-run] [-i <patch file>] [file]
--         apply a unified diff (from the file named with -i, or from the clipboard-style prompt when none is given) to `file`, or to the
--         files named in the patch (with <n> leading folders removed); -R undoes a patch. Nothing is changed unless every hunk fits.
local diff = require("tsr.diff")
local vfs = require("tsr.vfs")

local M = {}
local F = vfs.fs

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

local function compareDirs(a, b, ctx, io, out)
  local names, seen = {}, {}
  for _, n in ipairs(F.list(a)) do names[#names + 1] = n seen[n] = true end
  for _, n in ipairs(F.list(b)) do if not seen[n] then names[#names + 1] = n end end
  table.sort(names)
  for _, n in ipairs(names) do
    local pa, pb = a .. "/" .. n, b .. "/" .. n
    local ea, eb = F.exists(pa), F.exists(pb)
    if ea and eb and F.isDir(pa) and F.isDir(pb) then compareDirs(pa, pb, ctx, io, out)
    elseif not (ea and eb) then out[#out + 1] = "Only in " .. (ea and a or b) .. ": " .. n
    elseif F.isDir(pa) ~= F.isDir(pb) then out[#out + 1] = pa .. " and " .. pb .. " are not both folders or both files"
    else
      local d = diff.unified(vfs.readFile(pa, true), vfs.readFile(pb, true), { nameA = pa, nameB = pb, context = ctx })
      if d ~= "" then out[#out + 1] = (d:gsub("\n$", "")) end
    end
  end
end

function M.diff(args, io)
  io = io or defaultIO()
  local ctx, recursive, files = 3, false, {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "-r" then recursive = true
    elseif a == "-U" then i = i + 1 ctx = tonumber(args[i]) or 3
    elseif a == "-u" then -- unified is the only format
    else files[#files + 1] = a end
    i = i + 1
  end
  if #files ~= 2 then io.err("usage: diff [-U lines] [-r] <old> <new>") return false end
  local a, b = resolve(files[1]), resolve(files[2])
  if not F.exists(a) then io.err("diff: " .. a .. ": no such file or folder") return false end
  if not F.exists(b) then io.err("diff: " .. b .. ": no such file or folder") return false end
  if F.isDir(a) or F.isDir(b) then
    if not (F.isDir(a) and F.isDir(b)) then io.err("diff: cannot compare a folder with a file") return false end
    if not recursive then io.err("diff: " .. a .. " and " .. b .. " are folders (use -r)") return false end
    local out = {}
    compareDirs(a, b, ctx, io, out)
    for _, l in ipairs(out) do io.say(l) end
    return true
  end
  local d = diff.unified(vfs.readFile(a, true), vfs.readFile(b, true), { nameA = files[1], nameB = files[2], context = ctx })
  if d == "" then io.say("(the files are identical)") else io.say((d:gsub("\n$", ""))) end
  return true
end

local function strip(name, n)
  if name == "/dev/null" then return nil end
  for _ = 1, n do name = name:gsub("^/*[^/]*/", "", 1) end
  return name
end

function M.patch(args, io)
  io = io or defaultIO()
  local reverse, dry, pstrip, patchFile, target = false, false, 0, nil, nil
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "-R" then reverse = true
    elseif a == "--dry-run" then dry = true
    elseif a == "-p" then i = i + 1 pstrip = tonumber(args[i]) or 0
    elseif a:match("^%-p%d+$") then pstrip = tonumber(a:sub(3))
    elseif a == "-i" then i = i + 1 patchFile = args[i]
    else target = a end
    i = i + 1
  end
  if not patchFile then io.err("usage: patch [-R] [-p n] [--dry-run] -i <patch file> [file]") return false end
  local text = vfs.readFile(resolve(patchFile), true)
  if not text then io.err("patch: cannot read " .. patchFile) return false end
  local files, err = diff.parse(text)
  if not files then io.err("patch: " .. tostring(err)) return false end
  -- first work out every result; write only when all of them succeed
  local results = {}
  for _, f in ipairs(files) do
    local name = target or strip(reverse and f.old or f.new, pstrip) or strip(reverse and f.new or f.old, pstrip)
    if not name then io.err("patch: the patch names no file to change") return false end
    local path = resolve(name)
    local current = F.exists(path) and vfs.readFile(path, true) or nil
    if current == nil then
      local creates = #f.hunks > 0 and (reverse and f.hunks[1].newLen or f.hunks[1].oldLen) == 0
      if not creates then io.err("patch: " .. path .. " does not exist") return false end
      current = ""
    end
    local new, report = diff.apply(current, f.hunks, { reverse = reverse })
    if not new then io.err("patch: " .. path .. ": " .. tostring(report)) return false end
    results[#results + 1] = { path = path, text = new, report = report }
    if target then break end
  end
  for _, r in ipairs(results) do
    local moved = 0
    for _, o in ipairs(r.report.offsets) do if o ~= 0 then moved = moved + 1 end end
    io.say(("%s %s (%d hunk%s%s)"):format(dry and "would patch" or "patched", r.path, r.report.hunks, r.report.hunks == 1 and "" or "s",
      moved > 0 and (", " .. moved .. " found at a different line") or ""))
    if not dry then
      local ok, werr = vfs.writeFile(r.path, r.text, true)
      if not ok then io.err("patch: cannot write " .. r.path .. ": " .. tostring(werr)) return false end
    end
  end
  return true
end

return M
