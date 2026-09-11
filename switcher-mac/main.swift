import AppKit
import ApplicationServices

// the whole state machine: open (bool), tabs (the list), sel (chrome's real
// active tab, mirrored at 50ms), hover (row under the mouse). that's it.
final class App: NSObject {
    static let shared = App()

    let overlay = Overlay()
    let q = DispatchQueue(label: "dev.cobalt.switcher")   // serial: apple events run here
    var bundleId: String?
    var tabs: [Browser.Tab] = []
    var sel = 0
    var open = false
    var hover: Int?
    var poll: DispatchSourceTimer?
    var busy = false
    var tick = 0

    // ctrl+tab seen while a chromium-family browser is frontmost.
    // chrome already switched (or is switching); we just show the mirror.
    func begin() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              Browser.isChromiumFamily(app),
              let bid = app.bundleIdentifier else { return }
        bundleId = bid
        guard !open else { return }   // autorepeat / already up — poll keeps it synced
        open = true
        hover = nil
        tabs = []
        sel = 0
        tick = 0
        busy = false
        overlay.render(tabs: [], sel: 0, hover: nil)
        overlay.show()
        refreshList()
        startPoll()
    }

    // ctrl released
    func end() {
        guard open else { return }
        open = false
        hover = nil
        busy = false
        poll?.cancel()
        poll = nil
        overlay.hide()
    }

    // esc: over a row → close that tab. otherwise → cancel the overlay.
    func escPressed() {
        guard open, let bid = bundleId else { return }
        if let h = hover, h < tabs.count {
            let tab = tabs[h]
            end()
            q.async { Browser.closeTab(bundleId: bid, n: tab.n) }
        } else {
            end()
        }
    }

    private func startPoll() {
        let timer = DispatchSource.makeTimerSource(queue: q)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler { [weak self] in self?.pollTick() }
        timer.resume()
        poll = timer
    }

    private func pollTick() {
        guard open, let bid = bundleId else { return }
        tick += 1
        if tick % 10 == 0 { refreshList(); return }   // full refresh ~every 500ms
        guard !busy else { return }
        busy = true
        Browser.activeIndex(bundleId: bid, queue: q) { [weak self] idx in
            guard let self, self.open else { self?.busy = false; return }
            self.busy = false
            guard let idx else { return }
            DispatchQueue.main.async {
                guard self.open, idx - 1 != self.sel else { return }
                self.sel = idx - 1
                self.overlay.render(tabs: self.tabs, sel: self.sel, hover: self.hover)
            }
        }
    }

    private func refreshList() {
        guard let bid = bundleId else { return }
        busy = true
        Browser.list(bundleId: bid, queue: q) { [weak self] tabs, active in
            guard let self, self.open else { self?.busy = false; return }
            self.busy = false
            DispatchQueue.main.async {
                guard self.open else { return }
                if let tabs { self.tabs = tabs }
                if let active { self.sel = active - 1 }
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
