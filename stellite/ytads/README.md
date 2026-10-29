# ytads — youtube ad blocker

everything for ad blocking lives in this folder + one `content_scripts`
entry in `../manifest.json`. to remove the ad blocker entirely:

1. delete this folder
2. remove the second `content_scripts` entry in `../manifest.json`

nothing else (shorts blocker, ntp, pin shortcut) depends on it.

## what it does

- `hide.css`: home/search feed ads, masthead banner, promo banners,
  watch-page ad column, end-screen companion. uses `:has()` so the whole
  feed item disappears, not just the ad inside it.
- `ads.js`: feed sweep for anything badged "Sponsored"/"Promoted" that
  slips past a renderer rename (badge text is the stable signal), plus
  in-video handling: watches `#movie_player`'s ad state, auto-clicks the
  skip button, fast-forwards the ad stream to its end when there is no
  skip button yet, closes overlay/display ads.

## honest limits

- feed ads: ~100%, degrades gracefully (css + badge fallback).
- in-video ads are stitched into the stream — no simple extension can
  remove them at the request level. expect ~90%: youtube a/b-tests
  detection, so the occasional ad takes a few seconds instead of zero.
- no handling of youtube's adblock-detection wall (kept simple on
  purpose).
