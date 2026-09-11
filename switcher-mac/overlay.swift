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
    private let glass: NSVisualEffectView
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
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        glass = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: Overlay.W, height: 100))
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 14
        glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 1
        glass.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        panel.contentView = glass

        highlight.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        highlight.cornerRadius = 8
    }

    func show() {
        guard let s = NSScreen.main else { return }
        var f = panel.frame
        f.origin.x = s.frame.midX - Overlay.W / 2
        f.origin.y = s.frame.midY + 100
        panel.setFrame(f, display: false)   // position only — render() owns the size
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        lastKey = ""
    }

    func render(tabs: [Browser.Tab], sel: Int, hover: Int?) {
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
            f.origin.y -= (newH - f.size.height)
            f.size.height = newH
            panel.setFrame(f, display: true)
            glass.frame = NSRect(origin: .zero, size: f.size)

            glass.subviews.forEach { $0.removeFromSuperview() }
            rows.removeAll()
            if glass.layer?.sublayers?.contains(highlight) != true {
                glass.layer?.insertSublayer(highlight, at: 0)
            }

            for (i, tab) in visible.enumerated() {
                let tabIndex = start + i
                let row = RowView(frame: rowFrame(i, height: newH), tab: tab)
                row.onEnter = { [weak self] in App.shared.hover = tabIndex; self?.restyle(hover: tabIndex) }
                row.onExit  = { [weak self] in App.shared.hover = nil;    self?.restyle(hover: nil) }
                glass.addSubview(row)
                rows.append((row, tabIndex))
            }
        }
        currentStart = start
        currentCount = visible.count

        restyle(hover: hover)
        placeHighlight(index: sel, animate: false)

        // mouse already sitting where the panel appeared → pick up hover instantly
        if let hit = hitTest(NSEvent.mouseLocation) {
            App.shared.hover = hit
            restyle(hover: hit)
        }
    }

    // per-press fast path: slide the highlight layer. if the selection left
    // the visible window, fall back to a full render (window scrolls).
    func moveHighlight(to sel: Int, tabs: [Browser.Tab]) {
        guard sel >= currentStart, sel < currentStart + currentCount else {
            render(tabs: tabs, sel: sel, hover: App.shared.hover)
            return
        }
        placeHighlight(index: sel, animate: true)
    }

    private func rowFrame(_ i: Int, height: CGFloat) -> NSRect {
        let y = height - Overlay.MARGIN - Overlay.ROW_H * (CGFloat(i) + 1) - Overlay.GAP * CGFloat(i)
        return NSRect(x: Overlay.MARGIN, y: y, width: Overlay.W - Overlay.MARGIN * 2, height: Overlay.ROW_H)
    }

    private func placeHighlight(index sel: Int, animate: Bool) {
        guard let (_, tabIndex) = rows.first(where: { $0.1 == sel }) else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(animate ? 0.05 : 0)
        highlight.frame = rows.first { $0.1 == sel }!.0.frame
        CATransaction.commit()
        _ = tabIndex
    }

    private func hitTest(_ screenPoint: NSPoint) -> Int? {
        guard panel.isVisible else { return nil }
        let local = panel.convertPoint(fromScreen: screenPoint)
        for (row, tabIndex) in rows where row.frame.contains(local) { return tabIndex }
        return nil
    }

    // hover styling only — selection lives in the highlight layer
    private func restyle(hover: Int?) {
        for (row, tabIndex) in rows {
            row.setHovered(tabIndex == hover)
        }
    }
}

// one row: colored letter badge (chrome-style "no favicon" tile) + title +
// right-aligned domain. hover = subtle wash. no selection styling — the
// sliding highlight layer draws that.
final class RowView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var ta: NSTrackingArea?

    private let badge = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let domain = NSTextField(labelWithString: "")

    init(frame: NSRect, tab: Browser.Tab) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        let d = tab.domain
        badge.stringValue = String(d.first.map { String($0) } ?? "?").uppercased()
        badge.frame = NSRect(x: 9, y: 9, width: 20, height: 20)
        badge.alignment = .center
        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 5
        badge.layer?.backgroundColor = Self.color(for: d).cgColor
        badge.textColor = .white
        addSubview(badge)

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

    func setHovered(_ hovered: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = hovered ? NSColor.white.withAlphaComponent(0.08).cgColor : NSColor.clear.cgColor
        CATransaction.commit()
    }

    private static func color(for domain: String) -> NSColor {
        var hash = 0
        for b in domain.utf8 { hash = (hash &* 31 &+ Int(b)) & 0xFFFF }
        let hue = CGFloat(hash % 360) / 360.0
        return NSColor(hue: hue, saturation: 0.55, brightness: 0.62, alpha: 1)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta { removeTrackingArea(ta) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        ta = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}
