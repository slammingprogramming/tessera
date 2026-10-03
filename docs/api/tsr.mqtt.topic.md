# tsr.mqtt.topic

Package: `mqtt`

MQTT topic names ("home/kitchen/light") and filters ("home/+/light", "home/#").

## `M.validTopic(t)`

A topic name to publish to: no wildcards, not empty.

## `M.validFilter(f)`

A filter to subscribe with: + for exactly one level, # (last, whole level) for all the rest.

## `M.match(filter, topic)`

Does the filter match the topic? (Filters that start with a wildcard do not match topics starting with $, the broker's own.)

## `M.covers(rule, filter)`

Does the rule filter allow subscribing with this filter? (everything the requested filter can match is also matched by the rule)
