# talonite

Co–Cr–W–Mo — the cobalt blade alloy. named for the same reason as the rest of cobalt: it holds an edge.

## what this is

one raycast extension, two commands:

- **Timezones** — pinned zones for now, or any custom instant ("9:00 in Tokyo")
- **Proxy Status** — wi-fi + HTTP/HTTPS proxy state; toggle each or both

both live in `src/`, share nothing but the manifest.

## timezone search

the pin screen (⌘P) matches:

- city codes — `nyc`, `sfo`, `lon`, `tyo` (~50 curated)
- country codes — `us`, `uk`, `jp`… (multi-zone countries expand to all their zones)
- substrings, subsequences (`nyk` → New York), and per-word typos (`wunited stets` → United States)

already-pinned zones stay in the results, marked, and pin/unpin is a toggle.

## how it works

- IANA conversion is the platform `Intl` API — timezone data comes from the OS ICU database, not from this repo
- wall-time-in-a-zone → instant is a two-pass conversion (guess UTC, correct by the zone's offset at the guess)
- the proxy half runs `networksetup` for state changes; the wi-fi password copy runs `security find-generic-password` on demand
- `assets/timezones/` map PNGs are from the MIT-licensed raycast-timezone-converter extension

## dependencies

`@raycast/api` + `@raycast/utils` (both first-party). nothing else, nothing resolved at runtime.

## install

    npm install
    npm run dev

dev extensions compile locally, never auto-update, and stop working if this folder moves.
