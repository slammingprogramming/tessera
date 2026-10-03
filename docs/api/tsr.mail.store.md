# tsr.mail.store

Package: `mail`

Mailboxes on disk: one folder per mailbox under the store root (/var/mail), subfolders INBOX, Sent, Drafts, Trash, Spam and your own, one file per message
(<uid>.eml), plus an index per folder with the flags and the numbers that listings need. Messages never change once stored; deleting is a flag until expunge.
Also here: the accounts (name, password hash, quota) in /etc/tsr/mail/users.lua.

## `M.new(opts)`

root: where mailboxes live (default M.ROOT), users: path of the accounts file (default M.USERS), iterations: password hashing work.

## `Store:authenticate(name, password)`

Check a password. Returns the account name or nil.

## `Store:usage(mailbox)`

Bytes used by all messages of the mailbox.

## `Store:deliver(mailbox, raw, folder, flags)`

Store a message. Returns its uid, or nil + reason ("quota" when the mailbox is full).

## `Store:list(mailbox, folder)`

The listing of a folder: { uid, flags, size, from, subject, date }.

## `Store:expunge(mailbox, folder)`

Remove messages flagged deleted. Returns how many went.

## `Store:move(mailbox, folder, uid, target)`

Move a message to another folder (new uid there). Returns the new uid.

## `Store:reload()`

Forget cached indexes (after another process changed the files).
