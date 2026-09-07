# cobalt

*Atomic number 27 — three spots after chromium.*

Manage a Chromium browser's bookmarks bar and omnibox site-search engines from
one plain config file. No extension, no daemon, no sync service.

Works with any Chromium fork (Chrome, Chromium, Helium, Vivaldi, Brave, Edge,
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

## Firefox / Zen

Not yet — different storage (`places.sqlite` + `search.json.mozlz4`).
Planned as a second adapter behind the same config.
