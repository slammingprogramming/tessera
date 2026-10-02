# tsr.rules

Package: `rules`

Rules engine: watch readings from the HAL and act when they cross a threshold. Rule files live in /etc/tsr/rules.d/*.lua and
return one rule or a list of rules:

  return {
    name = "generator-on-when-low",
    every = 5,                                    -- seconds between checks (default 5)
    when = { device = "cube_0", metric = "energy.percent", op = "<", value = 20 },
    hold = 10,                                    -- the condition must stay true this long before the rule fires
    clear = { device = "cube_0", metric = "energy.percent", op = ">", value = 60 },   -- optional hysteresis
    on  = { { action = "device", device = "generator", do_ = "machine.start" },
            { action = "log", level = "warn", text = "Power low (${value}%)" } },
    off = { { action = "device", device = "generator", do_ = "machine.stop" } },
  }

Conditions combine with { all = {...} }, { any = {...} } and { ["not"] = cond }. Operators: < <= > >= == ~= and
"between" (value = {low, high}); without an operator the reading itself must be true. Actions (`action = ...`):
  device    { device, do_ (an action name; `do` is a Lua keyword), args = {...} }       through the HAL
  redstone  { port = "back:red", set = true | 0-15 }
  command   { line = "shell command line" }
  service   { start | stop | restart = "service name" }
  log       { level = "info" | "warn" | "error", text = "..." }          ${value}, ${rule}, ${state} are replaced
  notify    { title, text, level }                                         pushes a notification (package mobile)
  event     { name = "my_event" }                                         queues an os event: tsr_rule, rule, state
A rule fires its `on` list once when it becomes active and its `off` list once when it ends (edge-triggered), not on every check.

## `M.evaluate(cond, lookup)`

Evaluate a condition. `lookup(deviceName)` returns a HAL device. Returns true/false, plus the last reading seen, or
nil + error when a device or reading is unavailable.

## `M.engine(opts)`

opts: now (function -> seconds), env (HAL env: peripheral, redstone...), run (function(line) for command actions)

## `Engine:load(dir)`

Read rule files from M.dir. Returns the number of rules and a list of problems.

## `Engine:tick()`

Check every rule that is due. Returns the list of { rule, event = "on"|"off" } that fired.

## `M.daemon()`

The rulesd service.

## `M.cli(args, io, env)`

rules list | check [<name>]
