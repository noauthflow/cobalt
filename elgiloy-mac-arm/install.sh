#!/bin/bash
# elgiloy — tab overlay daemon: build, sign, wrap in an .app bundle, register launchd agent
#   ./install.sh            build + install + start
#   ./install.sh uninstall  stop agent, remove plist + bundle
set -euo pipefail
cd "$(dirname "$0")"

NAME="elgiloy"
LABEL="dev.cobalt.elgiloy"
BUNDLE_ID="dev.cobalt.elgiloy"
APP="$HOME/Applications/cobalt/Elgiloy.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
GUI="gui/$(id -u)"

if [[ "${1:-}" == "uninstall" ]]; then
  launchctl bootout "$GUI/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  rm -rf "$APP"
  echo "uninstalled: agent stopped, plist + $APP removed"
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
swiftc -O -o "$NAME" main.swift tap.swift overlay.swift browser.swift favicon.swift \
  -framework AppKit -framework ApplicationServices -framework OSAKit
codesign --force --sign "cobalt-dev" "$NAME"
echo "signed (cobalt-dev)"

# the daemon sends apple events to chromium ("control chrome") — tcc can only
# show the automation prompt for a process with an app bundle identity; a bare
# binary launched by launchd gets silently auto-denied (-1743, no popup).
# so the signed binary lives inside a minimal .app bundle, and launchd runs it there.
mkdir -p "$APP/Contents/MacOS"
cp -f "$NAME" "$APP/Contents/MacOS/$NAME"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Elgiloy</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --sign "cobalt-dev" "$APP"
echo "bundled: $APP"

launchctl bootout "$GUI/$LABEL" 2>/dev/null || true
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/$NAME</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/tmp/$NAME.err</string>
</dict></plist>
EOF
launchctl bootstrap "$GUI" "$PLIST"

echo
echo "installed: $APP"
echo "launchd:   $LABEL — starts at login, restarts on crash, logs: /tmp/$NAME.err"
echo
echo "one-time setup (both happen once, then never again — cobalt-dev signature):"
echo "  1. system settings -> privacy & security -> accessibility -> add:"
echo "     $APP"
echo "  2. first ctrl+tab over chromium pops the automation prompt"
echo "     ('Elgiloy wants to control Chromium') -> allow"
