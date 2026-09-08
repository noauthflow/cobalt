# chrome: undocumented behavior notes

maintainer documentation for chrome internals discovered while building cobalt.
none of this is in official documentation. findings verified against the exact
build below; behavior may differ on other versions.

- date: 2026-09-09
- chrome: 152.0.7977.83 (installed as /Applications/Chromium.app, Google Chrome branding)
- profile used for testing: `~/Library/Application Support/Google/Chrome/Default`

## seed color preferences

theme/accent colors are stored as plain JSON in the profile's `Preferences`
file under `browser.theme.*`. values are SkColor `0xAARRGGBB` packed into a
**signed int32**. conversion: `int32 = 0xFF000000 + (R<<16) + (G<<8) + B`,
interpreted as signed. example: `#7C4DFF` → `0xFF7C4DFF` → `-8630785`;
`#000000` → `-16777216`.

two keys exist and they do different things:

- `browser.theme.user_color` — controls the address bar focus ring color and
  the highlight color inside the address bar.
- `browser.theme.user_color2` — changes some default icon colors.

the full spectrum of what each key affects is untested; the above are the
directly observed effects.

additional properties of these keys:

chrome's theme model is a background color plus two accent slots. in the GUI,
the accents can only be changed indirectly — by selecting one of the
predefined themes, each of which ships its own accent pair. there is no GUI
control for setting accents under a custom theme. modifying the preference
keys below directly does work, but applying a custom theme (extension or
pack) resets the accent prefs to defaults: they are per-theme state, not
global state. observed: theme-extension activation deletes `user_color2` at
launch; `user_color` has survived so far.

- `browser.theme.saved_local_theme` (when present) is a pointer to a Customise
  Chrome picker swatch preset and outranks the color keys. delete it when
  writing colors manually.
- the Customise Chrome GUI picker writes only `user_color2` (verified by
  file diff on swatch pick).
- chromium main source labels the prefs as `kDeprecatedUserColorDoNotUse` =
  `browser.theme.user_color` and `kUserColor` = `browser.theme.user_color2`.
  observed behavior on this build does not match that labeling; version
  drift is likely.
- a zero-chroma seed (pure black) produces no generated palette; chrome falls
  back to the default blue. near-black with hue may work.

procedure for editing: fully quit chrome (⌘Q, not window close), edit
`Preferences`, relaunch. chrome rewrites this file on exit; edits made while
running are clobbered. `cobalt seed <hex>` automates all of this: writes both
color keys, deletes `saved_local_theme`, mirrors the value into
`account_values.browser.theme.user_color` if present, refuses while the
browser is running (`--force` overrides), and backs up the file to
`Preferences.cobalt-bak` first.

## theme extensions vs seed colors

two independent systems:

1. theme extensions — a manifest with a `theme` key. static colors/images.
   outranks seed colors for the surfaces they define.
2. seed color prefs (above) — drive generated accents.

both coexist: grey surfaces from a theme extension + violet accents from
`user_color` is the current setup.

**fatal mv3 rule**: a manifest containing BOTH a `theme` key and any
functional feature (`content_scripts`, `chrome_url_overrides`, background
worker) is silently rejected. chrome treats it as a theme package and themes
cannot be extensions. themes must live in a separate extension folder.
rejection is silent: the extension does not appear anywhere.

other theme-extension facts:

- `omnibox_*` theme keys are ignored by this build (gm3 hardcodes omnibox
  tokens).
- theme-type extensions do not appear in chrome://extensions on this build;
  no reload GUI exists. unpacked themes re-read their manifest at every
  browser launch, so quit + relaunch reloads them.
- `theme_toolbar` images are tiled in both directions; height must match the
  toolbar (~40px) or it bands.

## toolbar divider

the toolbar's bottom edge (bottom ~3px on every page) renders as
`0.8 × toolbar_color + 0.2 × white`. no theme key controls it;
`toolbar_separator` does not affect it. the divider is therefore always a
white-tinted line and cannot be removed through theming. the only way to make
it invisible is a toolbar color of ~`#020202`, which defeats the purpose of
a custom toolbar color.

## omnibox site shortcuts do not sync

chrome's site shortcuts (omnibox keyword engines, e.g. `yt` →
youtube.com) do not survive google sync: they are lost on uninstall or when
moving to another device. chrome sync cannot be used to maintain a fixed set.

cobalt is the only mechanism for keeping a defined set of keyboard shortcuts
in the omnibox that map to specific URLs and is configurable in a plain dot
file (`~/.config/cobalt.conf`): `cobalt push` writes the bar and engines
exactly as specified; `cobalt pull` reads them back.

## telemetry channels (152.0.7977.83, privacy config applied)

with sync off, suggestions off, standard safe browsing, basic spellcheck,
metrics off, and web & app activity off, the remaining content-bearing
channels are:

- safe browsing standard: truncated URL hashes, only on locally-matched
  suspicious URLs
- translate: page text, only when invoked
- privacy sandbox: only if enabled (chrome://settings/adPrivacy)

everything else is version/metadata chatter. the stock new tab page phones
home for tiles/logos; a blank NTP override (`extension/blank.html`) removes
that channel.

## repo changes in this revision

- `extension/` — new tab extension restructured: `blank.html` (#353535 NTP
  override), `block.js` (youtube shorts blocker), `hide.css`, icons/.
- `theme/` — separate theme extension (grey surfaces; must be separate per
  the mv3 rule above) + repro documentation.
- `cobalt seed` — new CLI subcommand; see seed color section above.
