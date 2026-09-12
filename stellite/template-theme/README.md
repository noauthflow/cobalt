# template theme

a starting point for your own chrome theme — modify it to your liking if you
don't like the default chrome themes (or this one). load it unpacked:

    chrome://extensions → developer mode → load unpacked → <this folder>

## what's here

    manifest.json         the grey theme (what cobalt uses by default)
    manifest.json.violet  the same surfaces hue-shifted toward violet (accent #B79CFF)

to use the violet variant: copy it over `manifest.json`, then reload the
extension in chrome.

## editing it

a theme manifest is just static colors: `frame` (window edges), `toolbar`,
`bookmark_text`, `ntp_background` (new tab page), and so on. change the RGB
triples, reload the extension, see what happens. two gotchas the comments in
manifest.json explain in detail:

- leave `background_tab*` unset — chrome then derives tab surfaces from
  `toolbar`/`frame`, which keeps tabs seamless instead of drawing pill outlines
- keep `tab_text` set — chrome's fallback for the active tab label is black

## accents: don't put them in the theme

chrome resets accent preferences whenever a theme is applied, so accents are
NOT set in this manifest. use the sync CLI instead:

    cobalt-sync seed '#7C4DFF'

that writes chrome's `browser.theme.user_color` preference directly (address
bar focus ring, icon tinting) and survives independently of the theme. the
recommended pairing: grey theme + `#7C4DFF`, violet theme + `#B79CFF`.
