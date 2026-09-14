import AppKit

// favicons. chrome's apple events don't expose tab icons, so: per-domain
// disk cache + duckduckgo's icon service (icons.duckduckgo.com/ip3/<domain>.ico,
// 404s for unknown domains — unlike google's service, which returns a generic
// globe we can't distinguish from a real icon). no icon → the colored letter
// badge stays, so offline/unknown domains still look intentional.
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
    func fetch(_ domain: String, done: @escaping (NSImage?) -> Void) {
        guard !domain.isEmpty, domain.contains(".") else { done(nil); return }
        q.async { [weak self] in
            guard let self else { return }
            // fresh enough on disk? serve without touching the network
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
            // ddg's service is indexed per-domain and coverage is uneven:
            // "web.whatsapp.com" 404s while "whatsapp.com" has the icon.
            // try the full host first, then fall back to the registrable
            // domain — but always cache under the ORIGINAL key, so the
            // instant disk path above keeps matching what tabs actually are.
            let candidates = [domain] + self.registrableFallback(domain)
            self.fetchFirst(candidates, domain: domain)
        }
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
            let callbacks = waiting.removeValue(forKey: domain) ?? []
            DispatchQueue.main.async { callbacks.forEach { $0(nil) } }
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
                    let callbacks = self.waiting.removeValue(forKey: domain) ?? []
                    DispatchQueue.main.async { callbacks.forEach { $0(img) } }
                    return
                }
                self.fetchFirst(Array(candidates.dropFirst()), domain: domain)
            }
        }.resume()
    }
}