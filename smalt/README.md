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
- **icons** — Material Design 3 SVG assets loaded through one AppKit renderer
  on their own 24×24 grid, scaled to `iconSize` so every glyph keeps its
  optical balance — one uniform scale, no per-icon tuning.
- **type** — SF Pro tabular digits at medium, sized so the stems sit at the
  icon stroke weight. text is centered by glyph ink (CoreText), not line
  height — line-height centering is what leaves digits riding high.
- **slots** — a stack (`Theme.slots`) where each widget claims one or more
  cells (`span`) — a span of N cells is one continuous region with no gaps
  inside; the gap only separates widgets. battery / calendar / hour /
  minute / headphones / bluetooth / microphone each take 1, the slider
  takes 5. containers, hit-testing and the debug grid all derive from the
  list.

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
| cursor rests on the bluetooth rune (120ms dwell) | the glass itself extends leftward out of the pill's edge — fused, one silhouette, one shadow; closes 180ms after the cursor leaves rune + panel |
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
  `sliderTrack` (M3 metric) + `sliderHandle` (24pt — bigger than M3's 18dp, smalt skin) in `Theme`;
  `PILL_RADIUS`, `REVEAL_WIDTH` (12px), `HIDE_MARGIN` (6px) in main.swift
- the span-5 slider below the time is Material Design 3's shape language
  (4dp track, round handle) drawn with CG in the palette — the same cool
  taupe styling the keyboard-brightness slider always wore (#75564F value
  run, #5E463F under the cursor), the Night-Day SVG at rest swelling to a
  live percentage (tabular semibold, shrink-to-fit) while you drag,
  lingering ~1.5s after release, then back to the icon. the value it
  reads and writes is Night Shift's now: it drives `CBBlueLightClient`
  — the Night Shift pane's own client class — `getStrength:` /
  `setStrength:commit:`, the pane's own call path. the slider IS the live
  strength (0 = shallow, 1 = intensive; System Settings calls it
  Less/More) and samples it on the same 30Hz/2Hz clock, so the sunset →
  sunrise ramp glides the knob on its own while you watch. two hard-won
  system facts shaped the Night Shift side: the applied warmth is its own
  layer — schedule Off alone leaves the screen warm, so OFF also pins the
  applied CCT to neutral 6000K; and the client caches the schedule, so
  every call builds a FRESH client (a long-lived one reads stale — that's
  the bug that once made drag-back-up fail to re-arm). dragging to zero
  switches the schedule Off; dragging back up re-arms exactly what was
  there. verify from the terminal: `smalt night status | off | <0..1>`
  (the warm moon-slider variant — lamp-amber ink, OFF face — lives on in
  the code, parked with no slot.)
- the pill is clickable; widgets don't do anything yet — v1 flips that
- focus: hover = attention. while the cursor is on the glass the panel
  takes KEY status (`OverlayPanel` canBecomeKey + `strip.makeKey()`) —
  cursor rects go live (the arrow is law, no redraw race) and keystrokes
  land on the pill. when the cursor leaves, the panel drops key (orderOut
  + orderFront, no activation anywhere) and the active app's window
  regains key on its own — no re-click. the app beneath stays frontmost
  the entire time; no menu-bar flash, no activation denial.
- cursor: pinned by key-window cursor rects while hovered, reasserted on
  mouse moves and passively at 30Hz as a fallback during handoffs
- clicks: hidden glass = click-through (the edge belongs to the apps again);
  visible glass = smalt takes the click. cmd-override still forces
  click-through at any visibility
- coexists with cobalt-60: the wall holds the cursor 5px below the menu bar,
  nowhere near the pill's mid-right-edge band — they never fight
