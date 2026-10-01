-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Answers chat commands through an Advanced Peripherals chat box (waits until one is attached).
return {
  description = "in-game chat bot",
  module = "tsr.chatbot",
  entry = "daemon",
  autostart = false,
  restart = "on-failure",
}
