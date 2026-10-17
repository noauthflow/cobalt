# safflorite

**Hold ⌘⇧Space** to show a translucent clock pill anchored to the bottom of
every screen: the current time in 24-hour format (`HH:mm:ss`) in large white
mono type inside a hudWindow vibrancy capsule. **Release** to hide — it fades
in/out rather than popping. Clicks pass through the pill.

Named after the cobalt mineral safflorite.

## How it works

- Single `main.swift`, builds with `swiftc`, no dependencies beyond AppKit + Carbon.
- The hotkey is a **Carbon registered hotkey** (`RegisterEventHotKey`), not an
  `NSEvent` global monitor — registered hotkeys need no TCC permissions (no
  Accessibility, no Input Monitoring). Hotkeys only fire on press, so the
  release is detected by polling the physical space key state
  (`CGEventSourceKeyState`, 30ms interval — also permission-free).
- One borderless, transparent, mouse-immune capsule per screen, sized to the
  text plus padding, sitting bottom-centre just above the dock
  (`visibleFrame`), at `.floating` level, joining all spaces.
- Runs as a persistent launchd agent so the hotkey is always live.

## Tunables (top of `main.swift`)

- `pillAlpha` — overall opacity of the pill (default `0.85`)
- `bottomMargin` — gap above the dock (default `12`)
- `hPad` / `vPad` — pill padding around the text (default `36` / `16`)

## Install

```sh
./install.sh            # build + install + start agent
./install.sh uninstall  # stop agent, remove plist + binary
```

- Requires: `swiftc`
- Permissions: none
- Logs: `/tmp/safflorite.err`
