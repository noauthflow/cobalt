import Foundation
import OSAKit
import ApplicationServices
import Darwin

// all browser contact happens here. every call runs an apple event against
// the frontmost chromium-family app, targeted by bundle id (never by name —
// the user's browser is a renamed Chromium.app).
enum Browser {
    struct Tab: Codable, Equatable {
        var n: Int      // 1-based tab index, as chrome sees it (mutable: renumbers on close)
        let title: String
        let url: String
        var pinned: Bool = false   // from the AX tree (see pinnedFlags)

        init(n: Int, title: String, url: String, pinned: Bool = false) {
            self.n = n; self.title = title; self.url = url; self.pinned = pinned
        }

        // hand-rolled decode so cache files from before `pinned` still load
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            n = try c.decode(Int.self, forKey: .n)
            title = try c.decode(String.self, forKey: .title)
            url = try c.decode(String.self, forKey: .url)
            pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        }

        // "https://github.com/…" → "github.com"
        var domain: String {
            var s = url
            if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
            if let r = s.range(of: "/") { s = String(s[..<r.lowerBound]) }
            return s.isEmpty ? url : s
        }
    }

    static func isChromiumFamily(_ app: NSRunningApplication) -> Bool {
        let names = ["chromium", "chrome", "brave", "edge", "arc", "vivaldi", "opera"]
        let name = (app.localizedName ?? "").lowercased()
        let exec = app.executableURL?.lastPathComponent.lowercased() ?? ""
        return names.contains { name.contains($0) || exec.contains($0) }
    }

    // the pid that owns the topmost FLOATING panel on screen, if any. this is
    // a launcher check only: raycast/spotlight/alfred float above chrome as
    // panels (raycast: layer 8) while chrome stays the "frontmost app" — when
    // one is up, the user is mid-launch and ctrl+tab must do nothing.
    // anything at layer ≤ 4 is a normal app window and NEVER blocks: while the
    // browser is frontmost its window tops layer 0, so a foreign window above
    // it at low layer is just a persistent float — steam keeps its main window
    // at layer 1, and treating that as "a launcher is up" refused to open the
    // overlay for as long as steam's window was visible anywhere. system
    // chrome (menu bar, dock, banners) lives at layer ≥ 20 and never blocks.
    static func floatingPanelOwnerPID() -> pid_t? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for w in list {
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            if layer >= 20 { continue }   // skip system chrome (menu bar, dock, …)
            if layer < 5 { return nil }   // normal app window — not a launcher
            return w[kCGWindowOwnerPID as String] as? pid_t
        }
        return nil
    }

    // run a precompiled script synchronously, return its string result
    private static func run(_ script: OSAScript) -> String? {
        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        if result == nil {
            fputs("elgiloy: apple event error \(err?["NSAppleScriptErrorMessage"] ?? err ?? "unknown")\n", stderr)
            return nil
        }
        return result?.stringValue
    }

    // scripts are compiled ONCE per process (per bundle id) and re-executed —
    // compiling on every call was the single biggest latency source. the id is
    // baked into the source, since OSAScript can't pass handler parameters.
    private static var scripts: [String: (list: OSAScript, active: OSAScript)] = [:]

    private static func compiled(for bundleId: String) -> (list: OSAScript, active: OSAScript) {
        if let s = scripts[bundleId] { return s }
        let s = (
            list: OSAScript(source: """
                tell application id "\(bundleId)"
                    -- window 1, never "front window": chromium resolves
                    -- "front window" through its last-active-window pointer,
                    -- which dies the moment another app takes a click (steam,
                    -- ghostty, anything) and throws -1719 until the browser is
                    -- re-activated. window 1 is front-to-back order — the same
                    -- window — and never wedges.
                    set a to active tab index of window 1
                    set ts to title of tabs of window 1
                    set us to URL of tabs of window 1
                    set out to (a as text) & (character id 31)
                    -- title and url lists can momentarily disagree (tab mid-
                    -- load, chrome's applescript model wedged): bound the loop
                    -- by the shorter list so a mismatch degrades to a partial
                    -- row instead of a -1700 crash of the whole query
                    set tc to count of ts
                    if (count of us) < tc then set tc to count of us
                    repeat with i from 1 to tc
                        set out to out & i & (character id 31) & (item i of ts) & (character id 31) & (item i of us) & (character id 30)
                    end repeat
                end tell
                return out
                """),
            active: OSAScript(source: """
                tell application id "\(bundleId)" to get active tab index of window 1
                """)
        )
        scripts[bundleId] = s
        return s
    }

    // ---- pinned tabs -------------------------------------------------------
    // chromium's appleScript dictionary has NO `pinned` property on tab, but
    // the accessibility tree does: every tab in the strip is an AXRadioButton
    // whose AXDescription contains " – Pinned " when the tab is pinned. the
    // strip's document order matches appleScript tab order, so the caller can
    // zip the flags straight onto the tab list by index.
    struct PinnedScan {
        var flags: [Bool]     // one per tab, in strip order
        var titles: [String]  // matching AX titles, for the fallback merge
    }

    static func pinnedFlags(pid: pid_t?) -> PinnedScan {
        guard let pid else { return PinnedScan(flags: [], titles: []) }
        let app = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &winRef)
        guard let w = winRef else { return PinnedScan(flags: [], titles: []) }
        // BFS down to the tab strip. prune AXWebArea — the page's accessibility
        // tree can hold thousands of nodes and this probe runs on every poll —
        // and cap depth; the strip sits a few groups under the window.
        var tabGroup: AXUIElement?
        var queue: [(AXUIElement, Int)] = [(w as! AXUIElement, 0)]
        while tabGroup == nil, !queue.isEmpty {
            let (el, depth) = queue.removeFirst()
            if depth > 7 { continue }
            for k in axChildren(el) {
                let role = axRole(k)
                if role == "AXTabGroup" { tabGroup = k; break }
                if role == "AXWebArea" { continue }
                queue.append((k, depth + 1))
            }
        }
        guard let tg = tabGroup else { return PinnedScan(flags: [], titles: []) }
        // one walk: grab the tab elements in document order, then read flags.
        // per tab this costs 2 attribute round-trips (role + description) —
        // titles are fetched LAZILY, only if the fallback merge needs them
        // (counts mismatch), since that's the only place they're used.
        var tabEls: [AXUIElement] = []
        func collect(_ el: AXUIElement) {
            if axRole(el) == "AXRadioButton" { tabEls.append(el); return }
            for k in axChildren(el) { collect(k) }
        }
        collect(tg)
        let flags = tabEls.map {
            (axString($0, kAXDescriptionAttribute as String) ?? "").range(of: "Pinned") != nil
        }
        return PinnedScan(flags: flags, titles: flags.count == tabEls.count ? [] : tabEls.map {
            axString($0, kAXTitleAttribute as String) ?? ""
        })
    }

    private static func axChildren(_ el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v)
        return (v as? [AXUIElement]) ?? []
    }

    private static func axRole(_ el: AXUIElement) -> String {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v)
        return v as? String ?? ""
    }

    private static func axString(_ el: AXUIElement, _ name: String) -> String? {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, name as CFString, &v)
        return v as? String
    }

    // everything the overlay needs in one query: active tab index (first
    // field) + every tab's title and url — plus pinned flags from the AX tree
    static func list(bundleId: String, queue: DispatchQueue, done: @escaping ([Tab]?, Int?) -> Void) {
        // captured on the calling (main) thread: NSWorkspace is happiest there
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        queue.async {
            let s = compiled(for: bundleId)
            guard let raw = run(s.list) else { done(nil, nil); return }
            var parts = raw.components(separatedBy: "\u{1f}")
            guard parts.count >= 2, let active = Int(parts.removeFirst()) else { done(nil, nil); return }
            var tabs: [Tab] = []
            for record in parts.joined(separator: "\u{1f}").components(separatedBy: "\u{1e}") where !record.isEmpty {
                let f = record.components(separatedBy: "\u{1f}")
                if f.count == 3, let n = Int(f[0]) { tabs.append(Tab(n: n, title: f[1], url: f[2])) }
            }
            // merge pinned flags. primary path: AX strip order == appleScript
            // order, so equal counts zip by index. fallback (AX pruned tabs
            // from the strip): match by title — a heuristic, better than none
            let scan = pinnedFlags(pid: pid)
            if scan.flags.count == tabs.count {
                for i in tabs.indices { tabs[i].pinned = scan.flags[i] }
            } else if !scan.flags.isEmpty {
                let pinnedTitles = Set(zip(scan.flags, scan.titles).filter { $0.0 }.map { $0.1 })
                for i in tabs.indices where pinnedTitles.contains(tabs[i].title) { tabs[i].pinned = true }
            }
            done(tabs.isEmpty ? nil : tabs, active)
        }
    }

    // the mirror beat: "which tab did chrome actually switch to?"
    static func activeIndex(bundleId: String, queue: DispatchQueue, done: @escaping (Int?) -> Void) {
        queue.async {
            let s = compiled(for: bundleId)
            let raw = run(s.active)
            done(raw.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        }
    }

    // ---- real-time background cycling -------------------------------------
    // every press fires a switch command. fire-and-forget + coalesced: the
    // overlay NEVER waits for it (highlight is instant), and during rapid
    // cycling only the newest target matters — no backlog of switches.
    // scripts compiled once per (browser, tab index), so commits are instant
    // after first use of an index.
    private static let commitQ = DispatchQueue(label: "dev.cobalt.elgiloy.commit")
    private static var activateScripts: [String: [Int: OSAScript]] = [:]
    private static var pendingActivate: (bundleId: String, n: Int)?
    private static var activateQueued = false

    static func activateAsync(bundleId: String, n: Int) {
        pendingActivate = (bundleId, n)
        guard !activateQueued else { return }
        activateQueued = true
        commitQ.async {
            activateQueued = false
            guard let p = pendingActivate else { return }
            pendingActivate = nil
            var cache = activateScripts[p.bundleId] ?? [:]
            if cache[p.n] == nil {
                cache[p.n] = OSAScript(source: """
                    tell application id "\(p.bundleId)" to set active tab index of window 1 to \(p.n)
                    """)
            }
            activateScripts[p.bundleId] = cache
            _ = run(cache[p.n]!)
        }
    }

    // the one write command we own for w: close the SELECTED tab while the
    // overlay is open
    static func closeTab(bundleId: String, n: Int) {
        let script = OSAScript(source: "tell application id \"\(bundleId)\" to close tab \(n) of window 1")
        _ = run(script)
        fputs("elgiloy: closed tab \(n)\n", stderr)
    }
}
