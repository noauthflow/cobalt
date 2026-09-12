# cobalt

named after the periodic table: three atomic points above chromium (because chromium is better than firefox).

everything in this family is something **made from cobalt** — an alloy, an isotope, a coating — because every tool here is derived from the same base material. each one is named for the material whose personality it borrows:

    cobalt-sync   Co-Al-Ni magnet alloy      sync = magnetic alignment
    cobalt-60     the radioactive isotope    an invisible barrier you don't cross
    elgiloy       Co-Cr-Ni spring alloy      cycles forever without fatiguing
    stellite      Co-Cr wear-proof alloy     a coating that doesn't degrade

## the directories

| folder | what it is |
|---|---|
| [cobalt-sync/](cobalt-sync/) | bookmarks + omnibox sync CLI |
| [cobalt-60/](cobalt-60/) | cursor wall daemon |
| [elgiloy/](elgiloy/) | tab overlay daemon |
| [stellite/](stellite/) | new tab page + shorts blocker extension + template theme |

each folder is self-contained: source + its own `install.sh`. nothing here depends on anything else in the repo. see each folder's README for the full story.

## install — what the scripts do and what they need

all scripts are standalone and idempotent. `./install.sh uninstall` reverses each one.

**cobalt-sync** — symlinks the CLI to `~/.local/bin/cobalt-sync`.
needs python 3.8+. **no special permissions** (writes browser profile files directly; quit browsers first).

**cobalt-60** — builds with swiftc, signs, copies binary to `~/.local/bin/cobalt-60`, registers launchd agent `dev.cobalt.cobalt-60`.
needs swiftc. **Accessibility permission** — it rewrites mouse events system-wide.

**elgiloy** — same pipeline: binary to `~/.local/bin/elgiloy`, agent `dev.cobalt.elgiloy`.
needs swiftc. **Accessibility + Input Monitoring** (listens for ctrl+tab) and one **Automation** prompt on first use (queries chrome's tabs).

**stellite** — no install script; chrome loads unpacked extensions by folder path:
`chrome://extensions → developer mode → load unpacked → <folder>`. **no permissions** beyond chrome itself. (the `template-theme/` subfolder inside is a chrome theme, not part of the extension — load it separately.)

notes: daemons run as launchd agents (start at login, restart on crash, logs at `/tmp/<name>.err`). signing with the optional `cobalt-dev` codesign identity keeps accessibility grants alive across rebuilds — see any daemon README.
