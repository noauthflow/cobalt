#!/bin/bash
# cobalt tab switcher — build + register with launchd (macos, swift, no Xcode app needed)
set -euo pipefail
cd "$(dirname "$0")"

BIN="$PWD/cobalt-switcher"

echo "building (swiftc)"
swiftc -O -o "$BIN" main.swift tap.swift overlay.swift browser.swift favicon.swift \
  -framework AppKit -framework ApplicationServices -framework OSAKit

# sign with the persistent self-signed cert if it exists — keeps the
# accessibility grant valid across rebuilds (ad-hoc binaries invalidate it)
if security find-identity -v -p codesigning | grep -q "cobalt-dev"; then
  codesign --force --sign "cobalt-dev" "$BIN"
  echo "signed (cobalt-dev) — accessibility grant survives rebuilds"
else
  echo "NOTE: no 'cobalt-dev' codesigning cert found; rebuilds will need a re-grant."
  echo "      create once: keychain access -> certificate assistant -> create certificate"
  echo "      name: cobalt-dev, type: self-signed root, type: code signing"
fi

PLIST="$HOME/Library/LaunchAgents/dev.cobalt.switcher.plist"
launchctl bootout "gui/$(id -u)/dev.cobalt.switcher" 2>/dev/null || true
rm -f "$PLIST"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.cobalt.switcher</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/tmp/cobalt-switcher.err</string>
</dict></plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo
echo "installed: $BIN"
echo "launchd:   starts at login, restarts on crash"
echo
echo "one-time setup:"
echo "  1. system settings -> privacy & security -> accessibility"
echo "     remove any stale cobalt-switcher entry, add: $BIN"
echo "     (the daemon polls every 10s and attaches itself once granted)"
echo "  2. first ctrl+tab pops ONE automation prompt ('control Chromium') -> allow"
echo "  3. logs: tail -f /tmp/cobalt-switcher.err"
