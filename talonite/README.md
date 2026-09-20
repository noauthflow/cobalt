# talonite

Co–Cr–W–Mo — the cobalt blade alloy. named for the same reason as the rest of cobalt: it holds an edge.

## what this is

one raycast extension, six commands:

- **Timezones** — pinned zones for now, or any custom instant ("9:00 in Tokyo")
- **Proxy Status** — wi-fi + HTTP/HTTPS proxy state; toggle each or both
- **Color Picker** — system magnifier loupe; copies the picked color (hex / rgb / hsl preference)
- **Ruler** — crosshair overlay; click two points (or drag) and the distance in pixels is copied
- **Audio Devices** — every output/input device CoreAudio knows; one action flips the default on either side
- **Bluetooth Devices** — paired devices with live connection state; connect, disconnect, or toggle

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
- `audio.swift` — pure CoreAudio: enumerates devices with their sides (a device can serve output and input), master volume, transport (builtin/hdmi/bluetooth/usb/airplay/…), and the current default per side; setting a default is the same property write the Sound pane performs (`kAudioHardwarePropertyDefaultOutputDevice` and friends on the system object). no permissions
- `bluetooth.swift` — pure IOBluetooth: paired devices with live connection state, connect via `openConnection()`, disconnect via `closeConnection()` — the same calls the Bluetooth pane makes. type detection reads class-of-device when it's populated (classic keyboards/mice) and falls back to blued's `device_minorType` from `system_profiler` for BLE HID gear — so rows show the M3 keyboard / mouse glyph, or the bluetooth rune when nothing is known. the first action triggers macOS's Bluetooth permission prompt for Raycast; grant once, it survives rebuilds. addresses are the device's own `addressString`, so list → act needs no lookup table

`npm run native` (build-native.sh) compiles them into universal binaries at
`assets/compiled_raycast_swift/` — the same folder raycast's own swift packaging
would produce — and `src/native.ts` spawns them with the same calling convention
raycast generates: argv = function name + JSON args, JSON result on stdout.

no permissions needed: the overlay is our own key window, so no accessibility or
input-monitoring grants. audio needs none either (CoreAudio defaults are
permission-free). bluetooth earns its TCC prompt honestly — one grant, stored
against Raycast's signature. no Xcode needed either — swiftc from the command line
tools is enough (raycast's own swift packaging requires full Xcode for xcodebuild).
distances are screen points (what NSEvent reports), labelled px to match the oracle.

## dependencies

`@raycast/api` + `@raycast/utils` (both first-party). nothing else, nothing resolved at runtime.

## install

    npm install
    npm run build

dev extensions compile locally, never auto-update, and stop working if this folder moves.
