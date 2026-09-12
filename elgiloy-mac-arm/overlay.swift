import AppKit

// the overlay: frosted-glass HUD. rows are built ONCE per tab-set change;
// the selection is a single CALayer that slides between rows — moving the
// highlight costs one frame change, nothing else. that's the app-switcher
// trick, and it's why per-press cost is effectively zero.
final class Overlay {
    static let W: CGFloat = 620
    static let ROW_H: CGFloat = 38
    static let MARGIN: CGFloat = 8
    static let GAP: CGFloat = 2
    static let MAX_ROWS = 12

    private let panel: NSPanel
    private let glass: NSGlassEffectView
    private let content: NSView
    private let highlight = CALayer()
    private var rows: [(RowView, Int)] = []
    private var lastKey = ""
    private var currentStart = 0
    private var currentCount = 0

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Overlay.W, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true   // system shadow follows the glass shape now
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true   // fully click-through: the mouse can't
                                          // interact with the overlay at all
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // macOS 26+ Liquid Glass: native rounded glass, no layer masking.
        // the system draws both the rounding and the window shadow from the
        // glass shape, so the shadow hugs the corners by construction.
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
    }

    func show() {
        guard let s = NSScreen.main else { return }
        var f = panel.frame
        f.origin.x = s.frame.midX - Overlay.W / 2
        f.origin.y = s.frame.midY - f.size.height / 2   // vertically centered (origin = bottom edge)
        panel.setFrame(f, display: false)   // position only — render() owns the size
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        lastKey = ""
    }

    func render(tabs: [Browser.Tab], sel: Int) {
        let count = min(tabs.count, Overlay.MAX_ROWS)
        let start = tabs.isEmpty ? 0 : max(0, min(sel - Overlay.MAX_ROWS / 2, tabs.count - Overlay.MAX_ROWS))
        let visible = tabs.isEmpty ? [] : Array(tabs[start..<start + count])

        // rebuild only when the visible tab set actually changed
        let key = visible.map { "\($0.n):\($0.title)" }.joined(separator: "\u{1e}")
        if key != lastKey {
            lastKey = key
            let nRows = CGFloat(max(visible.count, 1))
            let newH = Overlay.MARGIN * 2 + Overlay.ROW_H * nRows + Overlay.GAP * (nRows - 1)
            var f = panel.frame
            // grow/shrink around the CENTER — anchoring an edge (the old
            // behavior) made the panel jump up/down whenever the height
            // changed between sessions
            f.origin.y -= (newH - f.size.height) / 2
            f.size.height = newH
            panel.setFrame(f, display: true)
            glass.frame = NSRect(origin: .zero, size: f.size)
            content.frame = NSRect(origin: .zero, size: f.size)

            content.subviews.forEach { $0.removeFromSuperview() }
            rows.removeAll()
            if content.layer?.sublayers?.contains(highlight) != true {
                content.layer?.insertSublayer(highlight, at: 0)
            }

            for (i, tab) in visible.enumerated() {
                let tabIndex = start + i
                let row = RowView(frame: rowFrame(i, height: newH), tab: tab)
                content.addSubview(row)
                rows.append((row, tabIndex))
            }
        }
        currentStart = start
        currentCount = visible.count

        placeHighlight(index: sel, animate: false)
    }

    // per-press fast path: slide the highlight layer. if the selection left
    // the visible window, fall back to a full render (window scrolls).
    func moveHighlight(to sel: Int, tabs: [Browser.Tab]) {
        guard sel >= currentStart, sel < currentStart + currentCount else {
            render(tabs: tabs, sel: sel)
            return
        }
        placeHighlight(index: sel, animate: true)
    }

    private func rowFrame(_ i: Int, height: CGFloat) -> NSRect {
        let y = height - Overlay.MARGIN - Overlay.ROW_H * (CGFloat(i) + 1) - Overlay.GAP * CGFloat(i)
        return NSRect(x: Overlay.MARGIN, y: y, width: Overlay.W - Overlay.MARGIN * 2, height: Overlay.ROW_H)
    }

    private func placeHighlight(index sel: Int, animate: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animate ? 0.05 : 0)
        highlight.frame = rows.first { $0.1 == sel }!.0.frame
        CATransaction.commit()
    }
}

// one row: favicon (or colored letter badge fallback) + title + right-aligned
// domain. no hover styling, no click handling — the mouse has zero effect;
// only the keyboard moves the highlight.
final class RowView: NSView {
    private let badge = NSTextField(labelWithString: "")
    private let tile = NSView()
    private let iconView = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let domain = NSTextField(labelWithString: "")

    init(frame: NSRect, tab: Browser.Tab) {
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
        domain.frame = NSRect(x: 38 + textW * 0.68 + 6, y: 11, width: textW * 0.32 - 8, height: 16)
        domain.font = .systemFont(ofSize: 11)
        domain.textColor = NSColor.white.withAlphaComponent(0.45)
        domain.alignment = .right
        domain.lineBreakMode = .byTruncatingHead
        addSubview(domain)
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
