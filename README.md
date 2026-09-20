# cobalt

A collection of small, self-contained desktop utilities for macOS (plus one cross-platform CLI and one Chrome extension).

## Contents

| Folder | What it is | OS support |
|---|---|---|
| [cobalt-sync/](cobalt-sync/) | bookmarks + omnibox sync CLI | macOS, linux, windows (auto-detects browser paths; `avatar` subcommand is macOS + Chrome only) |
| [cobalt-60/](cobalt-60/) | cursor wall daemon | macOS |
| [smalt/](smalt/) | menu bar strip daemon | macOS |
| [cerulean/](cerulean/) | completely enable/disable a display (compositor-level) | macOS |
| [erythrite/](erythrite/) | custom videos as native aerials: animated lock screen wallpaper | macOS 26+ |
| [elgiloy-mac-arm/](elgiloy-mac-arm/) | tab overlay daemon | macOS (Apple Silicon) |
| [elgiloy-linux/](elgiloy-linux/) | tab overlay daemon, linux port | linux (in progress) |
| [stellite/](stellite/) | new tab page + shorts blocker Chrome extension + template theme | anywhere Chrome runs |
| [talonite/](talonite/) | Raycast extension: timezones, proxy toggle, color picker, ruler, audio + bluetooth switching | macOS |

Each folder is self-contained: source + its own `install.sh` where applicable. Nothing here depends on anything else in the repo. See each folder's README for details.

## Installation

Each tool installs independently. All install scripts are standalone and idempotent; `./install.sh uninstall` reverses each one.

### cobalt-sync

Symlinks the CLI to `~/.local/bin/cobalt`.

- Requires: Python 3.8+
- Permissions: none (writes browser profile files directly; quit browsers first)

### erythrite

Symlinks the CLI to `~/.local/bin/erythrite`. The old v1 window daemon (`main.swift`, launchd agent) is retired — this incarnation injects into the system aerials store instead: no daemon, no signing identity, no permissions.

- Requires: Python 3.8+, `ffmpeg`
- Permissions: none (writes the user-writable aerials store; restarts WallpaperAgent)
- Injected assets are ledgered and removable (`erythrite remove`); run `erythrite verify --fix` after OS updates

### cobalt-60

Builds with `swiftc`, signs, copies the binary to `~/.local/bin/cobalt-60`, registers launchd agent `dev.cobalt.cobalt-60`.

- Requires: `swiftc`, the `cobalt-dev` signing identity (see below)
- Permissions: Accessibility (rewrites mouse events system-wide)

### elgiloy-mac-arm

Same pipeline as cobalt-60: binary to `~/.local/bin/elgiloy`, launchd agent `dev.cobalt.elgiloy`.

- Requires: `swiftc`, the `cobalt-dev` signing identity
- Permissions: Accessibility + Input Monitoring (listens for ctrl+tab), plus one Automation prompt on first use (queries Chrome's tabs)

### smalt

- Requires: `swiftc`, the `cobalt-dev` signing identity
- See `smalt/README.md` for specifics

### cerulean

Builds with `swiftc`, signs, copies the binary to `~/.local/bin/cerulean`. No launchd — plain CLI.

- Requires: `swiftc`
- Permissions: none (private SkyLight APIs, no TCC involvement)
- `./install.sh uninstall` removes the binary (warns if a display is currently disabled)

### stellite

No install script. Load as an unpacked extension: `chrome://extensions` → Developer mode → Load unpacked → select the folder. The `template-theme/` subfolder is a Chrome theme, not part of the extension — load it separately.

- Permissions: none beyond Chrome itself

### talonite

Raycast extension. Install via Raycast's development extension workflow.

- Permissions: none

## Notes

- Daemons run as launchd agents: start at login, restart on crash, logs at `/tmp/<name>.err`.

## One-time setup: the `cobalt-dev` signing identity

The daemon install scripts sign their binaries with a self-signed codesigning certificate named `cobalt-dev`. macOS anchors TCC permissions to the code signature, so a stable identity means Accessibility grants survive rebuilds.

Create it once:

1. Keychain Access → Certificate Assistant → Create Certificate
2. Name: `cobalt-dev` · Type: Code Signing · Self-Signed Root

Without it, the daemon install scripts refuse to run (and print instructions). Check for it with `security find-identity -p codesigning`.

**Order matters:** the binary must be signed *before* granting it Accessibility — TCC anchors the grant to the signature present at approval time. `install.sh` handles this correctly (it signs before the daemon starts). If you grant Accessibility to a manually compiled, unsigned binary, the grant is anchored to that exact build and the first re-sign invalidates it.
