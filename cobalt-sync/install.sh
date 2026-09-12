#!/bin/bash
# cobalt — install the sync CLI into ~/.local/bin
#   ./install.sh            install (symlink)
#   ./install.sh uninstall  remove symlink
set -euo pipefail
cd "$(dirname "$0")"

BIN="$HOME/.local/bin/cobalt"

if [[ "${1:-}" == "uninstall" ]]; then
  rm -f "$BIN"
  echo "removed: $BIN"
  exit 0
fi

command -v python3 >/dev/null || { echo "python3 is required"; exit 1; }

mkdir -p "$HOME/.local/bin"
ln -sfn "$PWD/cobalt" "$BIN"

echo "installed: $BIN -> $PWD/cobalt"
echo "config:    ~/.config/cobalt.conf (see cobalt.conf.example)"
