# erythrite

custom videos as **native macOS aerials** — fully animated on the lock screen,
rendered by Apple's own WallpaperAgent. not an overlay, not a daemon, not a
hack of a window layer: the video becomes a first-class aerial indistinguishable
from the ones Apple ships.

## history

this tool had two incarnations.

**v1 (the window daemon):** a Swift launchd agent owning one borderless
`NSWindow` per display at the desktop window layer, `AVPlayerLayer` looping
video behind the desktop icons, scrims, per-monitor bindings, battery pausing.
it worked, but it fought the compositor: windows to manage, Accessibility-adjacent
behaviors, a daemon to keep alive, and the lock screen was untouchable no
matter what.

**v2 (this, formerly a separate experiment called azurite):** macOS 26/27
renders the lock screen — and the desktop's still snapshot — from one
user-writable aerials store. erythrite writes entries there the way Apple's
own pipeline does, and macOS plays your file believing it's theirs. no daemon,
no windows, no permissions, nothing to crash. the old `main.swift` is gone
from the tree (still in git history); the store is the only thing that
remembers anything.

the trade: the desktop shows a **still** — Apple's policy for every aerial,
ours included (video decode never runs behind your icons). the lock screen is
fully animated. v1 animated the desktop and couldn't touch the lock screen;
v2 owns the lock screen natively and accepts Apple's still desktop. if desktop
video ever matters again, that's a window-layer problem, and git history has
the code.

## how it works

    ~/Library/Application Support/com.apple.wallpaper/aerials/
      manifest/entries.json    asset catalog (plain JSON, user-writable)
      videos/<UUID>.mov        HEVC hvc1
      thumbnails/<UUID>.png
      TVIdleScreenStrings.bundle/.../Localizable.nocache.loctable

`erythrite add` puts your video in `videos/`, a thumbnail in `thumbnails/`, an
entry in `entries.json`, and a display-name key in the loctable — exactly the
shape Apple's pipeline writes. it then selects the asset in the wallpaper
store (`Store/Index.plist`) and SIGKILLs WallpaperAgent, which launchd
immediately respawns onto the new state. that's the whole trick.

## the four landmines

the aerials extension validates injected assets and silently falls back to a
baked-in Golden Gate clip when any of these are violated. each was found by
bisecting a byte-identical clone of a real Apple aerial:

1. **file:// URLs must be percent-encoded.** the manifest's `url-*` and
   `previewImage` fields are parsed with `URL(string:)`; a raw space in
   `Application Support` yields nil and the asset is rejected.
2. **`localizedNameKey` must exist in the loctable.** an unknown key rejects
   the asset even if the video bytes are Apple's own. erythrite injects the
   name into all 45 locales.
3. **`subcategories` must be non-empty.** the extension indexes assets by
   subcategory; an empty array rejects the asset.
4. **your own gallery section requires a custom *category*.** subcategories
   only group rows inside Apple's existing sections (Landscapes, Cities, …).
   erythrite creates one shared "Erythrite" top-level category and files
   every injection there.

symptom of any violation: Golden Gate still background,
`WallpaperAerialsExtensionError (0)` in the log, `FigVideoQueue: 0 frames
enqueued`. the one-liner diagnostic:

    lsof -p $(pgrep -f WallpaperAerialsExtension.appex) | grep mov

shows exactly which file the renderer opened.

## commands

    erythrite list                      # injected aerials + what's selected
    erythrite add ~/Movies/odyssey.mp4  # transcode → inject → activate
    erythrite add clip.mov --name "Odyssey" --no-activate
    erythrite add clip.mov --fast       # hardware encode (videotoolbox)
    erythrite use "Odyssey"             # select by name or id (Apple's too)
    erythrite remove Odyssey            # injected assets only; Apple's protected
    erythrite verify --fix              # re-inject after OS updates clobber the store
    erythrite restart                   # restart WallpaperAgent

add `--dry-run` to anything to preview without writing.

every injected asset is marked `shotID=ERYTHRITE_*` and tracked in a ledger at
`~/.config/erythrite.json`. `remove` only ever touches those; Apple's assets
are untouchable. `entries.json` is backed up (10 deep) before every write.

## installing

    ./install.sh          # symlink into ~/.local/bin (also scrubs old-daemon leftovers)
    ./install.sh uninstall

requires python3 and ffmpeg. no permissions, no network, no daemon, no
launchd, no signing identity.

## notes

- **format:** sources are probed; anything that isn't HEVC `hvc1` `.mov` is
  re-encoded to HEVC Main10 to match Apple's aerials (audio stripped — the
  lock screen has no business making noise; `--keep-audio` preserves it).
  already-compatible files are copied as-is. `--fast` uses Apple's hardware
  encoder (near-realtime, larger files); default is libx265 CRF 22 (visually
  transparent, not lossless).
- **activation order matters:** write the store *after* SIGKILLing the agent
  (SIGTERM lets it rewrite the store on quit), then kickstart.
- **OS updates can rewrite the manifest.** that's what `verify --fix` is for:
  the ledger remembers every injection and re-writes the entries (including
  loctable keys). run it if your wallpaper reverts after an update.
- **shuffle:** injected assets set `includeInShuffle: false`, so the aerial
  shuffle never picks them.
- removing an asset leaves its loctable name key behind — harmless, bytes.

read the source before you trust it. it's one python file, ~600 lines.
