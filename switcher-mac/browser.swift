import Foundation
import OSAKit

// all browser contact happens here. every call runs an apple event against
// the frontmost chromium-family app, targeted by bundle id (never by name —
// the user's browser is a renamed Chromium.app).
enum Browser {
    struct Tab {
        let n: Int      // 1-based tab index, as chrome sees it
        let title: String
        let url: String

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

    // run a precompiled script synchronously, return its string result
    private static func run(_ script: OSAScript) -> String? {
        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        if result == nil {
            fputs("cobalt-switcher: apple event error \(err?["NSAppleScriptErrorMessage"] ?? err ?? "unknown")\n", stderr)
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
                    set n to count of tabs of front window
                    set a to active tab index of front window
                    set out to (a as text) & (character id 31)
                    repeat with i from 1 to n
                        set out to out & i & (character id 31) & (title of tab i of front window) & (character id 31) & (URL of tab i of front window) & (character id 30)
                    end repeat
                end tell
                return out
                """),
            active: OSAScript(source: """
                tell application id "\(bundleId)" to get active tab index of front window
                """)
        )
        scripts[bundleId] = s
        return s
    }

    // everything the overlay needs in one query: active tab index (first
    // field) + every tab's title and url
    static func list(bundleId: String, queue: DispatchQueue, done: @escaping ([Tab]?, Int?) -> Void) {
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
    private static let commitQ = DispatchQueue(label: "dev.cobalt.switcher.commit")
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
                    tell application id "\(p.bundleId)" to set active tab index of front window to \(p.n)
                    """)
            }
            activateScripts[p.bundleId] = cache
            _ = run(cache[p.n]!)
        }
    }

    // the one write command we own for esc: hover a row, press esc, that tab dies
    static func closeTab(bundleId: String, n: Int) {
        let script = OSAScript(source: "tell application id \"\(bundleId)\" to close tab \(n) of front window")
        _ = run(script)
        fputs("cobalt-switcher: closed tab \(n)\n", stderr)
    }
}
