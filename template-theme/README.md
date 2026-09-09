# cobalt theme

chrome theme boilerplate. two variants ship in this folder:

    manifest.json           the live theme (loaded via chrome://extensions
                            -> developer mode -> load unpacked). currently
                            the grey variant with seamless tabs.
    manifest.json.grey      backup of the grey palette.
    manifest.json.violet    backup of the lavender/violet palette (surfaces
                            hue-shifted toward violet, accent #B79CFF).

to switch variants: copy the backup over manifest.json, hit reload on the
theme in chrome://extensions, and fully restart chrome (frame colors do not
repaint until relaunch). delete "Cached Theme.pak" if colors look stale —
chrome regenerates it from the manifest on load.

## design rules

  - elevation is an even-step ramp: frame 27 -> toolbar 40 -> ntp 53
    (13 per step). violet variant keeps the same lightness ramp, hue-shifted.
  - ntp_background is pinned to #353535 to match extension/blank.html, which
    overrides the new tab page with the same color. change both or neither.
  - do NOT set background_tab / background_tab_inactive / background_tab_hover:
    chrome then draws explicit tab pills. leaving them unset makes chrome
    derive the active tab from toolbar and inactive tabs from frame, so tabs
    blend seamlessly like the default dark theme.
  - DO set tab_text: chrome's fallback for the active tab label when the key
    is absent is black, while inactive labels derive light — inverted contrast.
  - accents (omnibox/user colors) are handled by `cobalt seed`, not the theme:
    grey variant pairs with #7C4DFF, violet with #B79CFF.
