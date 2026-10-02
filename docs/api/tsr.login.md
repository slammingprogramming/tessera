# tsr.login

Package: `auth`

Login prompt and lock screen. Every function takes an optional `io` table so tests can drive it:
  io.clear(), io.say(text), io.ask(prompt), io.secret(prompt), io.sleep(seconds), io.snapshot() -> restore function

## `M.run(opts)`

Ask for credentials until they are right. Returns the user (public view); with opts.attempts, gives up with nil after that
many failures. The user becomes the session user of the calling process.

## `M.lock(opts)`

Hide the screen until the current user's password is typed. Returns true once unlocked.
