# tsr.chatbot

Package: `chatbot`

In-game chat bot for the Advanced Peripherals chat box (peripheral "chat_box", "chatBox" before Minecraft 1.21.1).
The box raises  chat(username, message, uuid, isHidden)  for every chat message; messages that start with the command
prefix (default "!") are answered with sendMessageToPlayer.

  !help            list the commands you may use
  !status          this computer's uptime, services and warnings
  !time            in-game time and day
  !ping <peer>     reach a paired computer      !metrics <peer>    its vital signs
  !svc list|start|stop|restart <name>           (administrators only)

Configuration /etc/tsr/chatbot.cfg:  { prefix = "!", name = "Tessera", admins = { "PlayerName" }, admin_uuids = { "..." } }
More commands: drop a file into /etc/tsr/chatbot.d/ that returns { name = { help = "...", admin = false, run = function(ctx, args) return "text" end } }.

## `M.register(name, def)`

Add or replace a command at runtime.

## `M.loadExtras()`

Load extra command files from M.DIR.

## `M.handle(box, cfg, user, message, uuid, now)`

Process one chat event. Returns true when it was a command (answered or refused).

## `M.daemon()`

The chatbotd service: wait for a chat box, answer commands.

## `M.cli(args, io)`

chatbot admin add|remove <player> | prefix <p> | status
