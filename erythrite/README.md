# erythrite

living wallpaper. a looping video — or a still image — behind everything:
apps, widgets, desktop icons, the glass menu bar. every display gets its own,
bound by name and remembered. the thing macOS won't give you: different
wallpapers per display, *and* per-display videos, on the desktop layer, with
a legibility scrim.

not a hack of the native wallpaper: a daemon that owns one borderless window
per display at the desktop window layer. above the static wallpaper, below
the desktop icons, so the desktop keeps working (icons float over the video)
and the menu bar / dock blur over it like glass. the native wallpaper is
untouched and still there underneath — quit erythrite and it's back.

## why it's safe

this is the point of the tool, so it's stated plainly:

- **built from source, on your machine.** `swiftc main.swift`. the binary in
  `~/.local/bin` is compiled from the one file in this folder and nothing else.
- **no updater.** no Sparkle, no feed, no phone-home. the binary only changes
  when you re-run `install.sh` yourself. the supply chain is: you, your
  compiler, this file.
- **no permissions.** no accessibility, no input monitoring, no screen
  capture, no sandbox escape. AppKit + AVFoundation only.
- **no network.** the binary doesn't open a socket. verify: `lsof -p $(pgrep erythrite)`.

read the source before you build it. it's ~450 lines. that's the whole point.

## how it works

one borderless `NSWindow` per display at `kCGDesktopWindowLevel`, with:

- `ignoresMouseEvents` — the desktop stays fully clickable through the video
- `canJoinAllSpaces + stationary` — present on every space, out of Mission Control
- `AVPlayerLayer` + `AVPlayerLooper` — gapless loop, hardware HEVC decode, muted

one `AVQueuePlayer` feeds every display's layer, so the loop stays in sync
across monitors. a `CALayer` scrim (default 22% black) sits over the video
for legibility — tune per video in the config.

power discipline: on battery, low power mode, or sleeping displays the
player freezes on the current frame (`rate = 0`, decode stops) and resumes
when power returns. display connect/disconnect and resolution changes
rebuild the windows.

## displays are set individually, by name

there is no default display. every monitor is bound by hand:

    erythrite monitors                              # names, resolutions, what's playing
    erythrite set --monitor "AG271QG4" ~/Movies/odyssey.mp4
    erythrite set --monitor "Built-in Retina Display" ~/pics/dune.png --scrim 0.1

any file works: **video** (mp4/mov, hevc/h264, loops) or **image** (png, jpg,
heic, tiff, gif, bmp, webp — a still layer, zero decode cost, pause/resume
no-op). mix freely: video on one display, image on another.

`--monitor` is required — even with a single display. the config file is the
cache: each display's binding is remembered, so a monitor keeps its video
across reboots, and a display that isn't connected right now keeps its block
and re-applies the moment it appears. dock at home, dock away — each setup
remembers itself.

unconfigured displays show the native wallpaper and are left alone.

## config — ~/.config/erythrite.conf

one block per display, keyed by the name from `erythrite monitors`. you can
hand-edit; the daemon picks up changes within 5s (or `erythrite reload`).

    battery-pause on              # freeze on battery + low power mode

    monitor "Built-in Retina Display"
    video ~/Movies/TOP G.mp4
    scrim 0.15                    # black veil, 0–1 (legibility dial)
    gravity fill                  # fill (crop) or fit (letterbox)

    monitor "AG271QG4"
    video ~/Movies/odyssey.mp4

## commands

    erythrite monitors                              # list displays + what's on them
    erythrite set --monitor "NAME" FILE             # bind a video to a display
          [--scrim 0.15] [--gravity fill|fit]
    erythrite pause                                 # freeze on the current frame
    erythrite resume                                # unfreeze
    erythrite reload                                # re-read the config
    erythrite status                                # per-display state

`install.sh` and `install.sh uninstall` install or remove the whole thing
(binary + launchd agent `dev.cobalt.erythrite`).

## notes

- desktop icons show through. that's the design — the video is *behind* the
  desktop, not *instead of* it. hide the icons if you want a pure wall.
- fullscreen apps cover it (a fullscreen app owns the screen) — it's still
  playing underneath, costs the same, and is there when you come back.
- hevc/h264 mp4 or mov, any resolution. 4k 60fps plays fine on m-series;
  expect a few % cpu while playing, ~0 while frozen.
- the lock screen is Apple's domain — its wallpaper is drawn by WallpaperAgent
  in another session's context, and no third-party process can draw there.
  (wallspace gets in via a private `WallpaperExtensionKit` appex — the
  sanctioned-but-undocumented route. possible someday; not in scope here.)

## install

    ./install.sh            build, sign, install, register launchd agent, start
    ./install.sh uninstall  stop agent, remove plist + installed binary
