# talonite

Co–Cr–W–Mo. a cobalt alloy with no iron in it at all — made for knife blades, because it holds an edge forever and laughs at corrosion. the everything-knife metal.

## what this is

one raycast extension, two edges:

    timezone    pinned zones for now — or any custom instant, in any zone
    proxy       wi-fi + HTTP/HTTPS proxy state, toggle per-pair or both at once

talonite the alloy is what knife makers reach for when they want one blade
that does everything and never rusts; this is the same idea in software —
the two small utilities that get used daily, fused into one extension so
there's one install, one menu entry point, one thing to audit.

named for the material's personality: **holds an edge** (the zone list and
proxy state are always true, always ready) and **cannot corrode** (zero
permissions, zero network, zero filesystem — nothing to rust).

## the search

the pin screen understands how people actually look for zones:

    nyc  sfo  lon  tyo  sin  dxb        city codes (~50, curated)
    us   uk  jp  in  au  br             country codes (60; multi-zone ones expand)
    york  tokyo  island                 substrings
    nyk  tky                             subsequences, scored (word-starts + streaks)
    wunited stets                       typos — per-word edit distance

results show each zone's offset *right now*, its country, and its clock, so
you pin the right one. already-pinned zones stay visible, marked amber.

## how it works

- IANA conversion is the platform `Intl` API — the OS's own ICU database is
  the timezone data. it updates when macOS updates; nothing else.
- "9:00 in Tokyo" is a two-pass conversion: guess UTC → read the zone's
  offset at that instant → correct. (what luxon does internally; no luxon.)
- the proxy half shells out to `networksetup` (state changes) and
  `security find-generic-password` (wi-fi password copy, on demand only) —
  the same commands System Settings runs.
- the 25 world-map PNGs are from the MIT-licensed raycast-timezone-converter
  extension, copied verbatim.

## dependencies

two, both raycast first-party: `@raycast/api`, `@raycast/utils` (for
preference storage). no luxon, no date-fns, nothing that resolves at
runtime. the whole dependency tree is auditable at a glance, forever.

## install

    npm install
    npm run dev       # appears in raycast as a development extension

development extensions run from this folder, compiled locally — the store
pipeline never touches them, they never auto-update, and `git diff` is the
entire trust audit. stop development and the last build keeps running.

## commands

| command | default shortcut | what it does |
|---|---|---|
| Timezones | — | pinned zones; ⌘P pin (fuzzy), ⌘T custom time, ⌘0 now, ⌘R reorder, ⌘C copy |
| Proxy Status | — | wi-fi row (copy password/network name), HTTP + HTTPS rows, toggle each or both |
