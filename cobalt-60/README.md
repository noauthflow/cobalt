# cobalt-60

the radioactive isotope of cobalt

a daemon that keeps the mouse cursor from entering the top 5px of the screen (the menu bar area).

## how it works

an event tap (`CGEventTapCreate` on the HID tap) intercepts `mouseMoved`, `leftMouseDragged` and `otherMouseDragged` events **mid-flight** — before the window server delivers them. out-of-bounds events are rewritten in place: the y coordinate is clamped to 5px below the menu bar, so the cursor never crosses the line and never flickers. there is no polling, no correction loop, no lag; when the mouse is still the process sits in its run loop at 0% cpu.

the boundary is computed from the screen's `visibleFrame` (which excludes the menu bar), and recomputed on display changes — resolution switches, monitor plug/unplug.

## install

    ./install.sh            build, sign, install, register launchd agent, start
    ./install.sh uninstall  stop agent, remove plist + installed binary

what it does: builds with swiftc, signs with the `cobalt-dev` codesign identity if present, copies the binary to `~/.local/bin/cobalt-60`, writes `~/Library/LaunchAgents/dev.cobalt.cobalt-60.plist`, and bootstraps the agent. the daemon starts at login and restarts on crash (`RunAtLoad` + `KeepAlive`).

## permissions

**Accessibility** (system settings → privacy & security → accessibility). the event tap is the entire mechanism — without the grant, tap creation fails and the daemon writes the reason to its log and exits (launchd restarts it, it tries again, forever, politely).

the binary is installed to `~/.local/bin/cobalt-60` — that exact path is what you add to the accessibility list. signing with `cobalt-dev` matters here: ad-hoc (unsigned) builds change hash every rebuild and invalidate the grant; a signed build keeps it.

## notes

- logs: `/tmp/cobalt-60.err`
- the margin is 5px — constant `TOP_MARGIN` in main.swift if you want to change it
- shows up in system settings → general → login items → "allow in the background"
