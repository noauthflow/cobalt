# cobalt new tab extension

optional. cobalt works fully without it — this just replaces the new tab
page and de-annoys youtube. load unpacked via chrome://extensions →
developer mode, or don't run it at all.

## features

**blank new tab page** (`blank.html`)
- plain #353535 page, "New Tab" title. no tiles, no search box, no
  google logo — the stock NTP phones home for those; this kills that.
- inline SVG favicon (lavender #C7B8E8 starburst) via data URI.

**youtube shorts blocker** (`block.js` + `hide.css`, runs at document_start)
- hides the sidebar entry and shorts shelves.
- hides grid/search results linking to /shorts/.
- redirects /shorts/ urls to the normal watch page.
- youtube renames element classes periodically; the redirect is the only
  part that cannot break.

**tab pin shortcut** (`pin.js`)
- chrome has no native keyboard shortcut for pinning tabs; this adds one.
- toggles pin on the active tab. default Ctrl+Shift+P (Cmd+Shift+P on mac),
  rebindable at chrome://extensions/shortcuts.

**icons** (`icons/`) — white 8-point starburst, 16/32/48/128.

## notes

- MV3 rule: this manifest has chrome_url_overrides + content_scripts, so
  it can NOT also carry a theme key — chrome would silently reject it.
  that's why the theme lives in a separate folder (template-theme/).
