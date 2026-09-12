# cobalt-sync

Co-Al-Ni — the classic cobalt magnet alloy. sync is magnetic alignment: one plain text config, one field, every browser snapped into line.

`cobalt-sync` drives the bookmarks-bar structure and omnibox keyword engines of any chromium-family or firefox-family browser. no extension, no daemon, no sync service. the config file is the source of truth; `push` writes the browser's native databases directly.

## install

    ./install.sh            symlink the cli to ~/.local/bin/cobalt-sync
    ./install.sh uninstall  remove the symlink

needs python 3.8+ (stdlib only, nothing to build). no special macOS permissions — it reads and writes browser profile files directly, so quit browsers before pushing.

## commands

    cobalt-sync ls                      list detected browsers/profiles
    cobalt-sync push [--browser B] [--profile P] [--dry]
                                        config -> browser (bar made to match exactly)
    cobalt-sync pull [--browser B] [--profile P]
                                        browser -> config (exact nesting/order)
    cobalt-sync seed IMAGE|COLOR [--strength N] [--force]
                                        set chrome's theme accent + NTP background
    cobalt-sync avatar IMAGE [browser]  replace chromium profile avatar PNGs (192x192)
    cobalt-sync reload [--force]        re-apply last seed color + avatar after chrome updates
    cobalt-sync init [--force]          create a starter config

`--root /path/to/user-data-dir` targets any chromium fork not auto-detected.

## config format (~/.config/cobalt.conf)

    Name | url                  bookmark. file order = bar order, strictly.
    keyword = url               omnibox engine named after its keyword.
    Name | keyword | url        engine with a custom display name.
    [Folder]                    folder. nesting via indentation, arbitrary depth.

blank lines and `#` comments are ignored. top level = directly on the bookmarks bar. a url containing `%s` (or `{query}`) gets the typed query substituted; a plain url just navigates (`yt = youtube.com` opens youtube.com). bookmarklets survive: a second field starting with a url scheme (`javascript:`, `https:`, ...) is treated as a url, never a keyword.

nesting: a line belongs to the nearest `[Folder]` above it whose indentation is strictly smaller. any width works (spaces or tabs, consistent width recommended); `pull` emits 2 spaces per level.

see `cobalt.conf.example` for a working starting point.

## supported browsers

chromium family (Bookmarks JSON + "Web Data" sqlite): chrome, chrome-beta, chrome-dev, chrome-canary, chromium, helium, brave, edge, edge-beta, edge-dev, edge-canary, vivaldi, opera, thorium, arc

firefox family (places.sqlite): firefox, zen, librewolf, waterfox, floorp

anything else: `--root`.

## chrome-internals.md

field notes on undocumented chrome behavior discovered while building this — seed color storage, avatar sources, pak formats, branded-chrome tamper resistance, launch flags. maintainer documentation; not needed to use the tool.
