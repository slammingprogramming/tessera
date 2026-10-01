-- SPDX-License-Identifier: AGPL-3.0-or-later
return {
  description = "Chat bot: answers !commands from players through an Advanced Peripherals chat box",
  packages = { "chatbot" },
  services = { "chatbotd" },
  notes = "Needs a chat box next to the computer. Make yourself an administrator with 'chatbot admin add <player>'.",
}
