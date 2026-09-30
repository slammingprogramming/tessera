-- SPDX-License-Identifier: AGPL-3.0-or-later
local req = (rawget(_G, "tsr") and tsr.require) or dofile("/sys/lib/tsr/loader.lua").require
return req("tsrapps.storage").main({ ... })
