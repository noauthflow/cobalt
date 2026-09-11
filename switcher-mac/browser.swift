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

    // run an applescript synchronously, return its string result (nil on error)
    static func run(_ source: String) -> String? {
        let script = OSAScript(source: source)
        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        if result == nil {
            fputs("cobalt-switcher: apple event error \(err?["NSAppleScriptErrorMessage"] ?? err ?? "unknown")\n", stderr)
            return nil
        }
        return result?.stringValue
    }

    // one query returns everything the overlay needs: the active tab index
    // (first field) plus every tab's title and url. ~150ms, only on open/refresh.
    static func list(bundleId: String, queue: DispatchQueue, done: @escaping ([Tab]?, Int?) -> Void) {
        queue.async {
            let source = """
            tell application id "\(bundleId)"
                set n to count of tabs of front window
                set a to active tab index of front window
                set out to (a as text) & (character id 31)
                repeat with i from 1 to n
                    set out to out & i & (character id 31) & (title of tab i of front window) & (character id 31) & (URL of tab i of front window) & (character id 30)
                end repeat
            end tell
            return out
            """
            guard let raw = run(source) else { done(nil, nil); return }
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

    // the 50ms mirror beat: "which tab did chrome actually switch to?" ~30ms
    static func activeIndex(bundleId: String, queue: DispatchQueue, done: @escaping (Int?) -> Void) {
        queue.async {
            let source = "tell application id \"\(bundleId)\" to get active tab index of front window"
            done(run(source).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        }
    }

    // the one write command we own: hover a row, press esc, that tab dies
    static func closeTab(bundleId: String, n: Int) {
        let source = "tell application id \"\(bundleId)\" to close tab \(n) of front window"
        _ = run(source)
        fputs("cobalt-switcher: closed tab \(n)\n", stderr)
    }
}
