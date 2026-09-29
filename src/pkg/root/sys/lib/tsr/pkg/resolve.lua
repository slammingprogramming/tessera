-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Dependency resolution. Greedy with accumulated version constraints (no backtracking): each package is pinned to the
-- highest version satisfying every constraint seen so far, and a later constraint that contradicts that choice is
-- reported as a conflict rather than silently re-planned.
local semver = require("tsr.pkg.semver")
local util = require("tsr.util")

local M = {}

--- Parse "name", "name@range" into name, range.
function M.parseRequest(s)
  local name, range = s:match("^([^@]+)@(.+)$")
  return name or s, range or "*"
end

local function sortedKeys(t)
  local ks = {}
  for k in pairs(t or {}) do ks[#ks + 1] = k end
  table.sort(ks)
  return ks
end

--- requests: array of "name" / "name@range" strings.
--- ctx: installed(name) -> record|nil, installedProvider(virt) -> name|nil, lookup(name) -> doc|nil,
---      providers(virt) -> array of package names that can provide `virt`.
--- opts: upgrade (bool: move installed packages to the newest version), reinstall (bool)
--- Returns plan (array of { name, version, manifest, action = "install"|"upgrade"|"reinstall", reason }) or nil, errors.
function M.plan(requests, ctx, opts)
  opts = opts or {}
  local plan, order, constraints, visiting, errors, kept = {}, {}, {}, {}, {}, {}

  local function err(fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end

  local function combined(name)
    local parts = {}
    for _, c in ipairs(constraints[name] or {}) do
      if c.range ~= "*" then parts[#parts + 1] = c.range end
    end
    return #parts == 0 and "*" or table.concat(parts, " ")
  end

  local need
  need = function(name, range, by, reason, explicit)
    constraints[name] = constraints[name] or {}
    table.insert(constraints[name], { range = range, by = by })
    local range_all = combined(name)

    if plan[name] then
      if not semver.satisfies(plan[name].version, range_all) then
        err("%s: %s (needed by %s) conflicts with the already selected %s", name, range, by or "you", plan[name].version)
      end
      return
    end
    if kept[name] then
      if not semver.satisfies(kept[name], range_all) then
        err("%s: installed version %s does not satisfy %s (needed by %s)", name, kept[name], range, by or "you")
      end
      return
    end
    if visiting[name] then return err("dependency cycle involving %s", name) end

    local inst = ctx.installed(name)
    local doc
    if not inst then
      if not ctx.lookup(name) then
        local prov = ctx.installedProvider(name)
        if prov then return end -- an installed package already provides this virtual name
        local candidates = ctx.providers(name)
        if candidates and #candidates > 0 then return need(candidates[1], "*", by, "auto") end
        return err("package '%s' not found%s", name, by and (" (required by " .. by .. ")") or "")
      end
    end
    doc = ctx.lookup(name)
    local best
    if doc then best = semver.best(sortedKeys(doc.versions), range_all) end

    if inst then
      local satisfied = semver.satisfies(inst.version, range_all)
      local newer = best and semver.compare(best, inst.version) > 0
      local want = (explicit and opts.reinstall) or (newer and (opts.upgrade or not satisfied)) or (not satisfied)
      if not want then
        kept[name] = inst.version
        return
      end
      if not best then return err("%s: no available version satisfies %s", name, range_all) end
    elseif not best then
      return err("%s: no available version satisfies %s", name, range_all)
    end

    local manifest = doc.versions[best]
    visiting[name] = true
    for _, dep in ipairs(sortedKeys(manifest.requires)) do
      need(dep, manifest.requires[dep], name, "auto")
    end
    visiting[name] = nil
    for _, c in ipairs(manifest.conflicts or {}) do
      if ctx.installed(c) or plan[c] then err("%s conflicts with %s", name, c) end
    end
    local action = inst and (best == inst.version and "reinstall" or "upgrade") or "install"
    plan[name] = { name = name, version = best, manifest = manifest, action = action,
                   reason = explicit and "manual" or (inst and inst.reason) or reason or "auto" }
    order[#order + 1] = plan[name]
  end

  for _, req in ipairs(requests) do
    local name, range = M.parseRequest(req)
    need(name, range, nil, "manual", true)
  end
  if #errors > 0 then return nil, errors end
  return order
end

return M
