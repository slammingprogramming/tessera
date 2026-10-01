-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Colour themes for the desktop. A theme maps semantic roles (what a colour is FOR) to CraftOS colours, so widgets never name a
-- concrete colour. "mono" only uses the four greys a basic computer can show.
local M = {}

M.themes = {
  dark = {
    desktop = colors.blue, text = colors.white, textDim = colors.lightGray,
    window = colors.black, windowText = colors.white, border = colors.gray,
    titleActive = colors.cyan, titleActiveText = colors.black, titleInactive = colors.gray, titleInactiveText = colors.lightGray,
    button = colors.gray, buttonText = colors.white, buttonActive = colors.lightBlue, buttonActiveText = colors.black,
    input = colors.gray, inputText = colors.white, inputFocus = colors.lightGray, inputFocusText = colors.black,
    selection = colors.lightBlue, selectionText = colors.black, accent = colors.lightBlue,
    ok = colors.lime, warn = colors.orange, danger = colors.red, disabled = colors.gray,
    taskbar = colors.gray, taskbarText = colors.white, menu = colors.gray, menuText = colors.white,
  },
  light = {
    desktop = colors.lightBlue, text = colors.black, textDim = colors.gray,
    window = colors.white, windowText = colors.black, border = colors.lightGray,
    titleActive = colors.blue, titleActiveText = colors.white, titleInactive = colors.lightGray, titleInactiveText = colors.gray,
    button = colors.lightGray, buttonText = colors.black, buttonActive = colors.blue, buttonActiveText = colors.white,
    input = colors.white, inputText = colors.black, inputFocus = colors.yellow, inputFocusText = colors.black,
    selection = colors.blue, selectionText = colors.white, accent = colors.blue,
    ok = colors.green, warn = colors.orange, danger = colors.red, disabled = colors.lightGray,
    taskbar = colors.lightGray, taskbarText = colors.black, menu = colors.white, menuText = colors.black,
  },
  contrast = {
    desktop = colors.black, text = colors.white, textDim = colors.white,
    window = colors.black, windowText = colors.white, border = colors.white,
    titleActive = colors.yellow, titleActiveText = colors.black, titleInactive = colors.white, titleInactiveText = colors.black,
    button = colors.white, buttonText = colors.black, buttonActive = colors.yellow, buttonActiveText = colors.black,
    input = colors.black, inputText = colors.yellow, inputFocus = colors.yellow, inputFocusText = colors.black,
    selection = colors.yellow, selectionText = colors.black, accent = colors.yellow,
    ok = colors.lime, warn = colors.orange, danger = colors.red, disabled = colors.gray,
    taskbar = colors.white, taskbarText = colors.black, menu = colors.black, menuText = colors.white,
  },
  mono = {
    desktop = colors.gray, text = colors.white, textDim = colors.lightGray,
    window = colors.black, windowText = colors.white, border = colors.lightGray,
    titleActive = colors.white, titleActiveText = colors.black, titleInactive = colors.lightGray, titleInactiveText = colors.black,
    button = colors.gray, buttonText = colors.white, buttonActive = colors.white, buttonActiveText = colors.black,
    input = colors.gray, inputText = colors.white, inputFocus = colors.white, inputFocusText = colors.black,
    selection = colors.white, selectionText = colors.black, accent = colors.white,
    ok = colors.white, warn = colors.lightGray, danger = colors.white, disabled = colors.gray,
    taskbar = colors.lightGray, taskbarText = colors.black, menu = colors.black, menuText = colors.white,
  },
}

M.order = { "dark", "light", "contrast", "mono" }

M.current = M.themes.dark
M.currentName = "dark"

--- The theme a terminal can show: colour terminals get `name` (default dark); grey-scale ones always get mono.
function M.resolve(name, isColor)
  if isColor == nil then isColor = term.isColor() end
  if not isColor then return "mono" end
  if M.themes[name or "dark"] then return name or "dark" end
  return "dark"
end

function M.set(name, isColor)
  local resolved = M.resolve(name, isColor)
  M.current, M.currentName = M.themes[resolved], resolved
  return resolved
end

function M.get() return M.current end

return M
