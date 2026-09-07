# cobalt

Cobalt is named after the periodic table: three atomic points above Chromium. (Because Chromium is better than Firefox. Yes, we now support Firefox too. Someone has to.)

One plain text config drives the bookmarks-bar structure and omnibox keyword engines of any chromium-family or firefox-family browser. No extension, no daemon, no sync service. The config file is the source of truth; push writes the browser's native databases directly.

    repo:    ~/dev/cobalt
    config:  ~/.config/cobalt.conf
    install: ln -sf ~/dev/cobalt/cobalt ~/.local/bin/cobalt
    needs:   python 3.8+, stdlib only, macOS / linux / windows

## supported browsers

chromium family (Bookmarks JSON + "Web Data" sqlite): chrome, chrome-beta, chrome-dev, chrome-canary, chromium, helium, brave, edge, edge-beta, edge-dev, edge-canary, vivaldi, opera, thorium, arc

firefox family (places.sqlite): firefox, zen, librewolf, waterfox, floorp

anything else: `--root /path/to/user-data-dir`

## config format (~/.config/cobalt.conf)

    Name | url                  bookmark. file order = bar order, strictly.
    keyword = url               omnibox engine named after its keyword.
    Name | keyword | url        engine with a custom display name.
    [Folder]                    folder. nesting via indentation, arbitrary depth.

blank lines and # comments are ignored. top level = directly on the bookmarks bar. a url containing %s (or {query}) gets the typed query substituted; a plain url just navigates (`yt = youtube.com` opens youtube.com). bookmarklets survive: a second field starting with a url scheme (javascript:, https:, ...) is treated as a url, never a keyword.

nesting: a line belongs to the nearest `[Folder]` above it whose indentation is strictly smaller. any width works (spaces or tabs, consistent width recommended); `cobalt pull` emits 2 spaces per level.

## commands

    cobalt ls
        list detected browsers and profiles, tagged [chromium] or [firefox].

    cobalt push [browser] [--profile NAME] [--root DIR] [--all] [--prune] [--dry]
        apply the config to the browser. the bookmarks bar is made to match the
        config exactly: folders merged by name, urls by url, order strict,
        anything else on the bar is removed (each removal is printed).
        --profile NAME  target one profile. fuzzy match ("7" -> "Profile 7").
                        required when the browser has multiple profiles.
        --all           apply to every profile instead.
        --prune         also delete engine rows/keywords that left the config.
                        chromium: rows with sync_guid prefix "COBALT-" only.
                        firefox: keywords attached to cobalt-managed places only.
        --dry           preview. nothing is written.
        every target file is backed up to *.cobalt-bak before writing.

    cobalt pull [browser] [--profile NAME] [--root DIR] [--all] [-o FILE]
        serialize the browser's bookmarks bar (exact nesting and order) plus its
        engines into the config file. engines that exist only in an existing
        config are kept, so pull never deletes manually added engine lines.

    cobalt init [--force]
        write a starter config to the default path.

    global: --config FILE   use this config instead of the default.

## what push writes

chromium `<profile>/Bookmarks` — JSON tree. the checksum key is removed so the browser recomputes it on next launch. only the bookmark_bar root is touched; other/synced roots are left alone.

chromium `<profile>/Web Data` — sqlite `keywords` table. %s is stored as {searchTerms}. rows we manage carry sync_guid prefix "COBALT-" (used by --prune). built-in engines (prepopulate_id > 0, starter_pack_id) are never touched.

firefox `<profile>/places.sqlite` — moz_bookmarks/moz_places. the bar is the root row with guid "toolbar_____"; order is the `position` column. new places get foreign_count=1, fresh guids, url_hash=0. engines use firefox bookmark keywords (moz_keywords), and because firefox urlbar keywords only fire for bookmarked urls, each engine also gets a bookmark inside a "Cobalt Engines" folder under the menu root (guid "menu________"). keyword urls keep %s as-is (firefox's placeholder). keywords are stored lowercase.

## rules and gotchas

- push only with the browser closed. chromium/firefox hold everything in memory and rewrite these files on exit, clobbering external edits. pull is safe any time; it reads a snapshot copy (sqlite locks ignored).
- browser sync (chrome sync / firefox sync): the server re-adds bookmarks deleted locally, since local deletion never reaches the server. additions and renames upload fine; deletions get resurrected. either disable bookmark sync in the browser, or do deletions once inside the browser. cobalt warns on push when sync is on and deletions happen.
- firefox keyword engines work from the address bar but do not appear in firefox's search settings page (that would require search.json.mozlz4 surgery; not implemented).
- duplicate urls on the bar collapse to one entry on push.
- opera keeps the profile in the user-data dir itself; detected.
- firefox profiles live at `<root>/Profiles/<name>`; detected.

## examples

    cobalt ls
    cobalt pull chrome --profile 7
    $EDITOR ~/.config/cobalt.conf
    cobalt push chrome --profile 7 --dry
    cobalt push chrome --profile 7 --prune      # browser closed
    cobalt push zen
    cobalt push --root /some/unknown/fork/dir --profile Default
