# tsr.mail.spam.bayes

Package: `mail-spam`

A learning spam filter (naive Bayes over word counts, in the style of Paul Graham's "A Plan for Spam" with Robinson's smoothing). It starts knowing nothing and
says "unknown" until it has seen a few spam and a few good messages; users teach it by moving mail to or from the Spam folder (mailctl spam learn / mail spam / mail ham).
The database is a Lua table file that stays small: only the commonest tokens are kept (default 6000).
  local b = bayes.new("/var/lib/tsr/mail/bayes.lua")
  b:train(rawMessage, true)    -- this was spam
  local p, why = b:classify(rawMessage)    -- 0 (surely good) .. 1 (surely spam), or nil when it has not learned enough

## `M.tokens(raw)`

The words of a message plus a few markers (sender domain, attachment types, link hosts).

## `Bayes:untrain(raw, wasSpam)`

Take back a training (the user moved a message the other way).

## `Bayes:prune()`

Keep the table below the limit by dropping the rarest tokens.

## `Bayes:classify(raw)`

Probability that the message is spam, or nil + reason without enough training.
