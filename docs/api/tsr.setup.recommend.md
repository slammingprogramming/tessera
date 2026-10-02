# tsr.setup.recommend

Package: `installer`

Recommendation engine: turns a hardware probe (tsr.hw) into a profile choice and a list of suggested packages, each
with a human-readable REASON so the user can judge it. Pure function of the probe — easy to test.
Package names are the planned registry names; the wizard shows only the ones that actually exist in the registry.

## `M.detectMods(probe)`

Which known mods have peripherals attached? Returns array of { id, name, verified, example }.

## `M.profiles(probe)`

Profile suggestions. Returns array of { name, label, recommended, reason, blocked }.

## `M.packages(probe, profile)`

Suggested packages for `profile`. Returns array of { pkg, reason, tier = "recommended" | "optional" }.

## `M.recommend(probe)`

Everything at once: { profiles, default, items, mods }.
