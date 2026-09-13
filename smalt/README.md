# smalt

ground cobalt glass

for centuries, if you wanted a strip of cobalt blue across something — stained
glass, porcelain, delft tile — you ground cobalt glass into powder and laid it
down. smalt is that glass: a floating cream pill docked at the right edge of
the screen, dead center. hidden by default, summoned by the cursor.

## the design system

one file owns every visual decision (`Theme` in main.swift) — palette, grid,
type. nothing is hand-placed:

- **palette** — glass `#FAF6F3`, ink `#99947F` (strokes + labels), ink deep
  `#3D3829` (the darker on-palette ink, battery percentage), LPM yellow.
- **grid** — one uniform `CELL × CELL` slot per widget (`cell 28 / gap 8 /
  pad 11`); the pill is exactly its grid: `pad + 4 slots + gaps + pad`.
- **icons** — real heroicons, drawn on heroicons' own 24×24 grid at 1.5
  stroke, scaled to `iconSize` (20pt) so the stroke (1.25pt) scales with the
  glyph and can never drift from it.
- **type** — SF Pro tabular digits at medium, sized so the stems sit at the
  icon stroke weight. text is centered by glyph ink (CoreText), not line
  height — line-height centering is what leaves digits riding high.
- **slots** — battery / calendar / hour / minute, each drawn only inside its
  own fixed slot, optically centered in it.

## how it works

a borderless panel at level 21 (above app and fullscreen windows, below the
native menu bar), pinned to every desktop space (`canJoinAllSpaces` +
`stationary` + `fullScreenAuxiliary`).

fullscreen detection is the same trick cobalt-60 uses — a layer-0 window
matching the display's bounds means a fullscreen app owns the screen.
mission control fakes that check (it puts every space's windows "onscreen"),
so the dock's full-screen backdrop is the signal to get off the stage.

the reveal is a **global mouse monitor, not an event tap** — nothing is
intercepted, nothing is rewritten. that's why smalt needs zero permissions.

## behavior

hidden everywhere by default. visibility is purely a function of the cursor,
with hysteresis so jitter can't flicker it:

| situation | pill |
|---|---|
| idle | hidden (off-screen right) |
| cursor enters the right edge, level with the pill (±26px) | springs out |
| cursor drops left of the pill (or past its band) | springs away |
| mission control | off the stage |
| display change | snaps to the new geometry (no slide) |

the reveal is driven by a real underdamped spring (ω ≈ 23.7 rad/s, ζ ≈ 0.68)
on a screen-attached `CADisplayLink` (plain-timer fallback pre-14 / when the
link goes quiet). it retargets mid-flight, so a fast in-out is a smooth
reversal — no completion handlers, no races, zero CPU between animations.

the summon zone (12px) sits just past cobalt-60's 5px wall clamp on purpose:
the hover works whether the wall is relaxed, lagging, or not running at all —
the wall and the reveal never fight over the same pixel.

## commands

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

**none.** the reveal is a global mouse monitor, not an event tap; nothing is
polled. smalt is invisible to TCC. (signing with `cobalt-dev` is kept up
anyway, so any permission a later version earns survives rebuilds.)

## notes

- logs: `/tmp/smalt.err`
- main display only in v0 — secondary displays get the pill later
- constants: `cell/gap/pad`, `iconSize`, `typeSize/pctSize` in `Theme`;
  `PILL_RADIUS`, `REVEAL_WIDTH` (12px), `HIDE_MARGIN` (6px) in main.swift
- the pill is clickable; widgets don't do anything yet — v1 flips that
- focus: the panel can never become key (`OverlayPanel`) — a menu bar takes
  clicks, never keystrokes; the app beneath keeps focus hovered or clicked
- cursor: while the cursor is over the glass, smalt owns it (arrow) —
  defended on mouse moves AND passively re-won at 20Hz, since apps beneath
  re-assert their I-beam/resize cursors on redraw with no mouse event
- clicks: hidden glass = click-through (the edge belongs to the apps again);
  visible glass = smalt takes the click. cmd-override still forces
  click-through at any visibility
- coexists with cobalt-60: the wall holds the cursor 5px below the menu bar,
  nowhere near the pill's mid-right-edge band — they never fight
