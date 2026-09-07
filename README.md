# cobalt

*Atomic number 27 — three spots after chromium.*

Manage a Chromium browser's bookmarks bar and omnibox site-search engines from
one plain config file. No extension, no daemon, no sync service.

Works on macOS, Linux and Windows, with any Chromium fork (Chrome, Helium, Vivaldi, Brave, Edge,
Arc...) — same profile format everywhere. Unknown fork? `--root /path/to/dir`.

## Config

`~/.config/cobalt.conf`

```
Name | url                  bookmark (file order = bar order, strictly)
Name | keyword | url        search engine (omnibox only, not a bookmark)
[Folder]                    folder; nesting via indentation, any depth
```

Top level sits directly on the bookmarks bar. Order in the file is law.

## Usage

```bash
cobalt list                       # detected browsers + profiles
cobalt pull chrome --profile "Profile 7"   # browser -> config (exact nesting/order)
cobalt push --dry                 # preview exactly what would change
cobalt push --prune               # apply + clean up removed engines
```

⚠ `push` only while the browser is **closed** — it rewrites the files on exit.
`pull` is safe anytime. Backups land next to the targets (`*.cobalt-bak`).

## Install

```bash
ln -sf ~/dev/cobalt/cobalt ~/.local/bin/cobalt
```

## Firefox family (Firefox, Zen, LibreWolf, Waterfox, Floorp)

Same config, same commands — just name the browser: `cobalt push zen`.
Bookmarks go to `places.sqlite` (toolbar root, nested, strict order). Engines
use Firefox's native bookmark keywords (`moz_keywords`) — `yt = youtube.com`
jumps, `%s` in a url gets the query substituted. They work from the address
bar but don't appear in Firefox's search-settings page.

## Chromium family

Chrome, Chromium, Helium, Vivaldi, Brave, Edge, Arc, Opera, Thorium...
`Bookmarks` JSON + `Web Data` SQLite, as described above.
