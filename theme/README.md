# theme setup — reproducible by hand (no nix required)

three separate pieces. all hex values below are the current live config.

## 1. surfaces — `manifest.json` (theme extension)

neutral grey, elevation in three flat steps. load unpacked from this folder.

| key | value | role |
|---|---|---|
| frame | `#1E1F22` | window frame (deepest) |
| frame_inactive | `#18191B` | |
| background_tab / inactive | `#1E1F22` / `#1A1B1E` | inactive tabs melt into frame |
| background_tab_hover | `#26272B` | |
| toolbar / hover | `#26272B` / `#2D2E33` | lifted surface |
| toolbar_button_icon | `#C9CED6` | |
| toolbar_separator | `#26272B` | = toolbar, so vertical seams vanish |
| tab_text / tab_background_text | `#E8EAED` / `#8A9099` | |
| bookmark_text | `#C9CED6` | |
| button_background | `#2A2B30` | |
| ntp_background | `#353535` | matches blank.html |

note: `omnibox_*` keys are ignored by gm3 chrome (hardcoded tokens).
note: the toolbar divider is NOT themeable — it renders as 0.8×toolbar + 0.2×white.

## 2. accents — the seed color (chrome profile pref)

focus ring, highlights, selection tints are GENERATED from the seed.

- keys: `browser.theme.user_color` AND `browser.theme.user_color2` in the
  profile's `Preferences` (plain JSON)
- **user_color is the MAIN ACCENT key** (proven 2026-09-09 by isolation test —
  the old "inert legacy" claim was WRONG). `user_color2` is the picker's seed
  slot; theme-extension activation wipes it at launch. write BOTH.
- current value: **`#7C4DFF` (violet)** = signed int32 `-8630785`
  (NOTE: older docs said -8883713 — that value is actually #7871FF, stale/wrong)
- encoding: SkColor `0xAARRGGBB` as signed int32. conversion:
  `int32 = 0xFF000000 + (R<<16) + (G<<8) + B`, interpreted as signed
- `user_color` = the main accent key — NOT inert (earlier conclusion disproven)
- `user_color2` = the picker's slot; wiped by theme ext activation at launch
- `saved_local_theme` = pointer to a picker swatch preset; **delete this key** or
  it outranks the color keys
- to apply: fully quit chrome (⌘Q), edit `Preferences`, relaunch.
  chrome rewrites this file on exit — never edit while running.
- sync: turn sync off or the account copy (`account_values.browser.theme`)
  will stomp local values.
- black seed does NOT work: palette generation needs chroma; black (zero chroma)
  silently falls back to the default blue palette. that's why the picker has no
  black swatch.

## 3. favicon — blank.html inline SVG

the new tab favicon is an inline SVG starburst in `#C7B8E8` via `<link rel="icon">`
(data URI). loads after the page, so there's a brief white→lavender recolor
(extension icon shows first — unavoidable, see below). toolbar icon stays the
separate white PNG.

## icons — extension PNGs

`icon16/32/48/128.png` = white 8-point starburst (rendered from the 256-viewbox
path, 0.99 fit, 4x supersampled). the extension icon is the toolbar icon AND the
initial favicon. recoloring the PNGs changes all three at once (regenerating them
in lavender removes the favicon flash but recolors the toolbar icon too — decided
against).

## verification checklist

- [ ] chrome://extensions → both extensions loaded (cobalt, cobalt-theme), no errors
- [ ] new tab: #353535 page, grey chrome, "New Tab" title, lavender favicon
- [ ] address bar focus ring: violet
- [ ] youtube: no shorts anywhere, /shorts/ links open as normal videos
