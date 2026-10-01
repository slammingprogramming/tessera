-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Boot daemon: loads /etc/tsr/services.d, starts the enabled services and keeps them running.
local svc = require("tsr.svc")
require("tsr.kernel").onStop(svc.stopAll)
svc.supervise()
