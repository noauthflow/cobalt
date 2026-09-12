# smalt

ground cobalt glass

a strip of cobalt glass laid across the top of the screen. for centuries, a
strip of cobalt blue on something meant you ground cobalt glass into powder
and laid it down — stained glass, porcelain, delft tile. smalt is that strip
for the desktop.

this is the first panel of the cobalt menu bar. v0 scope is deliberately
tiny: **the strip and its behavior** — no widgets, no config. the clock,
battery, updates, toggles and everything else arrive later, painted onto
the glass one at a time.

## how it works

a borderless window at the menu bar's own window level, pinned to every
desktop space (`canJoinAllSpaces` + `stationary` + `fullScreenAuxiliary` —
the same flags cobalt-60 uses for its corner filler). it's a pane of glass:
it sits above every app and ignores mouse events entirely.

fullscreen detection is the same trick cobalt-60 uses — a layer-0 window
matching the display's bounds means a fullscreen app owns the screen.
mission control fakes that check (it puts every space's windows "onscreen"),
so the dock's full-screen backdrop is the signal to get off the stage.

the reveal is a **global mouse monitor, not an event tap** — nothing is
intercepted, nothing is rewritten. that's why smalt needs zero permissions.

## behavior

hidden everywhere by default. the strip has no steady state — visibility is
purely a function of the cursor:

| situation | strip |
|---|---|
| idle (desktop or fullscreen) | hidden |
| cursor enters the top edge — 12px from screen top in fullscreen, 12px below the menu bar on desktop | slides down (0.08s) |
| cursor drops below the strip | slides away |
| mission control | off the stage |
| display change | snaps to the new geometry (no slide) |

on the desktop the hidden strip lives above the screen, behind the menu
bar's airspace — the summon slides it out from under the native bar. in
fullscreen it slides in from behind the top edge. between the summon line
and the dismiss line there's hysteresis, so cursor jitter can't flicker it.

the summon zone is wider than cobalt-60's 5px wall clamp on purpose: the
hover works whether the wall is relaxed, lagging, or not running at all —
the wall and the reveal never fight over the same pixel.

## commands

the installed binary is on your PATH, so it controls itself:

    smalt on       start the daemon (after install.sh)
    smalt off      stop the daemon (starts again at next login — the launchd plist stays)
    smalt status   installed / loaded / running

`install.sh` and `install.sh uninstall` remain the way to install or remove
the whole thing (binary + launchd agent).

## install

    ./install.sh            build, sign, install, register launchd agent, start
    ./install.sh uninstall  stop agent, remove plist + installed binary

what it does: builds with swiftc, signs with the `cobalt-dev` codesign
identity if present (ad-hoc otherwise — fine for v0), copies the binary to
`~/.local/bin/smalt`, writes `~/Library/LaunchAgents/dev.cobalt.smalt.plist`,
and bootstraps the agent. the daemon starts at login and restarts on crash
(`RunAtLoad` + `KeepAlive`).

## permissions

**none.** the reveal is a global mouse monitor, not an event tap; the strip
ignores mouse events; nothing polls. smalt is invisible to TCC. (signing
with `cobalt-dev` is kept up anyway, so any permission a later version earns
survives rebuilds.)

## notes

- logs: `/tmp/smalt.err`
- main display only in v0 — secondary displays get the strip later
- constants: `BAR_HEIGHT` (26px), `REVEAL_HEIGHT` (12px), `HIDE_MARGIN` (6px), `SLIDE_DURATION` (0.08s) in main.swift
- the summon zone (6px) sits just below cobalt-60's 5px wall clamp, so the
  reveal works whether or not the wall has relaxed yet
- the strip's window ignores mouse events in v0; widgets (v1) flip that
- coexists with cobalt-60 today: on desktops the wall holds the cursor 5px
  below the menu bar — exactly the summon zone's outer edge, so pushing the
  cursor against the bar summons the strip; in fullscreen the wall relaxes
  and the zone starts at the top edge
- the native menu bar is untouched in v0 — hiding it (`_HIHideMenuBar`) is a
  separate, reversible step once the strip has proven itself
