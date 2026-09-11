import AppKit
import ApplicationServices

// WE ARE THE CYCLE. ctrl+tab is swallowed — chrome never sees it and never
// cycles on its own. the selection is plain local state (instant, one actor,
// nothing to flicker between). exactly ONE apple event happens per session:
// on ctrl release, activate the highlighted tab.
final class App: NSObject {
    static let shared = App()

    let overlay = Overlay()
    let q = DispatchQueue(label: "dev.cobalt.switcher")   // serial: apple events run here
    var bundleId: String?
    var tabs: [Browser.Tab] = []
    var sel = 0
    var open = false
    var hover: Int?
    var listBusy = false
    private var movedYet = false
    private var watchdog: Timer?

    // warm cache survives between opens → overlay renders instantly.
    // cacheSel = the tab chrome was last known to be on. cacheBundleId
    // guards against showing chrome's tabs when another browser is frontmost.
    private var cache: [Browser.Tab] = []
    private var cacheSel = 0
    private var cacheBundleId: String?

    override init() {
        super.init()
        loadCache()   // disk-backed: even the FIRST open after launch has tabs
        // warm prefetch: every time a chromium-family browser is activated,
        // quietly refresh its tab list in the background. by the time the
        // user presses ctrl+tab, the cache is already current — the overlay
        // never opens blank, not even the first time after a relaunch.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, !self.open,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  Browser.isChromiumFamily(app), let bid = app.bundleIdentifier else { return }
            self.bundleId = bid
            self.refreshList()
        }
    }

    // first ctrl+tab while a chromium-family browser is frontmost. opens the
    // overlay AND cycles immediately — the first press is a real switch, not
    // just "show me the list".
    func begin(shift: Bool) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              Browser.isChromiumFamily(app),
              let bid = app.bundleIdentifier else { return }
        bundleId = bid
        guard !open else { return }
        open = true
        hover = nil
        listBusy = false
        movedYet = false
        tabs = bid == cacheBundleId ? cache : []
        sel = cacheSel < tabs.count ? cacheSel : 0
        overlay.render(tabs: tabs, sel: sel, hover: nil)
        overlay.show()
        startWatchdog()
        refreshList()   // one query on open; corrects sel if chrome moved since last time
        advance(shift: shift)   // the first press cycles too (no-op if cache is still empty)
    }

    // each ctrl+tab press: highlight moves INSTANTLY (local), and chrome
    // switches to it in the background — fire-and-forget, real time, every press.
    func advance(shift: Bool) {
        guard open, !tabs.isEmpty else { return }
        movedYet = true   // even on the very first press — don't let the refresh snap back
        sel = (sel + (shift ? -1 : 1) + tabs.count) % tabs.count
        overlay.moveHighlight(to: sel, tabs: tabs)
        if let bid = bundleId {
            Browser.activateAsync(bundleId: bid, n: tabs[sel].n)
        }
    }

    // ctrl released → just hide. chrome is already on the highlighted tab —
    // every press switched it in real time. nothing deferred, nothing to commit.
    func end() {
        guard open else { return }
        open = false
        hover = nil
        stopWatchdog()
        cacheSel = sel
        overlay.hide()
        refreshList()   // prime the cache while idle — the NEXT open is instant
    }

    // esc: over a row → close that tab. otherwise → cancel (nothing changed,
    // so nothing to restore — chrome was never touched).
    func escPressed() {
        guard open, let bid = bundleId else { return }
        stopWatchdog()
        if let h = hover, h < tabs.count {
            let tab = tabs[h]
            open = false
            hover = nil
            overlay.hide()
            q.async { Browser.closeTab(bundleId: bid, n: tab.n) }
        } else {
            open = false
            hover = nil
            overlay.hide()
        }
        refreshList()   // prime cache; also corrects the list after a close
    }

    // SAFETY NET — the tap is normally the only thing that ends a session
    // (ctrl release via flagsChanged). but macOS silently disables event taps
    // when their callback times out, and flagsChanged events can be missed:
    // either way the overlay would sit on screen forever — frozen, with no
    // way to dismiss it. so an independent run-loop timer polls the REAL
    // global modifier state every 100ms; the moment ctrl isn't actually held
    // (or the frontmost app changed), the session force-ends. this works even
    // with the tap completely dead, because it never touches the tap.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.open else { return }
            let ctrlDown = CGEventSource.flagsState(.combinedSessionState).contains(.maskControl)
            let front = NSWorkspace.shared.frontmostApplication
            if !ctrlDown || front?.bundleIdentifier != self.bundleId {
                self.end()
            }
        }
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func refreshList() {
        guard let bid = bundleId, !listBusy else { return }
        listBusy = true
        Browser.list(bundleId: bid, queue: q) { [weak self] tabs, active in
            guard let self else { return }
            self.listBusy = false
            DispatchQueue.main.async {
                if let tabs {
                    // cache ALWAYS takes the reply — even when it lands after
                    // the session already ended. discarding it (the old
                    // behavior) meant fast sessions never warmed the cache and
                    // every open started blank.
                    self.cache = tabs
                    self.cacheBundleId = self.bundleId
                    self.persist()
                    if self.open {
                        // if the user already moved (possibly on the very
                        // first press), re-anchor the highlight to the same
                        // tab so a reordered/fresh list can't shift sel
                        let anchor = self.movedYet && self.sel < self.tabs.count
                            ? self.tabs[self.sel].n : nil
                        self.tabs = tabs
                        if !self.movedYet, let a = active, a - 1 < tabs.count {
                            // user hasn't moved: land on chrome's real tab
                            self.sel = a - 1
                        } else if let anchor, let i = tabs.firstIndex(where: { $0.n == anchor }) {
                            self.sel = i
                        }
                        self.overlay.render(tabs: self.tabs, sel: self.sel, hover: self.hover)
                    }
                }
            }
        }
    }

    // ---- disk-backed cache -------------------------------------------------
    // the daemon relaunches (boot, crash, reinstall) with an empty memory
    // cache — the first open would show a blank panel until the apple event
    // came back. persisting tabs fixes that: the background process really
    // does "always have them loaded".
    private struct CacheFile: Codable {
        let bundleId: String
        let tabs: [Browser.Tab]
        let sel: Int
    }

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("cobalt-switcher-tabs.json")
    }

    private func persist() {
        guard let bundleId else { return }
        let payload = CacheFile(bundleId: bundleId, tabs: cache, sel: open ? sel : cacheSel)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: Self.cacheURL, options: .atomic)
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let p = try? JSONDecoder().decode(CacheFile.self, from: data),
              !p.tabs.isEmpty else { return }
        cache = p.tabs
        cacheBundleId = p.bundleId
        cacheSel = min(p.sel, p.tabs.count - 1)
    }
}

// entry — accessory app, no dock icon, runs forever from the LaunchAgent
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
_ = App.shared
Tap.watchAndInstall()
app.run()
