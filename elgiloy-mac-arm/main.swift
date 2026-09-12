import AppKit
import ApplicationServices

// WE ARE THE CYCLE. ctrl+tab is swallowed — chrome never sees it and never
// cycles on its own. the selection is plain local state (instant, one actor,
// nothing to flicker between). exactly ONE apple event happens per session:
// on ctrl release, activate the highlighted tab.
final class App: NSObject {
    static let shared = App()

    let overlay = Overlay()
    let q = DispatchQueue(label: "dev.cobalt.elgiloy")   // serial: apple events run here
    var bundleId: String?
    var tabs: [Browser.Tab] = []
    var sel = 0
    var open = false
    var listBusy = false
    private var listPending = false   // a refresh arrived while one was in flight → run another when it lands
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
        // LIVE CACHE — while a chromium browser is frontmost and the overlay
        // is closed, quietly poll its tab list every 200ms. the batched list
        // query costs a few ms of apple-event time, so this is effectively
        // free, and it means the cache is ALWAYS current: a tab added two
        // seconds ago (or two hundred) is already in the list the instant
        // the overlay opens. no warm-up lag, no stale first frame.
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, !self.open else { return }
            guard let app = NSWorkspace.shared.frontmostApplication,
                  Browser.isChromiumFamily(app), let bid = app.bundleIdentifier else { return }
            self.bundleId = bid
            self.refreshList()
        }
    }

    // opens the overlay. triggered by ctrl+shift (modifiers alone, no key
    // press needed) or by the first ctrl+tab. on its own it NEVER cycles:
    // the overlay just appears, anchored on chrome's real active tab.
    // (the first ctrl+tab calls advance() right after begin() to keep the
    // original "first press is a real switch" behavior.)
    func begin() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              Browser.isChromiumFamily(app),
              let bid = app.bundleIdentifier else { return }
        // launcher overlays (raycast, spotlight, …) float above chrome as
        // panels — the workspace may still call chrome "frontmost", but the
        // overlay's window is the frontmost window. if the top app-level
        // window belongs to anyone but the browser, the user is mid-launcher
        // and ctrl+shift / ctrl+tab must do nothing.
        if let top = Browser.topAppWindowOwnerPID(), top != app.processIdentifier { return }
        bundleId = bid
        guard !open else { return }
        open = true
        listBusy = false
        movedYet = false
        tabs = bid == cacheBundleId ? cache : []
        sel = cacheSel < tabs.count ? cacheSel : 0
        overlay.render(tabs: tabs, sel: sel)
        overlay.show()
        startWatchdog()
        refreshList()   // one query on open; corrects sel if chrome moved since last time
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
        stopWatchdog()
        cacheSel = sel
        overlay.hide()
        refreshList()   // prime the cache while idle — the NEXT open is instant
    }

    // 1-0 while the overlay is open: jump straight to that tab. same path
    // as advance() — highlight snaps instantly (local), chrome switches in
    // real time — and the session stays open so jumps can chain. 0 = tab 10.
    func jump(to n: Int) {
        guard open, !tabs.isEmpty, tabs.indices.contains(n - 1) else { return }
        movedYet = true
        sel = n - 1
        overlay.moveHighlight(to: sel, tabs: tabs)
        if let bid = bundleId {
            Browser.activateAsync(bundleId: bid, n: tabs[sel].n)
        }
    }

    // esc: cancel (nothing changed — chrome was never touched).
    func escPressed() {
        guard open else { return }
        stopWatchdog()
        open = false
        overlay.hide()
        refreshList()
    }

    // w while the overlay is open: close the SELECTED tab — keyboard path,
    // no hovering required. the overlay stays open either way.
    func closeSelected() {
        guard open else { return }
        closeRow(sel)
    }

    // close row i: fires the close in the background, drops the row locally,
    // keeps the overlay open, and lands the selection on the row ABOVE the
    // closed one — every time. lets you close several in a row.
    private func closeRow(_ i: Int) {
        guard open, let bid = bundleId, tabs.indices.contains(i) else { return }
        let tab = tabs[i]
        q.async { Browser.closeTab(bundleId: bid, n: tab.n) }
        let wasSelected = i == sel
        tabs.remove(at: i)
        // chrome renumbers its tab indices after a close — keep local n in
        // sync so a fast next-press still switches to the right tab
        for k in tabs.indices where tabs[k].n > tab.n { tabs[k].n -= 1 }
        cache = tabs
        if wasSelected {
            // land on the row BELOW the closed one — same index, since the
            // rows below it shifted up into the gap — so you can keep closing
            // down a run of tabs. closing the LAST tab (nothing below it)
            // lands on the new last row, i.e. the one above.
            sel = i < tabs.count ? i : max(0, i - 1)
        } else if i < sel {
            sel -= 1
        }
        if tabs.isEmpty {
            open = false
            overlay.hide()
        } else {
            overlay.render(tabs: tabs, sel: sel, center: false)
        }
        refreshList()   // confirm against chrome — renumbers & titles settle
    }

    // SAFETY NET — the tap is normally the only thing that ends a session
    // (ctrl/cmd/option release via flagsChanged). but macOS silently disables
    // event taps
    // taps
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
            let flags = CGEventSource.flagsState(.combinedSessionState)
            let modsDown = flags.contains(.maskControl) || flags.contains(.maskCommand)
                || flags.contains(.maskAlternate)
            let front = NSWorkspace.shared.frontmostApplication
            if !modsDown || front?.bundleIdentifier != self.bundleId {
                self.end()
            }
        }
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func refreshList() {
        guard let bid = bundleId else { return }
        // never DROP a refresh: if one is already in flight (started by end(),
        // the activation watcher, or a close), queue a follow-up instead.
        // dropping it meant the overlay could open on a stale list — a tab
        // added seconds ago wouldn't appear until the NEXT session.
        if listBusy { listPending = true; return }
        listBusy = true
        Browser.list(bundleId: bid, queue: q) { [weak self] tabs, active in
            guard let self else { return }
            DispatchQueue.main.async {
                self.listBusy = false
                defer {
                    if self.listPending {
                        self.listPending = false
                        self.refreshList()
                    }
                }
                if let tabs {
                    // cache ALWAYS takes the reply — even when it lands after
                    // the session already ended. discarding it (the old
                    // behavior) meant fast sessions never warmed the cache and
                    // every open started blank.
                    let changed = tabs != self.cache || active != nil && !self.open && active! - 1 != self.cacheSel
                    self.cache = tabs
                    self.cacheBundleId = self.bundleId
                    if !self.open, let a = active, a - 1 < tabs.count {
                        // the poll runs while the overlay is closed, so this is
                        // where mouse-driven tab changes get noticed: chrome's
                        // real active index feeds cacheSel, keeping the cached
                        // pointer in sync. without it, a tab switched by mouse
                        // left cacheSel stale — the overlay opened anchored on
                        // the WRONG tab, and the first ctrl+tab activated that
                        // wrong tab in chrome.
                        self.cacheSel = a - 1
                    }
                    if changed { self.persist() }   // skip disk writes when the poll found nothing new
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
                        self.overlay.render(tabs: self.tabs, sel: self.sel, center: false)
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
        return dir.appendingPathComponent("elgiloy-tabs.json")
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
