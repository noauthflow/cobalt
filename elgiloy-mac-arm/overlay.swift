import AppKit

// the overlay: frosted-glass HUD. when the browser has pinned tabs there are
// TWO pills — pinned tabs in the top pill, regular tabs in the bottom one,
// separated by a gap; with no pinned tabs it's a single pill, same as ever.
// rows are built ONCE per tab-set change; the selection is a CALayer that
// slides between rows — moving the highlight costs one frame change, nothing
// else. that's the app-switcher trick, and it's why per-press cost is ~zero.
final class Overlay {
    static let W: CGFloat = 620
    static let ROW_H: CGFloat = 38
    static let MARGIN: CGFloat = 8
    static let GAP: CGFloat = 2
    static let PILL_GAP: CGFloat = 10   // space between the pinned pill and the main pill
    static let MAX_ROWS = 12
    // how many rows stay pinned beyond the selection before the window
    // scrolls — the selection rides 3 rows from the edge, then the list
    // advances one row per press (infinite scroll, no pagination jump)
    static let SCROLL_OFF = 3

    // one glass pill: its own panel (so the system shadow hugs ITS glass
    // shape), its own rows and highlight. empty → ordered out entirely.
    private final class Pill {
        let panel: NSPanel
        let glass: NSGlassEffectView
        let content: NSView
        let highlight = CALayer()
        var rows: [(RowView, Int)] = []
        var empty = true   // no rows last build → show() must not front it

        init() {
            panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Overlay.W, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true   // system shadow follows the glass shape
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true   // fully click-through
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            // macOS 26+ Liquid Glass: native rounded glass, no layer masking.
            glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: Overlay.W, height: 100))
            glass.cornerRadius = 14
            glass.style = .regular

            // rows/highlight live in a dedicated content view — NSGlassEffectView
            // only guarantees contentView is embedded inside the glass
            content = NSView(frame: NSRect(x: 0, y: 0, width: Overlay.W, height: 100))
            content.wantsLayer = true
            content.layer?.cornerRadius = 14
            content.layer?.masksToBounds = true
            content.layer?.borderWidth = 1
            content.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
            content.autoresizingMask = [.width, .height]
            glass.contentView = content
            panel.contentView = glass

            highlight.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
            highlight.cornerRadius = 8
            highlight.isHidden = true
        }

        func setHeight(_ h: CGFloat, bottomY: CGFloat, x: CGFloat) {
            var f = panel.frame
            f.size.height = h
            f.origin = NSPoint(x: x, y: bottomY)
            panel.setFrame(f, display: true)
            glass.frame = NSRect(origin: .zero, size: f.size)
            content.frame = NSRect(origin: .zero, size: f.size)
        }

        func buildRows(_ tabs: [(Browser.Tab, Int)], showPin: Bool) {
            content.subviews.forEach { $0.removeFromSuperview() }
            rows.removeAll()
            if content.layer?.sublayers?.contains(highlight) != true {
                content.layer?.insertSublayer(highlight, at: 0)
            }
            for (i, entry) in tabs.enumerated() {
                let row = RowView(frame: rowFrame(i, height: panel.frame.height), tab: entry.0, showPin: showPin)
                content.addSubview(row)
                rows.append((row, entry.1))
            }
        }

        private func rowFrame(_ i: Int, height: CGFloat) -> NSRect {
            let y = height - Overlay.MARGIN - Overlay.ROW_H * (CGFloat(i) + 1) - Overlay.GAP * CGFloat(i)
            return NSRect(x: Overlay.MARGIN, y: y, width: Overlay.W - Overlay.MARGIN * 2, height: Overlay.ROW_H)
        }

        // returns true when sel is a row of THIS pill (its highlight moved)
        @discardableResult
        func placeHighlight(index sel: Int, animate: Bool) -> Bool {
            guard let row = rows.first(where: { $0.1 == sel }) else {
                highlight.isHidden = true
                return false
            }
            CATransaction.begin()
            CATransaction.setAnimationDuration(animate ? 0.05 : 0)
            highlight.frame = row.0.frame
            highlight.isHidden = false
            CATransaction.commit()
            return true
        }
    }

    private let pinPill = Pill()
    private let mainPill = Pill()
    private let scrollbar = CALayer()   // thin position thumb, main pill's right edge
    private var lastKey = ""
    private var currentStart = 0
    private var currentCount = 0

    // true (default): pinned tabs in their own pill above. false ("flat"): one
    // pill, pinned tabs carry a pin icon next to the title instead.
    var splitView = true

    init() {
        scrollbar.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor
        scrollbar.cornerRadius = 2.5
        scrollbar.isHidden = true
    }

    func show() {
        // only pills that hold rows — an empty pill must stay ordered out,
        // otherwise it ghosts at its initial frame (bottom-left)
        if !pinPill.empty { pinPill.panel.orderFrontRegardless() }
        if !mainPill.empty { mainPill.panel.orderFrontRegardless() }
    }

    func hide() {
        pinPill.panel.orderOut(nil)
        mainPill.panel.orderOut(nil)
        lastKey = ""
    }

    // full rebuild. `center` (fresh open) centers the window on sel; otherwise
    // the window keeps its position and only moves when sel comes within
    // SCROLL_OFF rows of an edge — one row per press, no pagination jump.
    // ALWAYS yields a window containing sel.
    func render(tabs: [Browser.Tab], sel: Int, center: Bool = true) {
        let count = min(tabs.count, Overlay.MAX_ROWS)
        var start = center
            ? (tabs.isEmpty ? 0 : sel - Overlay.MAX_ROWS / 2)
            : currentStart
        // scroll-off margin: pin SCROLL_OFF rows beyond the selection
        if sel > start + count - 1 - Overlay.SCROLL_OFF {
            start = sel - (count - 1 - Overlay.SCROLL_OFF)   // 3 rows below
        }
        if sel < start + Overlay.SCROLL_OFF {
            start = sel - Overlay.SCROLL_OFF                 // 3 rows above
        }
        start = max(0, min(start, max(0, tabs.count - count)))
        let visible = tabs.isEmpty ? [] : Array(tabs[start..<start + count])

        // split mode: pinned pill above, regular pill below. flat mode: one
        // pill holding everything, pinned tabs marked per-row by RowView.
        let pinVisible = splitView
            ? visible.enumerated().filter { $0.element.pinned }
                .map { (tab: $0.element, index: start + $0.offset) }
            : []
        let mainVisible = visible.enumerated()
            .filter { !splitView || !$0.element.pinned }
            .map { (tab: $0.element, index: start + $0.offset) }

        // rebuild only when the visible tab set actually changed (pinned flags
        // AND view mode are part of the key — either changing redraws)
        let key = (splitView ? "s\u{1f}" : "f\u{1f}")
            + visible.map { "\($0.n):\($0.pinned ? 1 : 0):\($0.title)" }.joined(separator: "\u{1e}")
        if key != lastKey {
            lastKey = key
            let pinH = Self.height(for: pinVisible.count)
            let mainH = Self.height(for: mainVisible.count)
            let showPin = !pinVisible.isEmpty
            let showMain = !mainVisible.isEmpty

            // position the pair: union centered on the screen's mid-line
            if let s = NSScreen.main {
                let x = s.frame.midX - Overlay.W / 2
                let total = pinH + (showPin && showMain ? Overlay.PILL_GAP : 0) + mainH
                let bottom = s.frame.midY - total / 2
                if showMain {
                    mainPill.setHeight(mainH, bottomY: bottom, x: x)
                    mainPill.panel.orderFrontRegardless()
                } else {
                    mainPill.panel.orderOut(nil)
                }
                if showPin {
                    pinPill.setHeight(pinH, bottomY: bottom + mainH + (showMain ? Overlay.PILL_GAP : 0), x: x)
                    pinPill.panel.orderFrontRegardless()
                } else {
                    pinPill.panel.orderOut(nil)
                }
            }

            pinPill.rows.removeAll()
            mainPill.rows.removeAll()
            pinPill.empty = !showPin
            mainPill.empty = !showMain
            pinPill.buildRows(pinVisible.map { ($0.tab, $0.index) }, showPin: false)
            mainPill.buildRows(mainVisible.map { ($0.tab, $0.index) }, showPin: !splitView)

            // the thumb rides ON TOP of the rows — add it after them so it
            // survives every rebuild as the topmost layer
            if mainPill.content.layer?.sublayers?.contains(scrollbar) != true {
                mainPill.content.layer?.addSublayer(scrollbar)
            }
        }
        currentStart = start
        currentCount = visible.count

        // exactly one pill's highlight shows: the one holding sel
        let inPin = pinPill.placeHighlight(index: sel, animate: !center)
        let inMain = mainPill.placeHighlight(index: sel, animate: !center)
        if inPin { mainPill.highlight.isHidden = true }
        if inMain { pinPill.highlight.isHidden = true }

        updateScrollbar(total: tabs.count, count: count)
    }

    private static func height(for rows: Int) -> CGFloat {
        let n = CGFloat(max(rows, 1))
        return MARGIN * 2 + ROW_H * n + GAP * (n - 1)
    }

    // position thumb: proportional to where the visible window sits inside
    // the full tab list. hidden entirely when everything fits on screen or
    // the main pill isn't showing.
    private func updateScrollbar(total: Int, count: Int) {
        guard mainPill.rows.count > 0, total > Overlay.MAX_ROWS, count > 0, currentCount > 0 else {
            scrollbar.isHidden = true
            return
        }
        scrollbar.isHidden = false
        let trackH = mainPill.panel.frame.height - Overlay.MARGIN * 2
        let thumbH = max(24, trackH * CGFloat(count) / CGFloat(total))
        let frac = CGFloat(currentStart) / CGFloat(max(1, total - count))
        let y = Overlay.MARGIN + (trackH - thumbH) * (1 - frac)   // flipped: start=0 → top
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.05)
        scrollbar.frame = NSRect(x: Overlay.W - 7, y: y, width: 5, height: thumbH)
        CATransaction.commit()
    }

    // per-press fast path: slide the highlight layer. only when sel is fully
    // interior (SCROLL_OFF margin satisfied on both edges) — anything else
    // goes through render, which owns the window math.
    func moveHighlight(to sel: Int, tabs: [Browser.Tab]) {
        let count = min(tabs.count, Overlay.MAX_ROWS)
        let interior = sel >= currentStart + Overlay.SCROLL_OFF
            && sel <= currentStart + count - 1 - Overlay.SCROLL_OFF
        guard interior else {
            render(tabs: tabs, sel: sel, center: false)
            return
        }
        let inPin = pinPill.placeHighlight(index: sel, animate: true)
        let inMain = mainPill.placeHighlight(index: sel, animate: true)
        if inPin { mainPill.highlight.isHidden = true }
        if inMain { pinPill.highlight.isHidden = true }
    }
}

// one row: favicon (or colored letter badge fallback) + title + right-aligned
// domain. `showPin` adds a small pin glyph between title and domain for
// pinned tabs — used in flat view (in split view the pills already separate
// them, so the icon would be redundant). no hover styling, no click handling
// — the mouse has zero effect; only the keyboard moves the highlight.
final class RowView: NSView {
    private let badge = NSTextField(labelWithString: "")
    private let tile = NSView()
    private let iconView = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let domain = NSTextField(labelWithString: "")
    private let pinIcon = NSImageView()

    init(frame: NSRect, tab: Browser.Tab, showPin: Bool = false) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        let d = tab.domain

        // colored tile behind the fallback letter — deterministic color per
        // domain (hash over utf8 bytes → hue; same site = same color, always)
        tile.frame = NSRect(x: 9, y: 9, width: 20, height: 20)
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 5
        tile.layer?.masksToBounds = true
        tile.layer?.backgroundColor = Self.color(for: d).cgColor
        addSubview(tile)

        badge.stringValue = String(d.first.map { String($0) } ?? "?").uppercased()
        badge.alignment = .center
        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.textColor = .white
        badge.sizeToFit()   // frame → exact text bounds, so centering is real
        badge.frame.origin = NSPoint(x: 9 + (20 - badge.frame.width) / 2,
                                     y: 9 + (20 - badge.frame.height) / 2)
        addSubview(badge)

        // real favicon when we have one — instant from the disk cache, else
        // fetched once per domain and dropped in when it arrives. the letter
        // badge stays underneath as the fallback so unknown/offline domains
        // never look broken.
        iconView.frame = NSRect(x: 11, y: 11, width: 16, height: 16)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.isHidden = true
        addSubview(iconView)
        if let img = Favicons.shared.cached(d) {
            applyIcon(img)
        } else {
            Favicons.shared.fetch(d) { [weak self] img in
                guard let self, let img else { return }
                self.applyIcon(img)
            }
        }

        let textW = frame.width - 46
        title.stringValue = tab.title
        title.frame = NSRect(x: 38, y: 9, width: textW * 0.68, height: 20)
        title.font = .systemFont(ofSize: 13)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingMiddle
        title.cell?.truncatesLastVisibleLine = true
        addSubview(title)

        domain.stringValue = d
        domain.font = .systemFont(ofSize: 11)
        domain.textColor = NSColor.white.withAlphaComponent(0.45)
        domain.alignment = .right
        domain.lineBreakMode = .byTruncatingHead
        addSubview(domain)
        if showPin {
            // flat view: the pin hugs the domain text's left edge. size the
            // domain to its text and right-align it (right edge stays at the
            // same spot for every row); the pin sits immediately before it.
            // the 16pt reserve keeps the pin from ever crowding the title.
            domain.sizeToFit()
            let maxDW = textW * 0.32 - 8 - 16
            let dw = min(domain.frame.width, maxDW)
            domain.frame = NSRect(x: frame.width - 10 - dw, y: 11, width: dw, height: 16)
            pinIcon.frame = NSRect(x: domain.frame.minX - 15, y: 12, width: 13, height: 13)
        } else {
            domain.frame = NSRect(x: 38 + textW * 0.68 + 6, y: 11, width: textW * 0.32 - 8, height: 16)
        }
        pinIcon.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "pinned")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        pinIcon.contentTintColor = NSColor.white.withAlphaComponent(0.60)
        pinIcon.isHidden = !showPin || !tab.pinned
        addSubview(pinIcon)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyIcon(_ img: NSImage) {
        iconView.image = img
        iconView.isHidden = false
        tile.isHidden = true
        badge.isHidden = true
    }

    private static func color(for domain: String) -> NSColor {
        var hash = 0
        for b in domain.utf8 { hash = (hash &* 31 &+ Int(b)) & 0xFFFF }
        let hue = CGFloat(hash % 360) / 360.0
        return NSColor(hue: hue, saturation: 0.55, brightness: 0.62, alpha: 1)
    }
}