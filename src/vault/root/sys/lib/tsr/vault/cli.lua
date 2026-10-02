-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The vault command (encrypted folders):
--   vault create <folder>                  make a new vault; you choose a passphrase and get a RECOVERY KEY: write it down, it is shown once
--   vault open <folder> <mount point>      ask for the passphrase and show the decrypted files at the mount point (e.g. /secret)
--   vault recover <folder> <mount point>   the same with the recovery key instead of the passphrase
--   vault close <mount point>              lock it again (the plaintext disappears from memory)      vault list   what is mounted
--   vault passwd <folder>                  change the passphrase
local vault = require("tsr.vault")

local M = {}

local function defaultIO()
  local io = {}
  function io.say(t) print(t) end
  function io.err(t) if term.isColor and term.isColor() then term.setTextColor(colors.red) end print(t) term.setTextColor(colors.white) end
  function io.readPassword(prompt) write(prompt) return read("*") end
  function io.collect(n) require("tsr.crypto").rand.collect(n, function(i, total) write("\r" .. i .. "/" .. total .. " ") end) print() end
  return io
end

function M.run(args, io)
  io = io or defaultIO()
  local sub = args[1]

  if sub == "create" then
    local dir = args[2]
    if not dir then io.err("usage: vault create <folder>") return false end
    local pass = io.readPassword("New passphrase (at least 6 characters): ")
    if io.readPassword("Again: ") ~= pass then io.err("the passphrases differ") return false end
    if io.collect then io.say("Collecting randomness: press 16 keys...") io.collect(16) end
    local v, recovery = vault.create(dir, pass)
    if not v then io.err(tostring(recovery)) return false end
    io.say("Vault created in " .. dir .. ".")
    io.say("RECOVERY KEY (write it down somewhere safe; it is shown only now):")
    io.say(recovery)
    io.say("Mount it with:  vault open " .. dir .. " /secret")
    return true

  elseif sub == "open" or sub == "recover" then
    local dir, mountPoint = args[2], args[3]
    if not (dir and mountPoint) then io.err("usage: vault " .. sub .. " <folder> <mount point>") return false end
    if vault.mounted[require("tsr.vfs").normalize(mountPoint)] then io.err(mountPoint .. " is already a mounted vault") return false end
    local secret = io.readPassword(sub == "open" and "Passphrase: " or "Recovery key: ")
    local v, err = vault.open(dir, secret)
    if not v then io.err(tostring(err)) return false end
    v:mount(mountPoint)
    io.say("Unlocked. The files are at " .. mountPoint .. (#v.problems > 0 and (" (" .. #v.problems .. " damaged file(s) were skipped)") or "") .. ".")
    for _, p in ipairs(v.problems) do io.err(p) end
    return true

  elseif sub == "close" then
    local mountPoint = args[2] and require("tsr.vfs").normalize(args[2])
    local v = mountPoint and vault.mounted[mountPoint]
    if not v then io.err("no vault is mounted at " .. tostring(args[2])) return false end
    v:unmount()
    io.say("Locked.")
    return true

  elseif sub == "list" then
    local n = 0
    for mountPoint, v in pairs(vault.mounted) do io.say(mountPoint .. "  <-  " .. v.dir) n = n + 1 end
    if n == 0 then io.say("no vault is mounted") end
    return true

  elseif sub == "passwd" then
    local dir = args[2]
    if not dir then io.err("usage: vault passwd <folder>") return false end
    local v, err = vault.open(dir, io.readPassword("Current passphrase: "))
    if not v then io.err(tostring(err)) return false end
    local new = io.readPassword("New passphrase: ")
    if io.readPassword("Again: ") ~= new then io.err("the passphrases differ") return false end
    local ok, perr = v:changePassphrase(new)
    if not ok then io.err(tostring(perr)) return false end
    io.say("Passphrase changed. (The recovery key still works.)")
    return true
  end
  io.err("usage: vault create | open | recover | close | list | passwd")
  return false
end

function M.main(args) return M.run(args) end

return M
