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

## profile avatars: two sources — and only one is the toolbar

tested against 153.0.8010.37 (google chrome branding, /Applications/Chromium.app).
the profile avatar has TWO independent image sources, and confusing them cost
most of a day:

1. pak resources (`IDR_PROFILE_AVATAR_*`, see pak format below) — drive the
   avatar gallery and the avatar shown on `chrome://settings/manageProfile`.
   swapping pak image 14356 changes the manage page. it does NOT change the
   toolbar.
2. `<user-data-dir>/Avatars/*.png` — a runtime cache of 192x192 avatar images
   (e.g. `avatar_origami_cat.png`) that chrome populates itself. the toolbar
   profile button reads from THESE files. swapping the file the profile points
   at changes the toolbar.

only #2 is user-serviceable without bundle surgery: it's a plain PNG in the
user's own profile directory. no signature, no TCC, no re-signing. which file
corresponds to which gallery slot: `Preferences -> profile.avatar_index` picks
the slot; the filename mapping was determined empirically (index 27 =
`avatar_origami_cat.png` on this build), not from source.

caveats:

- a chrome **update** rewrites the bundle AND may re-download the Avatars/
  cache. re-run after updates.
- profiles with `profile.using_gaia_avatar = true` (signed-in account picture)
  ignore the Avatars/ folder entirely.
- `Local State` gaia-picture flags (`use_gaia_picture` +
  `gaia_picture_file_name`) are a dead end: on a signed-out profile, chrome
  actively reverts them — deletes the picture file (`Google Profile
  Picture.png`) and clears the name at launch. observed twice. custom
  pictures via that path are defended; don't bother.

## pak v5 format (chrome_100_percent.pak / chrome_200_percent.pak / resources.pak)

reverse-engineered against 153.0.8010.37; layout matches data_pack.cc v5:

    header (12B):  u32 version=5, u32 encoding, u16 resource_count, u16 alias_count
    index:         (resource_count+1) entries of (u16 id, u32 offset)
                   the last entry is a sentinel whose offset == end of blob data
    alias table:   alias_count * 4 bytes (u16 id -> u16 entry index)
    blobs:         raw, uncompressed, no per-entry checksums

verified data point: entry 0 of chrome_100_percent.pak = (id 257, offset 2860)
= 12 + 462*6 + 19*4. layout confirmed.

chrome validates offsets at load (data_pack.cc): any offset past EOF ->
`Data pack file corruption: Entry #N past end` and the pak is dropped
("Some features may not be available") — a loud failure, never silent
corruption. this makes pak edits safe to attempt: if it launches, the pak is
valid.

rebuild procedure that works: parse index, replace blobs, re-serialize with
offsets recomputed so the blob region starts exactly at
12+(count+1)*6+alias_count*4 and the sentinel equals the new file size. the
gotcha that cost a night: the alias table must be written before the blobs —
appending blobs directly after the index shifts every offset by the alias-
table size and chrome rejects the file.

## branded chrome tamper-resistance on macOS

findings from attempting pak edits on google-branded builds:

- editing pak files breaks the codesign resource seal. whether that matters
  depends ENTIRELY on the quarantine attribute:
  - quarantined + broken seal -> Gatekeeper re-validates at launch ->
    "Google Chrome is damaged and can't be opened. You should move it to the
    Bin." (observed. correct — the bundle no longer matches its manifest)
  - quarantine stripped (or already launched once) -> macOS does not
    re-validate the resource seal at every launch. pak edits run fine.
    chrome's own Framework.sig covers the framework binary, not the paks.
- **never re-sign the bundle ad-hoc to "fix" the seal.** the code signature is
  the identity that keychain ACLs and TCC are anchored to. ad-hoc re-signing
  locked chrome out of its own "Chromium Safe Storage" keychain item (cookies
  undecryptable) and triggered TCC blocks ("tried to access data from other
  apps"). the recovery is delete bundle + reinstall; profile data and the
  keychain item survive, and the fresh google-signed binary matches the ACL
  again.
- chrome auto-update rewrites the bundle: pak modifications are reverted.
- unsigned chromium-family builds have none of these defenses — pak edits are
  free there.

## repo changes in this revision

- `extension/` — new tab extension restructured: `blank.html` (#353535 NTP
  override), `block.js` (youtube shorts blocker), `hide.css`, icons/.
- `template-theme/` — separate theme extension (grey surfaces; must be separate per
  the mv3 rule above) + repro documentation.
- `cobalt seed` — new CLI subcommand; see seed color section above.
- `cobalt avatar` — new CLI subcommand; replaces every PNG in
  `<user-data-dir>/Avatars/` with one 192x192 PNG (toolbar profile avatar).
  strict input validation (must be exactly 192x192 PNG, no resizing), refuses
  while the browser is running, backs up to *.cobalt-bak. see profile avatars
  section above. the pak-level swap (manage-page avatar) is deliberately NOT
  automated — documented above, but bundle surgery on branded chrome is not a
  thing a config tool should do silently.
- `cobalt reload` — new CLI subcommand; re-applies the last seed color and
  last avatar image to the targets they were last applied to. state lives in
  `~/.config/cobalt.state` (JSON, override with COBALT_STATE), written only
  on successful non-dry runs. the post-update recovery flow is now:
  quit chrome -> `cobalt reload`.
