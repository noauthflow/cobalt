#!/bin/bash
# erythrite — install the aerial injector CLI into ~/.local/bin
#   ./install.sh            install (symlink)
#   ./install.sh uninstall  remove symlink
set -euo pipefail
cd "$(dirname "$0")"

BIN="$HOME/.local/bin/erythrite"

if [[ "${1:-}" == "uninstall" ]]; then
  rm -f "$BIN"
  echo "removed: $BIN"
  echo "note: injected aerials stay until removed with \`erythrite remove\`"
  exit 0
fi

command -v python3 >/dev/null || { echo "python3 is required"; exit 1; }
command -v ffmpeg  >/dev/null || { echo "ffmpeg is required (brew install ffmpeg)"; exit 1; }

# scrub leftovers from the old window-daemon incarnation
if [[ -f "$HOME/Library/LaunchAgents/dev.cobalt.erythrite.plist" ]]; then
  launchctl unload "$HOME/Library/LaunchAgents/dev.cobalt.erythrite.plist" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/dev.cobalt.erythrite.plist"
  echo "removed old daemon launchd plist"
fi
rm -f "$HOME/.local/bin/azurite"

chmod +x "$PWD/erythrite"
mkdir -p "$HOME/.local/bin"
ln -sfn "$PWD/erythrite" "$BIN"

echo "installed: $BIN -> $PWD/erythrite"
