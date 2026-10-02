# tsr.ssh.client

Package: `ssh`

The secure shell client library: connect to an sshd on another computer of the same game world, check its host key against
known_hosts, log in, and then make requests through the encrypted channel (see tsr.ssh.chan for the protocol).

  local conn, err = client.connect(node, "alpha", { user = "alex", identity = key, confirm = function(info) return true end })
  local res, err  = conn:call("exec", { line = "ls" })
  conn:close()

## `M.sshDir()`

The directory for per-user ssh files (known_hosts, id_ed25519): ~/.ssh of the logged-in user, else /root/.ssh.

## `Conn:call(op, args, timeout)`

One request with retransmission. Returns the body of the reply or nil + reason.

## `M.connect(node, target, opts)`

Connect and log in. `node` is a tsr.net node, `target` a computer id or name. Options:
  user, identity (key table), password (string or function), timeout,
  knownHosts (file path), confirm(info) -> boolean to accept an unknown host (info: id, host, fingerprint, art),
  acceptNew (add unknown hosts without asking), onWarning(text).
Returns a connection or nil + reason.
