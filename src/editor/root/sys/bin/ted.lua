-- SPDX-License-Identifier: AGPL-3.0-or-later
-- ted: text editor.   ted [file]
local req = (rawget(_G, "tsr") and tsr.require) or dofile("/sys/lib/tsr/loader.lua").require
local args = { ... }
local ed = req("tsr.edit.ui").new({ path = args[1] and shell and shell.resolve(args[1]) or args[1] })
ed:run()
