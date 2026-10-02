-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Colour palettes for advanced (colour) terminals and monitors. A scheme gives an RGB value to each of the 16 CraftOS colours;
-- the programs keep asking for colors.red and get the scheme's red. Applying works on a terminal object, so it also themes a
-- monitor. The choice is saved in the configuration key `ui.palette` and reapplied at boot.
local M = {}

-- order follows colors.white (1) ... colors.black (32768)
local ORDER = { "white", "orange", "magenta", "lightBlue", "yellow", "lime", "pink", "gray", "lightGray", "cyan", "purple", "blue", "brown",
                "green", "red", "black" }
M.ORDER = ORDER

M.schemes = {
  default = {
    white = 0xF0F0F0, orange = 0xF2B233, magenta = 0xE57FD8, lightBlue = 0x99B2F2, yellow = 0xDEDE6C, lime = 0x7FCC19, pink = 0xF2B2CC,
    gray = 0x4C4C4C, lightGray = 0x999999, cyan = 0x4C99B2, purple = 0xB266E5, blue = 0x3366CC, brown = 0x7F664C, green = 0x57A64E,
    red = 0xCC4C4C, black = 0x111111,
  },
  ["solarized-dark"] = {
    white = 0xFDF6E3, orange = 0xCB4B16, magenta = 0xD33682, lightBlue = 0x6C71C4, yellow = 0xB58900, lime = 0x859900, pink = 0xEE8BB8,
    gray = 0x586E75, lightGray = 0x93A1A1, cyan = 0x2AA198, purple = 0x6C71C4, blue = 0x268BD2, brown = 0x8B6B2F, green = 0x5B8C00,
    red = 0xDC322F, black = 0x002B36,
  },
  gruvbox = {
    white = 0xEBDBB2, orange = 0xFE8019, magenta = 0xD3869B, lightBlue = 0x83A598, yellow = 0xFABD2F, lime = 0xB8BB26, pink = 0xD3869B,
    gray = 0x504945, lightGray = 0xA89984, cyan = 0x8EC07C, purple = 0xB16286, blue = 0x458588, brown = 0xD65D0E, green = 0x98971A,
    red = 0xFB4934, black = 0x282828,
  },
  nord = {
    white = 0xECEFF4, orange = 0xD08770, magenta = 0xB48EAD, lightBlue = 0x88C0D0, yellow = 0xEBCB8B, lime = 0xA3BE8C, pink = 0xC9A0DC,
    gray = 0x434C5E, lightGray = 0xD8DEE9, cyan = 0x8FBCBB, purple = 0xB48EAD, blue = 0x5E81AC, brown = 0xA67C5B, green = 0x7FA36B,
    red = 0xBF616A, black = 0x2E3440,
  },
  paper = {
    white = 0x1B1B1B, orange = 0xB35900, magenta = 0x9B2D87, lightBlue = 0x2F5DA8, yellow = 0x8A6D00, lime = 0x2F7D1E, pink = 0xB0446B,
    gray = 0x8A8A8A, lightGray = 0x555555, cyan = 0x16727E, purple = 0x6B3FA0, blue = 0x1F4FB8, brown = 0x6B4E2E, green = 0x1F6B2E,
    red = 0xB02020, black = 0xF4F1E8,
  },
  ["high-contrast"] = {
    white = 0xFFFFFF, orange = 0xFF9500, magenta = 0xFF40FF, lightBlue = 0x40C0FF, yellow = 0xFFFF00, lime = 0x40FF40, pink = 0xFF80C0,
    gray = 0x606060, lightGray = 0xC0C0C0, cyan = 0x00FFFF, purple = 0xA040FF, blue = 0x4060FF, brown = 0xC08040, green = 0x00C000,
    red = 0xFF3030, black = 0x000000,
  },
}

M.names = { "default", "solarized-dark", "gruvbox", "nord", "paper", "high-contrast" }

local function colorValue(name) return colors[name] end

--- Apply scheme `name` to terminal `t` (default: the current one). Returns true or nil + reason.
function M.apply(name, t)
  t = t or term.current()
  local scheme = M.schemes[name]
  if not scheme then return nil, "no such palette: " .. tostring(name) end
  if not (t.setPaletteColor and (not t.isColor or t.isColor())) then return nil, "this screen has no colour palette" end
  for _, cname in ipairs(ORDER) do t.setPaletteColor(colorValue(cname), scheme[cname]) end
  return true
end

--- Back to the hardware defaults.
function M.reset(t)
  t = t or term.current()
  if not t.setPaletteColor then return nil, "this screen has no colour palette" end
  for _, cname in ipairs(ORDER) do
    local c = colorValue(cname)
    local r, g, b
    if t.nativePaletteColor then r, g, b = t.nativePaletteColor(c) elseif term.nativePaletteColor then r, g, b = term.nativePaletteColor(c) end
    if r then t.setPaletteColor(c, r, g, b) end
  end
  return true
end

--- The saved scheme (config ui.palette), if any, applied to `t`. Used at boot.
function M.applySaved(t)
  local okConfig, config = pcall(require, "tsr.config")
  if not okConfig then return nil end
  local name = config.get("ui.palette")
  if not name or name == "default" then return nil end
  return M.apply(name, t)
end

--- RGB values (0-1 each) of a colour in the scheme, for previews.
function M.rgb(name, cname)
  local v = M.schemes[name] and M.schemes[name][cname]
  if not v then return nil end
  return math.floor(v / 65536) / 255, (math.floor(v / 256) % 256) / 255, (v % 256) / 255
end

return M
