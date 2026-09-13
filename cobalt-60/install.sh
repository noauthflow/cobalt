#!/bin/bash
# cobalt-60 — cursor wall daemon: build, sign, install to ~/.local/bin, register launchd agent
#   ./install.sh            build + install + start
#   ./install.sh uninstall  stop agent, remove plist + binary
set -euo pipefail
cd "$(dirname "$0")"

NAME="cobalt-60"
LABEL="dev.cobalt.cobalt-60"
BIN_LOCAL="$HOME/.local/bin/$NAME"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
GUI="gui/$(id -u)"

if [[ "${1:-}" == "uninstall" ]]; then
  launchctl bootout "$GUI/$LABEL" 2>/dev/null || true
  rm -f "$PLIST" "$BIN_LOCAL"
  echo "uninstalled: agent stopped, plist + $BIN_LOCAL removed"
  exit 0
fi

command -v swiftc >/dev/null || { echo "swiftc is required (xcode-select --install)"; exit 1; }

# the binary must be signed so the accessibility grant survives rebuilds
# (macos anchors permissions to the code signature at grant time)
if ! security find-identity -v -p codesigning | grep -q "cobalt-dev"; then
  cat <<'MSG'
ERROR: no 'cobalt-dev' codesigning identity found.

this daemon must be signed: macos anchors the accessibility permission to
the binary's signature, and a stable identity means the grant survives
rebuilds. create the identity once:

  keychain access -> certificate assistant -> create certificate
  name: cobalt-dev   type: code signing   self-signed root

then re-run ./install.sh
MSG
  exit 1
fi

echo "building (swiftc)"
mkdir -p "$HOME/.local/bin"
# build straight to the install target — nothing lands in the repo folder
swiftc -O -o "$BIN_LOCAL" main.swift -framework AppKit
codesign --force --sign "cobalt-dev" "$BIN_LOCAL"
echo "signed (cobalt-dev)"

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
if ! pgrep -xq "$NAME"; then
  echo "one-time setup:"
  echo "  system settings -> privacy & security -> accessibility"
  echo "  add: $BIN_LOCAL"
fi
