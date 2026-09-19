#!/bin/bash
# smalt — one-time setup: grant the battery click passwordless Low Power Mode
# toggling. validates the rule with visudo before installing, never edits a
# live sudoers file blind.
#   ./enable-lpm.sh          (you'll be asked for your password — LAST time)
#   ./enable-lpm.sh remove   undo it
set -euo pipefail
cd "$(dirname "$0")"

# under sudo, $USER is root — the rule must name the invoking user
OWNER="${SUDO_USER:-$USER}"
FILE=/etc/sudoers.d/smalt-lpm
RULE="$OWNER ALL=(root) NOPASSWD: /usr/bin/pmset -a lowpowermode 0, /usr/bin/pmset -a lowpowermode 1"

if [[ "${1:-}" == "remove" ]]; then
  if [[ $EUID -ne 0 ]]; then echo "run as root: sudo ./enable-lpm.sh remove" >&2; exit 1; fi
  rm -f "$FILE"
  echo "removed: $FILE — battery click falls back to the password prompt"
  exit 0
fi

if [[ $EUID -ne 0 ]]; then
  echo "one-time setup — run as root:" >&2
  echo "  sudo ./enable-lpm.sh" >&2
  exit 1
fi

TMP=$(mktemp /tmp/smalt-lpm.XXXXXX)
echo "$RULE" > "$TMP"
chmod 440 "$TMP"
if ! visudo -cf "$TMP" >/dev/null; then
  rm -f "$TMP"
  echo "visudo rejected the rule — nothing written" >&2
  exit 1
fi
mv "$TMP" "$FILE"
chown root:wheel "$FILE"
chmod 440 "$FILE"

echo "done: $FILE"
echo "smalt's battery click now toggles Low Power Mode instantly — no password, ever"
