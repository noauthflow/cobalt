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
  `#3D3829` (the darker on-palette ink, battery fill + digits). the battery's
  accents are glaze colors, not traffic lights: cobalt `#0047AB` (charging),
  deep ochre `#9A6D1B` (low power), muted brick `#A34730` (low charge), on a
  glass-warmed shell `#D8D4CB`. digits + bolt are two-tone — deep ink on the
  shell, white inside the fill — so they read wherever the fill edge falls.
  charging is sage `#5E7749` — green says "plugged in" without shouting.
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
- the slider below the time is Material Design 3's shape language (4dp
  track, round handle) drawn with CG in the palette; the knob is the
  readout — the supplied Night-Day SVG at rest, swelling to a live percentage
  (tabular semibold, shrink-to-fit) while you drag, lingering ~1.5s after
  release, then back to the icon;
  it is live — press anywhere in its 5-cell region and drag, and the real
  keyboard backlight follows. it drives the same `KeyboardBrightnessClient`
  (private `CoreBrightness` framework) that the F5/F6 keys use — value
  0–1, no permissions. the slider state is the hardware, and the render
  is decoupled from the sample: smalt samples the hardware at 30Hz while
  the glass is visible (~0.16% of a core — 52µs per read, benchmarked)
  and 2Hz while hidden, and the handle *springs* to each new sample at
  120fps — so fn-key and ambient auto-brightness changes glide in exactly
  like the system's own bezel instead of stepping. there is no push
  channel at user privilege: CoreBrightness posts no darwin notification
  and the Keyboard Backlight HID device rejects listeners (privileged) —
  both were tested; sampling is the only channel macOS gives us
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
