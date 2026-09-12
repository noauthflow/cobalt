# cobalt

named after the periodic table: three atomic points above chromium (because chromium is better than firefox).

## what this is

cobalt started as one tool — a script that pushed a plain text bookmarks config into chrome. then it kept absorbing things: an omnibox engine, a new tab page, a tab overlay, a cursor wall. at some point it stopped being "a chrome bookmarks tool" and became what it actually is:

**a weird range of small utilities that are secretly one setup.** this repo is not a product; it's my machine, written down. every folder is something my desktop does that stock macOS/chrome doesn't, and they're all built from the same metal.

everything here is something **made from cobalt** — an alloy, an isotope, a coating — because each tool is derived from the same base material and named for the material whose personality it borrows:

    cobalt-sync   Co-Al-Ni magnet alloy      sync = magnetic alignment
    cobalt-60     the radioactive isotope    an invisible barrier you don't cross
    elgiloy       Co-Cr-Ni spring alloy      cycles forever without fatiguing
    stellite      Co-Cr wear-proof alloy     a coating that doesn't degrade

## the directories

| folder | what it is | os support |
|---|---|---|
| [cobalt-sync/](cobalt-sync/) | bookmarks + omnibox sync CLI | macOS today — logic is portable (python), browser paths aren't yet |
| [cobalt-60/](cobalt-60/) | cursor wall daemon | **macOS only** — it exists *for* the menu bar; other desktops don't have one |
| [elgiloy/](elgiloy/) | tab overlay daemon | **macOS only** — apple events, event taps, NSPanel; a linux port would be a different program |
| [stellite/](stellite/) | new tab page + shorts blocker extension + template theme | **anywhere chrome runs** — it's just an extension |

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

notes: daemons run as launchd agents (start at login, restart on crash, logs at `/tmp/<name>.err`).

**one-time: the `cobalt-dev` signing identity.** the daemon scripts sign their binaries with a self-signed codesigning certificate named `cobalt-dev` — macOS anchors permissions to the signature, and a stable signature means accessibility grants survive rebuilds. create it once:

    keychain access → certificate assistant → create certificate
    name: cobalt-dev · type: code signing · self-signed root

without it, the daemon install scripts **refuse to run** (and explain how to create the cert) — an unsigned daemon would need its accessibility grant redone after every rebuild. already have it? `security find-identity -p codesigning` will say so. **order matters:** the binary must be signed *before* you grant it accessibility — TCC anchors to the signature it sees at approval time. running `install.sh` first guarantees this (it signs before the daemon ever starts); granting a manually-compiled unsigned binary anchors the grant to that exact build and the first re-sign kills it.
