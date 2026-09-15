#!/bin/bash
# cerulean — complete display enable/disable via private SkyLight APIs
#   ./install.sh            build + install to ~/.local/bin
#   ./install.sh uninstall  remove the binary
set -euo pipefail
cd "$(dirname "$0")"

NAME="cerulean"
BIN_LOCAL="$HOME/.local/bin/$NAME"
STATE_FILE="$HOME/.cerulean_disabled"

if [[ "${1:-}" == "uninstall" ]]; then
  if [[ -f "$STATE_FILE" ]]; then
    echo "warning: $STATE_FILE exists — a display may currently be disabled."
    echo "         Re-enable it before uninstalling: $BIN_LOCAL on-all"
  fi
  rm -f "$BIN_LOCAL"
  echo "uninstalled: $BIN_LOCAL removed"
  exit 0
fi

command -v swiftc >/dev/null || { echo "swiftc is required (xcode-select --install)"; exit 1; }

if security find-identity -v -p codesigning | grep -q "cobalt-dev"; then
  IDENTITY="cobalt-dev"
else
  echo "note: no 'cobalt-dev' identity found — signing ad-hoc (fine: no TCC permissions involved)"
  IDENTITY="-"
fi

echo "building (swiftc)"
mkdir -p "$HOME/.local/bin"
# build straight to the install target — nothing lands in the repo folder
swiftc -O -o "$BIN_LOCAL" cerulean.swift
codesign --force --sign "$IDENTITY" "$BIN_LOCAL"
if [[ "$IDENTITY" != "-" ]]; then echo "signed (cobalt-dev)"; fi

echo
echo "installed: $BIN_LOCAL"
echo
echo "usage:"
echo "  cerulean list          show main + external display IDs"
echo "  cerulean off           completely disable every external display"
echo "  cerulean on            re-enable displays disabled by 'off'"
echo "  cerulean on-all        re-enable everything (emergency reset)"
echo
echo "notes: disabled displays are remembered in $STATE_FILE"
echo "       replug or reboot also re-detects a disabled display"
