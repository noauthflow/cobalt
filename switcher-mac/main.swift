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

    // warm cache survives between opens → overlay renders instantly.
    // cacheSel = the tab chrome was last known to be on.
    private var cache: [Browser.Tab] = []
    private var cacheSel = 0

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
        tabs = cache
        sel = cacheSel < tabs.count ? cacheSel : 0
        overlay.render(tabs: tabs, sel: sel, hover: nil)
        overlay.show()
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
        cacheSel = sel
        overlay.hide()
    }

    // esc: over a row → close that tab. otherwise → cancel (nothing changed,
    // so nothing to restore — chrome was never touched).
    func escPressed() {
        guard open, let bid = bundleId else { return }
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
    }

    private func refreshList() {
        guard let bid = bundleId, !listBusy else { return }
        listBusy = true
        Browser.list(bundleId: bid, queue: q) { [weak self] tabs, active in
            guard let self, self.open else { self?.listBusy = false; return }
            self.listBusy = false
            DispatchQueue.main.async {
                guard self.open else { return }
                if let tabs {
                    // if the user already moved (possibly on the very first
                    // press), re-anchor the highlight to the same tab so a
                    // reordered/fresh list can't make sel point elsewhere
                    let anchor = self.movedYet && self.sel < self.tabs.count
                        ? self.tabs[self.sel].n : nil
                    self.tabs = tabs
                    self.cache = tabs
                    if !self.movedYet, let a = active, a - 1 < tabs.count {
                        // user hasn't moved: land on chrome's real tab
                        self.sel = a - 1
                    } else if let anchor, let i = tabs.firstIndex(where: { $0.n == anchor }) {
                        self.sel = i
                    }
                }
                self.overlay.render(tabs: self.tabs, sel: self.sel, hover: self.hover)
            }
        }
    }
}

// entry — accessory app, no dock icon, runs forever from the LaunchAgent
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
_ = App.shared
Tap.watchAndInstall()
app.run()
