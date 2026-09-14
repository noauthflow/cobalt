# talonite

Co–Cr–W–Mo — the cobalt blade alloy. named for the same reason as the rest of cobalt: it holds an edge.

## what this is

one raycast extension, four commands:

- **Timezones** — pinned zones for now, or any custom instant ("9:00 in Tokyo")
- **Proxy Status** — wi-fi + HTTP/HTTPS proxy state; toggle each or both
- **Color Picker** — system magnifier loupe; copies the picked color (hex / rgb / hsl preference)
- **Ruler** — crosshair overlay; click two points (or drag) and the distance in pixels is copied

both no-view commands copy to the clipboard and confirm with a HUD.

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

## native helpers (swift/)

the color picker and ruler are thin react shells — all the real work happens in two
small swift CLIs in `swift/`:

- `color-picker.swift` — the system `NSColorSampler` loupe, resolved to sRGB (same API the store's color-picker extension uses)
- `Ruler.swift` — a borderless overlay window covering the screen under the cursor; crosshair, live line + distance chip, click A then click B (or drag, with the drag-mode preference), esc/right-click cancels, space accepts the point under the crosshair, holding cmd snaps the line to 45° increments

`npm run native` (build-native.sh) compiles them into universal binaries at
`assets/compiled_raycast_swift/` — the same folder raycast's own swift packaging
would produce — and `src/native.ts` spawns them with the same calling convention
raycast generates: argv = function name + JSON args, JSON result on stdout.

no permissions needed: the overlay is our own key window, so no accessibility or
input-monitoring grants. no Xcode needed either — swiftc from the command line
tools is enough (raycast's own swift packaging requires full Xcode for xcodebuild).
distances are screen points (what NSEvent reports), labelled px to match the oracle.

## dependencies

`@raycast/api` + `@raycast/utils` (both first-party). nothing else, nothing resolved at runtime.

## install

    npm install
    npm run build

dev extensions compile locally, never auto-update, and stop working if this folder moves.
