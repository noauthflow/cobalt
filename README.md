# shortcutpad

Manage bookmarks + omnibox site-search engines for **any Chromium browser** from a
plain, git-friendly config file. No extension, no sync service — your config repo
*is* the sync.

Works with Chrome, Chromium (incl. ungoogled builds), Helium, Vivaldi, Brave, Edge,
Opera, Thorium, Arc — and anything else via `--root`, since they all share the same
profile format (`Bookmarks` JSON + `Web Data` SQLite).

## Setup

```bash
shortcutpad init          # writes ~/.config/shortcutpad/shortcuts.conf
git add ~/.config/shortcutpad/shortcuts.conf   # put it in your dotfiles
```

Config format — one entry per line:

```
Name | keyword | url
```

- URL contains `%s` or `{query}` → **site-search engine** (usable from the omnibox: type the keyword, then Tab)
- Plain URL → **bookmark** (inside a "Shortcut Pad" folder on the bookmarks bar)

## Usage

```bash
shortcutpad list                    # detected browsers + profiles
shortcutpad push chrome             # apply config (all profiles)
shortcutpad push chromium --profile Default --prune   # also delete removed engines
shortcutpad push --root ~/.config/helium              # any fork, no built-in name needed
shortcutpad push vivaldi --dry      # preview
shortcutpad pull vivaldi            # browser -> config (bootstrap from existing setup)
```

Backups are written next to the targets (`*.scpad-bak`) before every push.

## ⚠️ The one rule

Run `push` while the target browser is **closed**. Chromium rewrites both files on
exit and will clobber your changes otherwise.

## Firefox / Zen

Not yet — different storage (`places.sqlite` + `search.json.mozlz4`). Planned as a
second adapter behind the same config.
