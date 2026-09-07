#!/usr/bin/env python3
"""
shortcutpad — manage Chromium bookmarks & site-search engines from a plain config file.

Works with any Chromium-based browser (Chrome, Chromium, ungoogled, Helium, Vivaldi,
Brave, Edge, Arc, Thorium, ...) because they all use the same profile format:

  <profile>/Bookmarks    -> JSON
  <profile>/Web Data     -> SQLite, `keywords` table (omnibox site-search engines)

Config format (one entry per line):
    Name | keyword | url
A url containing %s or {query} becomes a site-search engine; a plain url becomes a bookmark.

IMPORTANT: run `push` while the target browser is CLOSED — Chromium rewrites both
files on exit and will clobber your changes.
"""

import argparse
import json
import os
import re
import shutil
import sqlite3
import sys
import time
import uuid
from urllib.parse import urlparse

FOLDER_NAME = "Shortcut Pad"          # bookmarks folder we own on the bookmarks bar
GUID_PREFIX = "SCPAD-"                # marks engine rows created/managed by us (for --prune)
LINE_RE = re.compile(r"^\s*(.+?)\s*\|\s*(.*?)\s*\|\s*(\S.*?)\s*$")
PLACEHOLDER_RE = re.compile(r"\{query\}|%s", re.IGNORECASE)


# --------------------------------------------------------------------------
# Browser discovery
# --------------------------------------------------------------------------

def browser_roots():
    """Known install locations per browser. --root overrides all of this."""
    home = os.path.expanduser("~")
    if sys.platform == "darwin":
        base = os.path.join(home, "Library", "Application Support")
        return {
            "chrome":   os.path.join(base, "Google/Chrome"),
            "chromium": os.path.join(base, "Chromium"),
            "brave":    os.path.join(base, "BraveSoftware/Brave-Browser"),
            "edge":     os.path.join(base, "Microsoft Edge"),
            "vivaldi":  os.path.join(base, "Vivaldi"),
            "opera":    os.path.join(base, "Opera"),
            "helium":   os.path.join(base, "Helium"),
            "thorium":  os.path.join(base, "Thorium"),
            "arc":      os.path.join(base, "Arc/User Data"),
        }
    base = os.path.join(home, ".config")
    return {
        "chrome":   os.path.join(base, "google-chrome"),
        "chromium": os.path.join(base, "chromium"),   # covers most ungoogled builds too
        "brave":    os.path.join(base, "BraveSoftware/Brave-Browser"),
        "edge":     os.path.join(base, "microsoft-edge"),
        "vivaldi":  os.path.join(base, "vivaldi"),
        "opera":    os.path.join(base, "opera"),
        "helium":   os.path.join(base, "helium"),
        "thorium":  os.path.join(base, "thorium"),
    }


def find_profiles(root):
    """Profile dirs (Default, Profile 1, ...) directly under a browser user-data dir."""
    profiles = []
    if not os.path.isdir(root):
        return profiles
    for name in sorted(os.listdir(root)):
        d = os.path.join(root, name)
        if not os.path.isdir(d):
            continue
        if os.path.exists(os.path.join(d, "Web Data")) or os.path.exists(os.path.join(d, "Bookmarks")):
            profiles.append(d)
    return profiles


def resolve_target(args):
    """Return list of profile dirs to operate on."""
    if args.root:
        root = os.path.abspath(os.path.expanduser(args.root))
        if not os.path.isdir(root):
            sys.exit(f"error: --root {root} does not exist")
    else:
        root = browser_roots().get(args.browser)
        if not root or not os.path.isdir(root):
            sys.exit(f"error: browser '{args.browser}' not found. Try `list`, or pass --root.")
    profiles = find_profiles(root)
    if args.profile:
        profiles = [p for p in profiles if os.path.basename(p) == args.profile]
        if not profiles:
            sys.exit(f"error: profile '{args.profile}' not found under {root}")
    if not profiles:
        sys.exit(f"error: no profiles found under {root}")
    return root, profiles


# --------------------------------------------------------------------------
# Config parsing
# --------------------------------------------------------------------------

def parse_config(path):
    engines, bookmarks = [], []
    seen_keywords = {}
    with open(path, encoding="utf-8") as f:
        for n, raw in enumerate(f, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            m = LINE_RE.match(line)
            if not m:
                sys.exit(f"config error, line {n}: expected `Name | keyword | url`, got:\n  {raw.rstrip()}")
            name, keyword, url = m.group(1), m.group(2), m.group(3)
            if PLACEHOLDER_RE.search(url):
                if not keyword:
                    sys.exit(f"config error, line {n}: search-engine url needs a keyword:\n  {raw.rstrip()}")
                if keyword in seen_keywords:
                    print(f"warning: line {n}: duplicate keyword '{keyword}' "
                          f"(also line {seen_keywords[keyword]}), last one wins")
                seen_keywords[keyword] = n
                engines.append({
                    "name": name,
                    "keyword": keyword,
                    "url": PLACEHOLDER_RE.sub("%s", url),  # Chromium's native placeholder
                    "favicon_url": favicon_for(url),
                })
            else:
                bookmarks.append({"name": name, "url": url})
    return engines, bookmarks


def favicon_for(url):
    p = urlparse(url if "//" in url else "https://" + url)
    if p.scheme in ("http", "https") and p.netloc:
        return f"{p.scheme}://{p.netloc}/favicon.ico"
    return ""


# --------------------------------------------------------------------------
# Web Data (SQLite) — omnibox site-search engines
# --------------------------------------------------------------------------

def push_engines(profile, engines, prune, dry):
    path = os.path.join(profile, "Web Data")
    con = sqlite3.connect(path)
    try:
        cols = {row[1] for row in con.execute("PRAGMA table_info(keywords)")}
        if "keyword" not in cols:
            sys.exit(f"error: {path} has no `keywords` table — open the browser once, then retry")

        now = webkit_now()
        existing = dict(con.execute("SELECT keyword, id FROM keywords"))
        inserted = updated = 0

        for e in engines:
            values = {
                "short_name": e["name"],
                "keyword": e["keyword"],
                "favicon_url": e["favicon_url"],
                "url": e["url"],
                "safe_for_autoreplace": 0,
                "input_encodings": "UTF-8",
                "suggest_url": "",
                "alternate_urls": "[]",
                "date_created": now,
                "last_modified": now,
                "sync_guid": GUID_PREFIX + str(uuid.uuid4()),
                "is_active": 1,
            }
            use = {k: v for k, v in values.items() if k in cols}
            if e["keyword"] in existing:
                sets = ", ".join(f"{k} = ?" for k in use if k != "keyword")
                con.execute(f"UPDATE keywords SET {sets} WHERE keyword = ?",
                            [v for k, v in use.items() if k != "keyword"] + [e["keyword"]])
                updated += 1
            else:
                keys = ", ".join(use)
                qs = ", ".join("?" for _ in use)
                con.execute(f"INSERT INTO keywords ({keys}) VALUES ({qs})", list(use.values()))
                inserted += 1

        pruned = 0
        if prune:
            ours = con.execute("SELECT keyword FROM keywords WHERE sync_guid LIKE ?",
                               (GUID_PREFIX + "%",)).fetchall()
            keep = {e["keyword"] for e in engines}
            for (kw,) in ours:
                if kw not in keep:
                    con.execute("DELETE FROM keywords WHERE keyword = ?", (kw,))
                    pruned += 1

        if dry:
            con.rollback()
        else:
            con.commit()
        return inserted, updated, pruned
    finally:
        con.close()


def pull_engines(profile):
    """User-defined engines (not built-in/prepopulated), ours first."""
    path = os.path.join(profile, "Web Data")
    con = sqlite3.connect(path)
    try:
        cols = {row[1] for row in con.execute("PRAGMA table_info(keywords)")}
        if "keyword" not in cols:
            return []
        prepop = "prepopulate_id" in cols
        rows = con.execute(
            "SELECT short_name, keyword, url FROM keywords "
            f"{'WHERE prepopulate_id = 0' if prepop else ''} ORDER BY keyword").fetchall()
        return [{"name": r[0], "keyword": r[1], "url": r[2]} for r in rows if r[1] and r[2]]
    finally:
        con.close()


# --------------------------------------------------------------------------
# Bookmarks (JSON)
# --------------------------------------------------------------------------

def webkit_now():
    return int((time.time() + 11644473600) * 1_000_000)  # µs since 1601


def skeleton_bookmarks():
    now = str(webkit_now())
    def folder(i, name):
        return {"children": [], "date_added": now, "date_last_used": "0",
                "date_modified": now, "guid": str(uuid.uuid4()), "id": str(i),
                "name": name, "type": "folder"}
    return {"roots": {"bookmark_bar": folder(1, "Bookmarks bar"),
                      "other": folder(2, "Other bookmarks"),
                      "synced": folder(3, "Mobile bookmarks")}, "version": 1}


def walk_ids(node, acc):
    if isinstance(node, dict):
        try:
            acc.append(int(node["id"]))
        except (KeyError, TypeError, ValueError):
            pass
        for v in node.values():
            walk_ids(v, acc)


def push_bookmarks(profile, bookmarks, dry):
    path = os.path.join(profile, "Bookmarks")
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    else:
        data = skeleton_bookmarks()

    try:
        bar = data["roots"]["bookmark_bar"]
    except KeyError:
        sys.exit(f"error: {path} has unexpected structure, aborting")
    bar.setdefault("children", [])

    folder = next((c for c in bar["children"]
                   if c.get("type") == "folder" and c.get("name") == FOLDER_NAME), None)
    if folder is None:
        ids = []
        walk_ids(data, ids)
        folder = {"children": [], "date_added": str(webkit_now()), "date_last_used": "0",
                  "date_modified": str(webkit_now()), "guid": str(uuid.uuid4()),
                  "id": str(max(ids or [0]) + 1), "name": FOLDER_NAME, "type": "folder"}
        bar["children"].append(folder)
    folder.setdefault("children", [])

    want = {b["url"]: b["name"] for b in bookmarks}
    kids = folder["children"]

    # drop stale entries inside OUR folder only
    kids[:] = [c for c in kids if c.get("type") != "url" or c.get("url") in want]

    ids = []
    walk_ids(data, ids)
    next_id = max(ids or [0]) + 1

    added = updated = 0
    for url, name in want.items():
        child = next((c for c in kids if c.get("type") == "url" and c.get("url") == url), None)
        if child is None:
            kids.append({"date_added": str(webkit_now()), "date_last_used": "0",
                         "guid": str(uuid.uuid4()), "id": str(next_id), "name": name,
                         "type": "url", "url": url})
            next_id += 1
            added += 1
        elif child.get("name") != name:
            child["name"] = name
            updated += 1

    # checksum omitted -> Chromium recomputes and rewrites it on next launch
    data.pop("checksum", None)
    if not dry:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=3, ensure_ascii=False)
    return added, updated


def pull_bookmarks(profile):
    path = os.path.join(profile, "Bookmarks")
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    bar = data.get("roots", {}).get("bookmark_bar", {})
    folder = next((c for c in bar.get("children", [])
                   if c.get("type") == "folder" and c.get("name") == FOLDER_NAME), {})
    return [{"name": c.get("name", c.get("url", "")), "url": c["url"]}
            for c in folder.get("children", []) if c.get("type") == "url"]


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

def backup(path, dry):
    if not dry and os.path.exists(path):
        shutil.copy2(path, path + ".scpad-bak")


def cmd_list(args):
    roots = browser_roots()
    width = max(map(len, roots))
    found_any = False
    for name, root in roots.items():
        if not os.path.isdir(root):
            continue
        profiles = find_profiles(root)
        if not profiles:
            continue
        found_any = True
        print(f"{name.ljust(width)}  {root}")
        for p in profiles:
            print(f"{' ' * width}    -> {os.path.basename(p)}")
    if not found_any:
        print("no known browsers found — point me at one with --root /path/to/user-data-dir")


def cmd_push(args):
    engines, bookmarks = parse_config(args.config)
    root, profiles = resolve_target(args)
    print(f"config: {args.config}  ({len(engines)} engines, {len(bookmarks)} bookmarks)")
    if not args.dry:
        print("NOTE: make sure the browser is closed — it rewrites these files on exit.\n")
    for p in profiles:
        label = f"{os.path.basename(root)} / {os.path.basename(p)}"
        backup(os.path.join(p, "Bookmarks"), args.dry)
        backup(os.path.join(p, "Web Data"), args.dry)
        if engines or args.prune:
            ins, upd, pruned = push_engines(p, engines, args.prune, args.dry)
            print(f"{label}: engines +{ins} ~{upd}" + (f" pruned {pruned}" if args.prune else ""))
        if bookmarks:
            added, updated = push_bookmarks(p, bookmarks, args.dry)
            print(f"{label}: bookmarks +{added} ~{updated} (folder '{FOLDER_NAME}')")
    if args.dry:
        print("\n(dry run — nothing written)")


def cmd_pull(args):
    root, profiles = resolve_target(args)
    engines, bookmarks, seen = [], [], set()
    for p in profiles:
        for e in pull_engines(p):
            if e["keyword"] not in seen:
                seen.add(e["keyword"])
                engines.append(e)
        for b in pull_bookmarks(p):
            if b["url"] not in seen:
                seen.add(b["url"])
                bookmarks.append(b)
    out = args.out or args.config
    lines = ["# generated by `shortcutpad pull` — edit freely", ""]
    lines += [f"{e['name']} | {e['keyword']} | {e['url']}" for e in engines]
    if engines and bookmarks:
        lines.append("")
    lines += [f"{b['name']} | | {b['url']}" for b in bookmarks]
    with open(out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print(f"pulled {len(engines)} engines + {len(bookmarks)} bookmarks -> {out}")


def cmd_init(args):
    if os.path.exists(args.config) and not args.force:
        sys.exit(f"error: {args.config} already exists (use --force to overwrite)")
    os.makedirs(os.path.dirname(args.config), exist_ok=True)
    example = os.path.join(os.path.dirname(os.path.abspath(__file__)), "shortcuts.conf.example")
    if os.path.exists(example):
        shutil.copy(example, args.config)
    else:
        open(args.config, "w").write("# Name | keyword | url\nGitHub | gh | https://github.com/search?q=%s\n")
    print(f"wrote {args.config} — now put it in your dotfiles repo and edit it")


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def main():
    default_config = os.environ.get("SHORTCUTPAD_CONFIG",
                                    os.path.expanduser("~/.config/shortcutpad/shortcuts.conf"))
    ap = argparse.ArgumentParser(prog="shortcutpad",
                                 description="Chromium bookmarks & site-search engines from a plain config file")
    ap.add_argument("--config", default=default_config, help=f"config file (default: {default_config})")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list", help="list detected browsers/profiles")

    p_push = sub.add_parser("push", help="apply config -> browser(s)")
    p_push.add_argument("browser", nargs="?", default="chrome")
    p_push.add_argument("--root", help="user-data dir of any Chromium fork (vendor-agnostic escape hatch)")
    p_push.add_argument("--profile", help="target one profile (Default, Profile 1, ...)")
    p_push.add_argument("--prune", action="store_true", help="also delete engine rows we manage that are no longer in config")
    p_push.add_argument("--dry", action="store_true")

    p_pull = sub.add_parser("pull", help="browser -> config file")
    p_pull.add_argument("browser", nargs="?", default="chrome")
    p_pull.add_argument("--root", help="user-data dir of any Chromium fork")
    p_pull.add_argument("--profile", help="read one profile")
    p_pull.add_argument("-o", "--out", help="write to this file instead of --config")

    p_init = sub.add_parser("init", help="create a starter config")
    p_init.add_argument("--force", action="store_true")

    args = ap.parse_args()
    {"list": cmd_list, "push": cmd_push, "pull": cmd_pull, "init": cmd_init}[args.cmd](args)


if __name__ == "__main__":
    main()
