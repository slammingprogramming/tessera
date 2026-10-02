# tsr.hal.cdisplay

Package: `int-create`

The `cdisplay` command: put text on Create display links (CC:C Bridge `create_source`) and read display targets.
  cdisplay list                      the Create displays that are connected
  cdisplay write <name> <text...>    clear the display and show the text (\n starts a new line)
  cdisplay show <name>               print what a create_target currently shows
  cdisplay metric <name> <device> <reading> [label]   show one live HAL reading, e.g. an energy percentage

## `M.writeText(dev, text)`

Write `text` (with \n line breaks) on a source display.
