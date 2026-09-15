import AppKit
import SQLite3

// favicons. the source of truth is chrome's OWN favicon database
// (~/Library/Application Support/Google/Chrome/<profile>/Favicons) — the exact
// bitmaps the tab strip shows, fetched by chrome from inside the real browser.
// that's the whole point: a search engine's icon service (duckduckgo, google)
// serves what their CRAWLER saw, which is a different thing — svg-only sites
// come back 404 (openfront.io), cloudflare-blocked sites we can never reach,
// and coverage is generally the search icon, not the tab icon. chrome already
// rasterizes svgs and clears challenges, so its db just works.
//
// chrome holds an exclusive lock on the db, so: copy db + wal/journal to a
// temp dir and query the copy. network fallback only for domains chrome
// hasn't seen. no icon anywhere → the colored letter badge stays.
final class Favicons {
    static let shared = Favicons()
    private let q = DispatchQueue(label: "dev.cobalt.elgiloy.favicons")
    private var waiting: [String: [(NSImage?) -> Void]] = [:]   // domain → callbacks
    private let ttl: TimeInterval = 60 * 60 * 24 * 14           // refetch after 14 days

    private var dir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("elgiloy-favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func fileURL(_ domain: String) -> URL {
        let safe = domain.lowercased().map { c -> Character in
            (c.isLetter || c.isNumber || c == "." || c == "-") ? c : "_"
        }
        return dir.appendingPathComponent(String(safe))
    }

    // synchronous disk read — only ever called on the main thread. this is
    // what makes rows render with real icons INSTANTLY (no network on the
    // critical path).
    func cached(_ domain: String) -> NSImage? {
        guard let data = try? Data(contentsOf: fileURL(domain)) else { return nil }
        return NSImage(data: data)
    }

    // async fetch; fires done exactly once, on the main thread. concurrent
    // requests for the same domain are coalesced.
    func fetch(_ domain: String, pageURL: String? = nil, done: @escaping (NSImage?) -> Void) {
        guard !domain.isEmpty, domain.contains(".") else { done(nil); return }
        q.async { [weak self] in
            guard let self else { return }
            // fresh enough on disk? serve without touching anything
            if let attrs = try? FileManager.default.attributesOfItem(atPath: self.fileURL(domain).path),
               let mtime = attrs[.modificationDate] as? Date,
               Date().timeIntervalSince(mtime) < self.ttl,
               let data = try? Data(contentsOf: self.fileURL(domain)),
               let img = NSImage(data: data) {
                DispatchQueue.main.async { done(img) }
                return
            }
            // already fetching this domain? queue behind it
            if self.waiting[domain] != nil {
                self.waiting[domain]?.append(done)
                return
            }
            self.waiting[domain] = [done]
            // chrome's db first — the actual tab icon
            if let hit = self.fromChromeDB(domain, pageURL: pageURL) {
                try? hit.data.write(to: self.fileURL(domain), options: .atomic)
                self.fire(domain, img: hit.image)
                return
            }
            // ddg's service is indexed per-domain and coverage is uneven:
            // "web.whatsapp.com" 404s while "whatsapp.com" has the icon.
            // try the full host first, then fall back to the registrable
            // domain — but always cache under the ORIGINAL key, so the
            // instant disk path above keeps matching what tabs actually are.
            self.fetchFirst([domain] + self.registrableFallback(domain), domain: domain)
        }
    }

    private func fire(_ domain: String, img: NSImage?) {
        let callbacks = waiting.removeValue(forKey: domain) ?? []
        DispatchQueue.main.async { callbacks.forEach { $0(img) } }
    }

    // "web.whatsapp.com" → ["whatsapp.com"]; bare domains → []. two labels
    // is the safe definition of registrable here (no public-suffix table —
    // worst case "mail.google.com" → "google.com", which is the icon we want).
    private func registrableFallback(_ domain: String) -> [String] {
        let parts = domain.lowercased().split(separator: ".")
        guard parts.count > 2 else { return [] }
        return [parts.suffix(2).joined(separator: ".")]
    }

    // walk the candidate list; first 200 that decodes wins. fires the
    // original domain's callbacks exactly once, with nil if nothing worked.
    private func fetchFirst(_ candidates: [String], domain: String) {
        guard let candidate = candidates.first else {
            fire(domain, img: nil)
            return
        }
        let req = URLRequest(url: URL(string: "https://icons.duckduckgo.com/ip3/\(candidate).ico")!,
                             cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self else { return }
            self.q.async {
                if let http = resp as? HTTPURLResponse, http.statusCode == 200,
                   let data, let img = NSImage(data: data) {
                    try? data.write(to: self.fileURL(domain), options: .atomic)
                    self.fire(domain, img: img)
                    return
                }
                self.fetchFirst(Array(candidates.dropFirst()), domain: domain)
            }
        }.resume()
    }

    // ---- chrome's favicon db ----

    // "https://user:pw@www.github.com:443/x?y" → "github.com" — scheme,
    // userinfo, port, www and path all gone, lowercase.
    private func host(_ url: String) -> String {
        var s = url
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let r = s.range(of: "/") { s = String(s[..<r.lowerBound]) }
        if let r = s.range(of: "@") { s = String(s[r.upperBound...]) }
        if let r = s.range(of: ":") { s = String(s[..<r.lowerBound]) }
        if s.hasPrefix("www.") { s = String(s.dropFirst(4)) }
        return s.lowercased()
    }

    private func fromChromeDB(_ domain: String, pageURL: String?) -> (data: Data, image: NSImage)? {
        let chromeDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Google/Chrome", isDirectory: true)
        guard let profiles = try? FileManager.default.contentsOfDirectory(atPath: chromeDir.path) else { return nil }
        let target = host(domain)
        for profile in profiles {
            let dbPath = chromeDir.appendingPathComponent("\(profile)/Favicons").path
            guard FileManager.default.fileExists(atPath: dbPath) else { continue }
            // chrome holds the db open; work on a throwaway copy (wal + journal
            // ride along so nothing committed is missed)
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("elgiloy-favicons-\(UUID().uuidString)")
            for suffix in ["", "-wal", "-journal"] {
                try? FileManager.default.copyItem(atPath: dbPath + suffix, toPath: tmp.path + suffix)
            }
            defer {
                for suffix in ["", "-wal", "-journal", "-shm"] {
                    try? FileManager.default.removeItem(atPath: tmp.path + suffix)
                }
            }
            guard let db = openDB(tmp.path) else { continue }
            defer { sqlite3_close(db) }
            // exact page url (the tab's own mapping) first, then any mapping
            // from the same host — e.g. deep game urls map to the site icon
            let maps = mappings(db)
            let exact = pageURL.map { url in maps.filter { $0.url == url } } ?? []
            let sameHost = maps.filter { host($0.url) == target }
            for entry in exact + sameHost {
                if let data = bitmap(db, iconID: entry.iconID), let image = NSImage(data: data) {
                    return (data, image)
                }
            }
        }
        return nil
    }

    private func openDB(_ path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    private func mappings(_ db: OpaquePointer?) -> [(url: String, iconID: Int64)] {
        var out: [(String, Int64)] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT page_url, icon_id FROM icon_mapping", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                out.append((String(cString: c), sqlite3_column_int64(stmt, 1)))
            }
        }
        return out
    }

    private func bitmap(_ db: OpaquePointer?, iconID: Int64) -> Data? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            SELECT image_data FROM favicon_bitmaps
            WHERE icon_id = ? AND image_data IS NOT NULL
            ORDER BY width DESC LIMIT 1
            """, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, iconID)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let blob = sqlite3_column_blob(stmt, 0) else { return nil }
        let n = Int(sqlite3_column_bytes(stmt, 0))
        guard n > 0 else { return nil }
        return Data(bytes: blob, count: n)
    }
}
