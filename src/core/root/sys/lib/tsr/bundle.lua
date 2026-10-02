-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Offline bundles: a registry snapshot and/or package payloads packed into one container so a computer with NO
-- network access can still install Tessera and apps. A bundle reaches the computer in one of two ways:
--   * as a file dropped onto the terminal (file_transfer event) or read from a disk  -> "TSRZ" + raw DEFLATE stream
--   * as numbered text lines pasted at a prompt                                       -> "TSR1 <id> <n>/<total> <crc32> <base64>"
-- Container (before compression):  "TSRB" u8 version(1) u16 count, then per entry:
--   u8 kind (1=index json, 2=package doc json, 3=blob, 4=signature file of the index)  u8 nameLen  name  u32 dataLen  data
-- Index and package entries hold the registry files byte for byte, so their signatures and hashes stay valid.
-- Blob entries are named by the SHA-256 of their content and verified on load.
local hash = require("tsr.hash")
local inflate = require("tsr.inflate")

local M = {}

M.KIND_INDEX, M.KIND_PACKAGE, M.KIND_BLOB, M.KIND_SIGNATURE = 1, 2, 3, 4

local function u16(s, p) local a, b = s:byte(p, p + 1) return a * 256 + b end
local function u32(s, p)
  local a, b, c, d = s:byte(p, p + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

--- Parse an (already decompressed) container. Returns { index = table|nil, indexRaw, indexSig, packages = {name=doc}, packageRaw = {name=text}, blobs = {sha=data} }.
function M.parseContainer(s)
  if s:sub(1, 4) ~= "TSRB" then return nil, "not a Tessera bundle" end
  if s:byte(5) ~= 1 then return nil, "unsupported bundle version " .. tostring(s:byte(5)) end
  local count = u16(s, 6)
  local pos = 8
  local out = { packages = {}, packageRaw = {}, blobs = {} }
  for _ = 1, count do
    if pos + 5 > #s then return nil, "truncated bundle" end
    local kind, nameLen = s:byte(pos), s:byte(pos + 1)
    local name = s:sub(pos + 2, pos + 1 + nameLen)
    local dataLen = u32(s, pos + 2 + nameLen)
    local dpos = pos + 6 + nameLen
    if dpos + dataLen - 1 > #s then return nil, "truncated bundle" end
    local data = s:sub(dpos, dpos + dataLen - 1)
    pos = dpos + dataLen
    if kind == M.KIND_BLOB then
      if hash.sha256(data) ~= name then return nil, "blob " .. name:sub(1, 12) .. " is corrupt" end
      out.blobs[name] = data
    elseif kind == M.KIND_INDEX then
      out.index = textutils.unserializeJSON(data)
      if not out.index then return nil, "bad index json" end
      out.indexRaw = data
    elseif kind == M.KIND_SIGNATURE then
      out.indexSig = data
    elseif kind == M.KIND_PACKAGE then
      local doc = textutils.unserializeJSON(data)
      if not doc then return nil, "bad package json for " .. name end
      out.packages[name] = doc
      out.packageRaw[name] = data
    end
  end
  return out
end

--- Parse bundle bytes as delivered by a file drop or disk: "TSRZ" + raw deflate, or a text file of TSR1 lines.
function M.parse(data)
  if data:sub(1, 4) == "TSRZ" then
    local ok, raw = pcall(inflate.inflate, data, 6) -- 4 magic + 1 version byte
    if not ok then return nil, tostring(raw) end
    return M.parseContainer(raw)
  end
  if data:sub(1, 5) == "TSR1 " then
    local asm = M.newAssembler()
    for line in (data .. "\n"):gmatch("([^\r\n]*)\r?\n") do
      if line ~= "" then asm:add(line) end
    end
    if not asm:complete() then return nil, "incomplete: missing chunks " .. table.concat(asm:missing(), ",") end
    return asm:result()
  end
  return nil, "unrecognised bundle format"
end

---------------------------------------------------------------------------------------------------------------------
-- Text-chunk assembler (paste mode)
---------------------------------------------------------------------------------------------------------------------

local Assembler = {}
Assembler.__index = Assembler

function M.newAssembler()
  return setmetatable({ id = nil, total = nil, parts = {}, have = 0 }, Assembler)
end

--- Feed one pasted line. Returns status, detail:
---   "ok", seq        accepted        "dup", seq   already had it       "bad", reason   rejected (re-paste it)
---   "ignored"        not a chunk line (blank, prompt noise)
function Assembler:add(line)
  line = line:gsub("^%s+", ""):gsub("%s+$", "")
  if line == "" then return "ignored" end
  local id, seq, total, crc, payload = line:match("^TSR1 (%x+) (%d+)/(%d+) (%x+) (%S+)$")
  if not id then
    if line:sub(1, 4) == "TSR1" then return "bad", "malformed chunk line" end
    return "ignored"
  end
  seq, total = tonumber(seq), tonumber(total)
  if tonumber(crc, 16) ~= hash.crc32(payload) then return "bad", "chunk " .. seq .. ": checksum mismatch" end
  if seq < 1 or seq > total then return "bad", "chunk number out of range" end
  if self.id and (self.id ~= id or self.total ~= total) then return "bad", "chunk belongs to a different bundle" end
  self.id, self.total = id, total
  if self.parts[seq] then return "dup", seq end
  self.parts[seq] = payload
  self.have = self.have + 1
  return "ok", seq
end

function Assembler:progress() return self.have, self.total end
function Assembler:complete() return self.total ~= nil and self.have == self.total end

function Assembler:missing()
  local out = {}
  for i = 1, self.total or 0 do
    if not self.parts[i] then out[#out + 1] = i end
  end
  return out
end

--- Decode a completed assembly into the container table (verifies the bundle id and every blob hash).
function Assembler:result()
  if not self:complete() then return nil, "bundle incomplete" end
  local bin, err = hash.base64Decode(table.concat(self.parts))
  if not bin then return nil, err end
  if hash.sha256(bin):sub(1, #self.id) ~= self.id then return nil, "bundle checksum mismatch" end
  local ok, raw = pcall(inflate.inflate, bin)
  if not ok then return nil, tostring(raw) end
  return M.parseContainer(raw)
end

return M
