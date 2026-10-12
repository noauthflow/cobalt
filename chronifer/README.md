# chronifer

Live Downloads folder icon: renders the current 24-hour time (HH:mm, locale-independent) in red, dead centre of `blackfolder.icns`, and applies it as the custom icon of `~/Downloads`. A persistent launchd daemon fires exactly on each wall-clock minute boundary and at login.

Named after the cobalt alloy used in Swiss watch cases — chrono + fer.

No permissions needed (no TCC — plain AppKit drawing + `NSWorkspace.setIcon`).

## Install

    ./install.sh            build + install + start agent
    ./install.sh uninstall  stop agent, remove plist + binary, restore default icon

Builds with `swiftc`, ad-hoc signs, copies the binary and `blackfolder.icns` to `~/.local/bin/chronifer`, registers persistent launchd daemon `dev.cobalt.chronifer` (KeepAlive). Logs: `/tmp/chronifer.err`.

## Files

- `main.swift` — renderer + icon applier
- `blackfolder.icns` — base folder art (1024×1024)
