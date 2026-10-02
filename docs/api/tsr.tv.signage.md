# tsr.tv.signage

Package: `tv`

Digital signage: a slideshow on a monitor that runs by itself.
/etc/tsr/signage.cfg:  { monitor = "monitor_0", slides = { ... } }   (no monitor = the computer's own screen)
Slides (each lasts `seconds`, default 8):
  { kind = "text",   text = "Welcome!", scale = 2, color = "yellow" }      big letters, centred
  { kind = "image",  path = "/media/logo.nfp" }                           a picture (NFP or a one-frame BIMG)
  { kind = "video",  path = "/media/loop.bimg" }                          an animation (plays for `seconds`, looping)
  { kind = "clock" }                                                      the time of day
  { kind = "metric", device = "cell", metric = "energy.percent", label = "Power" }   a live reading through the HAL
  signage list | add text <text...> | add image|video <path> [seconds] | add clock | remove <n> | monitor <name> | run

## `M.show(slide, t, env)`

Show one slide. Returns the number of seconds it should stay (0 when playing already took that time).
env: peripheral (for metrics), pull (events), sleep.

## `M.run(cfg, env)`

The slideshow loop. env: term, peripheral, maxSlides (tests), sleep.

## `M.daemon()`

The signaged service.
