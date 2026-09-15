#!/bin/bash
# erythrite — living wallpaper daemon: build, sign, install to ~/.local/bin, register launchd agent
#   ./install.sh            build + install + start
#   ./install.sh uninstall  stop agent, remove plist + binary (config + video stay)
set -euo pipefail
cd "$(dirname "$0")"

NAME="erythrite"
LABEL="dev.cobalt.$NAME"
BIN_LOCAL="$HOME/.local/bin/$NAME"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
GUI="gui/$(id -u)"

if [[ "${1:-}" == "uninstall" ]]; then
  launchctl bootout "$GUI/$LABEL" 2>/dev/null || true
  rm -f "$PLIST" "$BIN_LOCAL" /tmp/$NAME.pid
  echo "uninstalled: agent stopped, plist + $BIN_LOCAL removed"
  echo "(config at ~/.config/$NAME.conf and your videos were left alone)"
  exit 0
fi

command -v swiftc >/dev/null || { echo "swiftc is required (xcode-select --install)"; exit 1; }

if security find-identity -v -p codesigning | grep -q "cobalt-dev"; then
  IDENTITY="cobalt-dev"
else
  echo "note: no 'cobalt-dev' identity found — signing ad-hoc (fine, no permissions needed)"
  IDENTITY="-"
fi

echo "building (swiftc)"
mkdir -p "$HOME/.local/bin"
swiftc -O -o "$BIN_LOCAL" main.swift \
  -framework AppKit -framework AVFoundation -framework QuartzCore -framework IOKit
codesign --force --sign "$IDENTITY" "$BIN_LOCAL"
if [[ "$IDENTITY" != "-" ]]; then echo "signed (cobalt-dev)"; fi

launchctl bootout "$GUI/$LABEL" 2>/dev/null || true
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN_LOCAL</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/tmp/$NAME.err</string>
</dict></plist>
EOF
launchctl bootstrap "$GUI" "$PLIST"

echo
echo "installed: $BIN_LOCAL"
echo "launchd:   $LABEL — starts at login, restarts on crash, logs: /tmp/$NAME.err"
echo
echo "permissions: none — no accessibility, no input monitoring, no network"
echo "next step:  $NAME monitors"
echo "            $NAME set --monitor \"<name from monitors>\" <video-file>"
