Rules live here as *.lua files. Example (save as power.lua and run `rules check`):

return {
  name = "generator-on-when-low",
  when = { device = "cube_0", metric = "energy.percent", op = "<", value = 20 },
  clear = { device = "cube_0", metric = "energy.percent", op = ">", value = 60 },
  hold = 10,
  on = { { action = "redstone", port = "back", set = true } },
  off = { { action = "redstone", port = "back", set = false } },
}

The full format is described at the top of /sys/lib/tsr/rules.lua.
