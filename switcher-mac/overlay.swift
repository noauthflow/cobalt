import AppKit

// the overlay: a frosted-glass HUD in the spirit of the macOS app switcher.
// NSVisualEffectView gives the real system vibrancy; each row is a container
// view (badge + title + domain) whose layer gets rounded selection/hover
// backgrounds. every render deletes and rebuilds — no in-place mutation.
final class Overlay {
    static let W: CGFloat = 620
    static let ROW_H: CGFloat = 38
    static let MARGIN: CGFloat = 8      // panel padding
    static let GAP: CGFloat = 2         // between rows
    static let MAX_ROWS = 12

    private let panel: NSPanel
    private let glass: NSVisualEffectView
    private var rows: [(RowView, Int)] = []

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
    }

    func show() {
        guard let s = NSScreen.main else { return }
        let x = s.frame.midX - Overlay.W / 2
        let y = s.frame.midY + 100
        panel.setFrame(NSRect(x: x, y: y, width: Overlay.W,
                              height: Overlay.MARGIN * 2 + Overlay.ROW_H), display: false)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func render(tabs: [Browser.Tab], sel: Int, hover: Int?) {
        // visible window of rows centered on the selection
        let count = min(tabs.count, Overlay.MAX_ROWS)
        let start = tabs.isEmpty ? 0 : max(0, min(sel - Overlay.MAX_ROWS / 2, tabs.count - Overlay.MAX_ROWS))
        let visible = tabs.isEmpty ? [] : Array(tabs[start..<start + count])
        let nRows = CGFloat(max(visible.count, 1))

        // resize, keeping the top edge fixed
        let newH = Overlay.MARGIN * 2 + Overlay.ROW_H * nRows + Overlay.GAP * (nRows - 1)
        var f = panel.frame
        f.origin.y -= (newH - f.size.height)
        f.size.height = newH
        panel.setFrame(f, display: true)
        glass.frame = NSRect(origin: .zero, size: f.size)

        // rebuild everything
        glass.subviews.forEach { $0.removeFromSuperview() }
        rows.removeAll()

        if visible.isEmpty {
            let hint = NSTextField(labelWithString: "  loading tabs…")
            hint.frame = NSRect(x: Overlay.MARGIN + 4, y: (newH - Overlay.ROW_H) / 2,
                                width: Overlay.W - Overlay.MARGIN * 2 - 8, height: Overlay.ROW_H)
            hint.font = .systemFont(ofSize: 13)
            hint.textColor = NSColor.white.withAlphaComponent(0.55)
            glass.addSubview(hint)
            return
        }

        for (i, tab) in visible.enumerated() {
            let tabIndex = start + i
            let y = newH - Overlay.MARGIN - Overlay.ROW_H * (CGFloat(i) + 1) - Overlay.GAP * CGFloat(i)
            let row = RowView(frame: NSRect(x: Overlay.MARGIN, y: y,
                                            width: Overlay.W - Overlay.MARGIN * 2, height: Overlay.ROW_H),
                              tab: tab)
            row.onEnter = { [weak self] in App.shared.hover = tabIndex; self?.restyle(sel: sel, hover: tabIndex) }
            row.onExit  = { [weak self] in App.shared.hover = nil;    self?.restyle(sel: sel, hover: nil) }
            glass.addSubview(row)
            rows.append((row, tabIndex))
        }
        restyle(sel: sel, hover: hover)

        // mouse already sitting where the panel appeared → pick up hover instantly
        if let hit = hitTest(NSEvent.mouseLocation) {
            App.shared.hover = hit
            restyle(sel: sel, hover: hit)
        }
    }

    private func hitTest(_ screenPoint: NSPoint) -> Int? {
        guard panel.isVisible else { return nil }
        let local = panel.convertPoint(fromScreen: screenPoint)
        for (row, tabIndex) in rows where row.frame.contains(local) { return tabIndex }
        return nil
    }

    private func restyle(sel: Int, hover: Int?) {
        for (row, tabIndex) in rows {
            row.setSelected(tabIndex == sel, hovered: tabIndex == hover)
        }
    }
}

// one row: colored letter badge (chrome-style "no favicon" tile) + title +
// right-aligned domain. selection/hover = rounded layer background.
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

        // badge — deterministic hue per domain, like chrome's generated favicons
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

    func setSelected(_ selected: Bool, hovered: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if selected {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
            title.textColor = .white
            domain.textColor = NSColor.white.withAlphaComponent(0.8)
        } else if hovered {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
            title.textColor = NSColor.white.withAlphaComponent(0.92)
            domain.textColor = NSColor.white.withAlphaComponent(0.45)
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            title.textColor = NSColor.white.withAlphaComponent(0.88)
            domain.textColor = NSColor.white.withAlphaComponent(0.45)
        }
        CATransaction.commit()
    }

    // stable color per domain
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
