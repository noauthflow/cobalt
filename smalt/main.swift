import AppKit
import QuartzCore
import ApplicationServices
import CoreText
import CoreWLAN
import IOKit
import IOKit.ps

// smalt — ground cobalt glass.
//
// for centuries, if you wanted a strip of cobalt blue across something —
// stained glass, porcelain, delft tile — you ground cobalt glass into
// powder and laid it down. smalt is that glass — a floating cobalt pill
// docked at the right edge of the screen, dead center.
//
//   hidden by default. the cursor entering the right edge, level with the
//   pill, summons it: a real spring drives it out (underdamped — it pops
//   past the dock and settles). dropping left of the pill dismisses it.
//   the spring retargets mid-flight, so fast in-out just reverses it
//   smoothly — no completion-handler races, no flicker.
//
//   the pill shows four widgets on one grid, each in its own fixed slot:
//   battery · calendar · hour · minute.
//   mission control    off the stage — it's not part of the expose grid
//
// zero permissions: the reveal is a global mouse monitor, not an event
// tap. nothing is intercepted, nothing is rewritten, nothing is polled.

// MARK: - the design system
//
// palette + grid + type — the ONLY place visual constants exist. every
// widget is a real heroicon glyph (or type) optically centered inside one
// uniform CELL × CELL slot; the pill is exactly its grid, nothing
// hand-placed anywhere.

enum Theme {
    // palette
    static let glass   = NSColor(srgbRed: 0xFA/255.0, green: 0xF6/255.0, blue: 0xF3/255.0, alpha: 1)  // #FAF6F3 pill glass
    static let ink     = NSColor(srgbRed: 0x99/255.0, green: 0x94/255.0, blue: 0x7F/255.0, alpha: 1)  // #99947F strokes + labels
    static let inkDeep = NSColor(srgbRed: 0x3D/255.0, green: 0x38/255.0, blue: 0x29/255.0, alpha: 1)  // #3D3829 the darker on-palette ink
    static let lpm     = NSColor(srgbRed: 0xCA/255.0, green: 0x8A/255.0, blue: 0x04/255.0, alpha: 1)  // #CA8A04 low-power amber — icon + percentage, one color

    // grid — one uniform CELL slot per widget, stacked top to bottom
    static let cell: CGFloat = 30
    static let gap: CGFloat = 4
    static let pad: CGFloat = 7

    // structure: the widget stack, top to bottom — THE single source of
    // truth. the pill is exactly its grid: height derives from this list,
    // every slot loop ranges over slotCount, and adding a widget is one
    // entry here plus one case in draw(_:) — the container follows on its
    // own (the smalt answer to auto layout: the grid IS the layout).
    // a widget can claim multiple cells via `span`: a span-5 slider is one
    // continuous 5-cell region — cells inside a span have no gap between
    // them; the gap only separates widgets.
    enum Kind {
        case battery, calendar, hour, minute, slider
    }
    struct SlotDef {
        let kind: Kind
        let span: Int
        init(_ kind: Kind, span: Int = 1) { self.kind = kind; self.span = span }
    }
    static let slots: [SlotDef] = [
        .init(.battery),
        .init(.calendar),
        .init(.hour),
        .init(.minute),
        .init(.slider, span: 5),
    ]
    static var slotCount: Int { slots.count }

    // icons — heroicons, verbatim svg paths on their 24×24 grid at their
    // authored 1.5 stroke. ONE uniform scale for every glyph: the grid is
    // the point size. no per-glyph normalization — heroicons balance their
    // set optically on the shared grid (the battery is wide-and-short on
    // purpose); rescaling glyphs individually breaks that tuning.
    static let iconSize: CGFloat = 30       // grid 24 → 30pt, all icons
    static let stroke: CGFloat = 1.5        // heroicons' authored stroke, in grid units (= pt at this scale)

    // grid debug: stroke every slot + the padding bounds so the layout is
    // visible. red = widget slots, blue = where the padding ends. flip to
    // false when done squinting at it.
    static let debugGrid = false

    // type — SF Pro tabular digits at a weight whose stems sit at the icon
    // stroke weight (medium at 15pt ≈ 1.2pt vs 1.25pt strokes)
    static let typeSize: CGFloat = 19     // clock digits
    static let pctSize: CGFloat = 8       // battery percentage (6.5 for "100")

    // slider — material design 3's shape language in smalt's skin: 4dp
    // track, round handle. vertical, one CELL tall... spans 5 below the
    // time. v0 drew a fixed value; the live hardware wiring is further down.
    static let sliderTrack: CGFloat = 24   // = sliderHandle: knob and track are the same width
    static let sliderHandle: CGFloat = 24
    static let sliderFill = NSColor(srgbRed: 0x75/255.0, green: 0x56/255.0, blue: 0x4F/255.0, alpha: 1)  // #75564F value run
    static let knob      = NSColor(srgbRed: 0x3A/255.0, green: 0x2D/255.0, blue: 0x27/255.0, alpha: 1)  // #3A2D27 knob bg
    static var sliderValue: CGFloat = 0.5    // the hardware's current level (sampled)
    static var sliderDisplay: CGFloat = 0.5  // what the handle draws — springs toward sliderValue
    static var sliderFace: CGFloat = 0       // knob face crossfade: 0 = sun, 1 = %

    // the pill is exactly its grid — derived from the slot stack, never hand-counted
    static var contentHeight: CGFloat {
        // every widget's full footprint: its cells PLUS the gaps inside its
        // span — then the between-widget gaps on top. omit the internal gaps
        // and the stack overflows the glass (the vanishing bottom margin).
        slots.reduce(0) { $0 + CGFloat($1.span) * cell + CGFloat($1.span - 1) * gap }
            + CGFloat(slotCount - 1) * gap
    }
    static var pillWidth: CGFloat { cell + 2 * pad }
    static var pillHeight: CGFloat { 2 * pad + contentHeight }

    // the slot rect for widget i: its span of cells (no internal gaps),
    // offset by every widget above it. flipped coords — y grows downward.
    static func slot(_ index: Int, in bounds: NSRect) -> NSRect {
        var y = pad
        for j in 0..<index { y += CGFloat(slots[j].span) * cell + gap }
        let h = CGFloat(slots[index].span) * cell + CGFloat(slots[index].span - 1) * gap
        return NSRect(x: pad, y: y, width: cell, height: h)
    }
}

let PILL_WIDTH = Theme.pillWidth
let PILL_HEIGHT = Theme.pillHeight
let PILL_INSET: CGFloat = 0      // fused to the right screen edge — no gap
let PILL_RADIUS: CGFloat = 17
// window ≠ glass: the window is wider than the tab by this much, with the
// slack hanging off-screen right — the glass SUBVIEW springs out from
// behind the screen edge inside it. the window (cursor domain) is present
// the instant the pill summons; the pixels arrive on the spring.
let TAB_TRAVEL: CGFloat = 50     // hidden slide distance (≥ pill width)
let TAB_MARGIN: CGFloat = 6      // left slack so spring overshoot never clips
let REVEAL_WIDTH: CGFloat = 12   // summon zone: cursor within this of the right edge
let HIDE_MARGIN: CGFloat = 6     // cursor must drop this far left of the pill before it springs away
let HIDE_BAND: CGFloat = 40      // vertical hysteresis: summon at ±26px, dismiss only past ±40px —
                                 // without it, 1px of hand jitter at the band edge flips the
                                 // state every poll and the pill flaps itself to death
// spring constants: ω ≈ 23.7 rad/s, ζ ≈ 0.68 — a crisp pop with ~5% overshoot
let SPRING_K: CGFloat = 560
let SPRING_C: CGFloat = 32

final class StripView: NSView {
    override var isFlipped: Bool { true }   // y counts down from the pill top

    // the tab: rounded on the left corners, dead straight into the right
    // screen edge — no fillets, no flare
    private func tabPath(in bounds: NSRect) -> NSBezierPath {
        let R = PILL_RADIUS
        let k: CGFloat = 0.5523
        let W = bounds.width, H = bounds.height
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 0, y: R))
        p.curve(to: NSPoint(x: R, y: 0),
                controlPoint1: NSPoint(x: 0, y: R - k * R),
                controlPoint2: NSPoint(x: R - k * R, y: 0))
        p.line(to: NSPoint(x: W, y: 0))
        p.line(to: NSPoint(x: W, y: H))
        p.line(to: NSPoint(x: R, y: H))
        p.curve(to: NSPoint(x: 0, y: H - R),
                controlPoint1: NSPoint(x: R - k * R, y: H),
                controlPoint2: NSPoint(x: 0, y: H - R + k * R))
        p.line(to: NSPoint(x: 0, y: R))
        p.close()
        return p
    }

    // hover: which slot the cursor is over (-1 = none). tracked, not polled
    private var hoverSlot: Int = -1 {
        didSet { needsDisplay = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // one tracking area per slot — mouseEntered tells us which
        for i in 0..<Theme.slotCount {
            let a = NSTrackingArea(rect: Theme.slot(i, in: bounds),
                                   options: [.mouseEnteredAndExited, .activeAlways],
                                   owner: self, userInfo: ["slot": i])
            addTrackingArea(a)
        }
        // cursor defense: apps UNDER the glass (ghostty, chrome) re-assert
        // their I-beam/resize cursors when they redraw. smalt's window is
        // topmost here, so it re-wins the cursor on every cursorUpdate —
        // and resetCursorRects declares arrow for the whole window.
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.cursorUpdate, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
        // the slider is an affordance, not a label — hand cursor over it
        for i in 0..<Theme.slotCount where Theme.slots[i].kind == .slider {
            addCursorRect(Theme.slot(i, in: bounds), cursor: .pointingHand)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        // apps beneath push their cursors on redraw; re-win by position —
        // the slider slot gets the hand, everything else the arrow
        let p = convert(event.locationInWindow, from: nil)
        if let i = slotIndex(at: p), Theme.slots[i].kind == .slider {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    // re-win the arrow on demand: apps beneath push their cursors when they
    // REDRAW — no mouse event fires, so nothing above catches it. called from
    // the passive cursor-defense timer in runDaemon (and the mouse monitor).
    func reassertCursor() {
        window?.invalidateCursorRects(for: self)   // window server re-reads resetCursorRects
        if hoverSlot != -1, Theme.slots[hoverSlot].kind == .slider {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if let slot = event.trackingArea?.userInfo?["slot"] as? Int { hoverSlot = slot }
    }

    override func mouseExited(with event: NSEvent) {
        hoverSlot = -1
    }

    // ── slider drag: press anywhere in the slider slot, the value follows
    // the cursor until mouse-up. hit-test walks Theme.slots so a different
    // stack order can't break it.
    var dragSlot: Int? = nil   // file-visible: the hw-sync poll pauses while we drive

    private func slotIndex(at p: NSPoint) -> Int? {
        for i in 0..<Theme.slotCount where Theme.slot(i, in: bounds).insetBy(dx: -3, dy: 0).contains(p) {
            return i
        }
        return nil
    }

    // spring-render: Theme.sliderDisplay chases Theme.sliderValue at 120fps
    // so a sampled hardware change arrives as one smooth glide (the bezel's
    // own ~250ms feel), never a jump. runs only while it has distance to
    // cover; drags bypass it and write both directly.
    private var valueTimer: Timer?
    private var faceTimer: Timer?
    private var faceTarget: CGFloat = 0

    // crossfade the knob face (sun ⇄ %) — same recipe as the value spring:
    // a 120fps timer that runs only while the blend has distance to cover
    private func setFaceTarget(_ target: CGFloat) {
        faceTarget = target
        guard faceTimer == nil else { return }
        faceTimer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let d = self.faceTarget - Theme.sliderFace
            if abs(d) < 0.002 {
                Theme.sliderFace = self.faceTarget
                self.faceTimer?.invalidate(); self.faceTimer = nil
            } else {
                Theme.sliderFace += d * 0.25
            }
            self.needsDisplay = true
        }
        RunLoop.main.add(faceTimer!, forMode: .common)
    }

    func beginValueSpring() {
        guard abs(Theme.sliderDisplay - Theme.sliderValue) > 0.0004 else { return }
        guard valueTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let d = Theme.sliderValue - Theme.sliderDisplay
            if abs(d) < 0.0004 {
                Theme.sliderDisplay = Theme.sliderValue
                self.valueTimer?.invalidate(); self.valueTimer = nil
            } else {
                Theme.sliderDisplay += d * 0.22
            }
            self.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        valueTimer = t
    }

    private func stopValueSpring() {
        valueTimer?.invalidate(); valueTimer = nil
        Theme.sliderDisplay = Theme.sliderValue
    }

    private func updateSliderValue(at p: NSPoint) {
        guard let i = dragSlot else { return }
        let r = Theme.slot(i, in: bounds)
        // flipped coords: slot top (minY) = 1.0, bottom = 0.0
        let v = min(1, max(0, (r.maxY - p.y) / r.height))
        Theme.sliderValue = v
        KeyboardBrightness.set(Float(v))   // the F5/F6 keys' own call path
        stopValueSpring()                  // the cursor is the only spring that matters here
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = slotIndex(at: p), Theme.slots[i].kind == .slider {
            dragSlot = i
            setFaceTarget(1)
        }
        updateSliderValue(at: p)
    }

    override func mouseDragged(with event: NSEvent) {
        updateSliderValue(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        dragSlot = nil
        setFaceTarget(0)   // back to the sun the instant you release — no debounce
    }

    // the glass: #FAF6F3 — the caelestia tab shape: rounded on the left,
    // fused into the right screen edge with concave fillets top and bottom
    override func draw(_ dirtyRect: NSRect) {
        let path = tabPath(in: bounds)
        Theme.glass.setFill()
        path.fill()
        window?.invalidateShadow()   // the shadow follows the tab silhouette

        // the grid: each entry of Theme.slots draws in its own uniform
        // slot — the container is built from the same list, so widget and
        // window can never disagree
        for i in 0..<Theme.slotCount {
            let r = Theme.slot(i, in: bounds)
            switch Theme.slots[i].kind {
            case .battery: drawBattery(in: r)
            case .calendar: drawCalendar(in: r)
            case .slider: drawSlider(in: r)
            case .hour: drawClock(.hour, in: r)
            case .minute: drawClock(.minute, in: r)
            }

            // hover wash: a soft ink tint filling the whole slot, so the
            // slot itself is the hit target — same fixed grid, nothing moves.
            // the slider opts out: its dark knob is feedback enough, and the
            // wash over the thick track just made mud
            if i == hoverSlot && Theme.slots[i].kind != .slider {
                Theme.ink.withAlphaComponent(0.12).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1),
                             xRadius: 5, yRadius: 5).fill()
            }
        }

        // layout x-ray: slots in red, the pad boundary in blue. the ink of
        // every widget must sit inside its red box; the red boxes never move.
        if Theme.debugGrid {
            NSColor.systemRed.withAlphaComponent(0.55).setStroke()
            for i in 0..<Theme.slotCount {
                let r = Theme.slot(i, in: bounds).insetBy(dx: 0.5, dy: 0.5)
                NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).stroke()
            }
            NSColor.systemBlue.withAlphaComponent(0.55).setStroke()
            let p = NSBezierPath(roundedRect: bounds.insetBy(dx: Theme.pad, dy: Theme.pad),
                                 xRadius: PILL_RADIUS - Theme.pad, yRadius: PILL_RADIUS - Theme.pad)
            p.stroke()
        }
    }
}

// MARK: - drawing primitives
//
// two rules keep everything on its spot:
//   · glyphs draw on the 24×24 heroicon grid, centered in their slot
//   · text draws centered by INK (glyph bounds), not line height —
//     line-height centering leaves digits riding high, which is exactly
//     the "percentage isn't in the middle" bug

// MARK: - heroicons, verbatim
//
// the glyphs ARE the heroicons svg path data, copied unchanged from
// heroicons.com (24×24 grid, stroke-width 1.5, round caps + joins). a tiny
// parser turns each `d` string into a CGPath, so when heroicons updates an
// icon you paste in its new `d` — no hand-transcription to drift.
// (no WebKit: a webview is a whole rendering process for two strokes; the
// parser renders the same vectors synchronously, in-process.)

enum SVGPath {
    // heroicons "calendar-days" (outline) — the frame + date dots
    static let calendar = "M6.75 3v2.25M17.25 3v2.25M3 18.75V7.5a2.25 2.25 0 0 1 2.25-2.25h13.5A2.25 2.25 0 0 1 21 7.5v11.25m-18 0A2.25 2.25 0 0 0 5.25 21h13.5A2.25 2.25 0 0 0 21 18.75m-18 0v-7.5A2.25 2.25 0 0 1 5.25 9h13.5A2.25 2.25 0 0 1 21 11.25v7.5m-9-6h.008v.008H12v-.008ZM12 15h.008v.008H12V15Zm0 2.25h.008v.008H12v-.008ZM9.75 15h.008v.008H9.75V15Zm0 2.25h.008v.008H9.75v-.008ZM7.5 15h.008v.008H7.5V15Zm0 2.25h.008v.008H7.5v-.008Zm6.75-4.5h.008v.008h-.008v-.008Zm0 2.25h.008v.008h-.008V15Zm0 2.25h.008v.008h-.008v-.008Zm2.25-4.5h.008v.008H16.5v-.008Zm0 2.25h.008v.008H16.5V15Z"
    // heroicons "battery" (outline)
    static let battery = "M21 10.5h.375c.621 0 1.125.504 1.125 1.125v2.25c0 .621-.504 1.125-1.125 1.125H21M3.75 18h15A2.25 2.25 0 0 0 21 15.75v-6a2.25 2.25 0 0 0-2.25-2.25h-15A2.25 2.25 0 0 0 1.5 9.75v6A2.25 2.25 0 0 0 3.75 18Z"
    // the slider's idle sun is NOT a borrowed glyph — it's generated in
    // drawSlider from the knob digits' own font metrics (stroke == stems,
    // disc == cap height), so icon and number can never drift apart.

    // svg path `d` → CGPath. just enough of the spec for icon path data:
    // M m L l H h V v C c S s Q q T t A a Z, implicit repeats, and the
    // packed-number forms svg allows ("2.25-2.25", "1.125.504").
    static func cgPath(_ d: String) -> CGPath {
        let p = CGMutablePath()
        var rest = Substring(d)
        var cmd: Character = " "
        var cur: CGPoint = .zero        // current point
        var sub: CGPoint = .zero        // subpath start (Z returns here)
        var lastC: CGPoint = .zero      // previous cubic control (S/s)
        var lastQ: CGPoint = .zero      // previous quad control (T/t)

        func num() -> CGFloat {
            while rest.first == " " || rest.first == "," { rest = rest.dropFirst() }
            var t = ""
            var dot = false
            if rest.first == "-" || rest.first == "+" { t.append(rest.removeFirst()) }
            while let c = rest.first {
                if c.isNumber { t.append(c); rest = rest.dropFirst() }
                else if c == "." && !dot { dot = true; t.append(c); rest = rest.dropFirst() }
                else { break }               // "1.125.504" → 1.125 | .504; "2.25-2.25" splits on the sign
            }
            return CGFloat(Double(t) ?? 0)
        }

        func arc(to end: CGPoint, rx rx0: CGFloat, ry ry0: CGFloat,
                 rotation: CGFloat, large: Bool, sweep: Bool) {
            // svg endpoint→center parameterization (W3C appendix); heroicons
            // arcs are circular (rx == ry), which cg arcs are too
            var rx = abs(rx0), ry = abs(ry0)
            let φ = rotation * .pi / 180
            let (cosφ, sinφ) = (cos(φ), sin(φ))
            let dx = (cur.x - end.x) / 2, dy = (cur.y - end.y) / 2
            let x1p = cosφ * dx + sinφ * dy
            let y1p = -sinφ * dx + cosφ * dy
            let λ = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry)
            if λ > 1 { let f = sqrt(λ); rx *= f; ry *= f }
            let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
            let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
            let co = ((large != sweep) ? 1.0 : -1.0) * sqrt(max(0, num / den))
            let ccx = cosφ * (co * rx * y1p / ry) - sinφ * (-co * ry * x1p / rx) + (cur.x + end.x) / 2
            let ccy = sinφ * (co * rx * y1p / ry) + cosφ * (-co * ry * x1p / rx) + (cur.y + end.y) / 2
            let θ1 = atan2((y1p + co * ry * x1p / rx) / ry, (x1p - co * rx * y1p / ry) / rx)
            var Δθ = atan2((-y1p + co * ry * x1p / rx) / ry, (-x1p - co * rx * y1p / ry) / rx) - θ1
            if !sweep && Δθ > 0 { Δθ -= 2 * .pi }
            if sweep && Δθ < 0 { Δθ += 2 * .pi }
            p.addArc(center: CGPoint(x: ccx, y: ccy), radius: rx,
                     startAngle: θ1, endAngle: θ1 + Δθ, clockwise: !sweep)
            cur = end
        }

        while !rest.isEmpty {
            if let c = rest.first, c.isLetter {
                cmd = c
                rest = rest.dropFirst()
                if c == "Z" || c == "z" {
                    p.closeSubpath()
                    cur = sub
                    continue
                }
            }
            switch cmd {
            case "M", "m":
                var x = num(), y = num()
                if cmd == "m" { x += cur.x; y += cur.y }
                p.move(to: CGPoint(x: x, y: y))
                cur = CGPoint(x: x, y: y); sub = cur
                cmd = cmd == "M" ? "L" : "l"      // implicit linetos after a moveto
            case "L", "l":
                var x = num(), y = num()
                if cmd == "l" { x += cur.x; y += cur.y }
                p.addLine(to: CGPoint(x: x, y: y))
                cur = CGPoint(x: x, y: y)
            case "H", "h":
                var x = num()
                if cmd == "h" { x += cur.x }
                p.addLine(to: CGPoint(x: x, y: cur.y))
                cur = CGPoint(x: x, y: cur.y)
            case "V", "v":
                var y = num()
                if cmd == "v" { y += cur.y }
                p.addLine(to: CGPoint(x: cur.x, y: y))
                cur = CGPoint(x: cur.x, y: y)
            case "C", "c":
                var a = (0..<6).map { _ in num() }
                if cmd == "c" { for k in stride(from: 0, to: 6, by: 2) { a[k] += cur.x; a[k + 1] += cur.y } }
                p.addCurve(to: CGPoint(x: a[4], y: a[5]),
                           control1: CGPoint(x: a[0], y: a[1]),
                           control2: CGPoint(x: a[2], y: a[3]))
                lastC = CGPoint(x: a[2], y: a[3])
                cur = CGPoint(x: a[4], y: a[5])
            case "S", "s":
                var a = (0..<4).map { _ in num() }
                if cmd == "s" { for k in stride(from: 0, to: 4, by: 2) { a[k] += cur.x; a[k + 1] += cur.y } }
                let r = CGPoint(x: 2 * cur.x - lastC.x, y: 2 * cur.y - lastC.y)
                p.addCurve(to: CGPoint(x: a[2], y: a[3]),
                           control1: r,
                           control2: CGPoint(x: a[0], y: a[1]))
                lastC = CGPoint(x: a[0], y: a[1])
                cur = CGPoint(x: a[2], y: a[3])
            case "Q", "q":
                var a = (0..<4).map { _ in num() }
                if cmd == "q" { for k in stride(from: 0, to: 4, by: 2) { a[k] += cur.x; a[k + 1] += cur.y } }
                p.addQuadCurve(to: CGPoint(x: a[2], y: a[3]),
                               control: CGPoint(x: a[0], y: a[1]))
                lastQ = CGPoint(x: a[0], y: a[1])
                cur = CGPoint(x: a[2], y: a[3])
            case "T", "t":
                var x = num(), y = num()
                if cmd == "t" { x += cur.x; y += cur.y }
                let c = CGPoint(x: 2 * cur.x - lastQ.x, y: 2 * cur.y - lastQ.y)
                p.addQuadCurve(to: CGPoint(x: x, y: y), control: c)
                lastQ = c
                cur = CGPoint(x: x, y: y)
            case "A", "a":
                let rx = num(), ry = num(), rot = num()
                let large = num() != 0, sweep = num() != 0
                var x = num(), y = num()
                if cmd == "a" { x += cur.x; y += cur.y }
                arc(to: CGPoint(x: x, y: y), rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
            default:
                rest = rest.dropFirst()
            }
        }
        return p
    }
}

// renders a heroicon `d` inside a slot: the 24 grid scaled to iconSize,
// stroked at the svg's own 1.5 with round caps + joins (as authored)
enum Heroicon {
    // draws a heroicon `d` on its own 24 grid, uniformly scaled so the grid
    // is `size` points — the same relation every heroicon has to every other
    // one on heroicons.com. stroke is the authored 1.5 in grid units, so
    // every icon carries the set's own weight, identically.
    static func draw(_ d: String, color: NSColor, in slot: NSRect, size: CGFloat? = nil) {
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.saveGState()
        let s = (size ?? Theme.iconSize) / 24
        ctx.translateBy(x: slot.midX, y: slot.midY)
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -12, y: -12)
        ctx.addPath(SVGPath.cgPath(d))
        ctx.setLineWidth(Theme.stroke)    // 1.5 grid units — the authored weight
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        color.setStroke()
        ctx.strokePath()
        ctx.restoreGState()
    }

    // a rect in svg-grid coordinates → view rect, for text inside a glyph
    static func gridRect(_ r: CGRect, in slot: NSRect) -> NSRect {
        let s = Theme.iconSize / 24
        return NSRect(x: slot.midX + (r.minX - 12) * s,
                      y: slot.midY + (r.minY - 12) * s,
                      width: r.width * s, height: r.height * s)
    }
}

// text centered on its ink — CoreText glyph bounds, not the line box
func drawText(_ s: String, font: NSFont, color: NSColor, in r: NSRect) {
    let line = CTLineCreateWithAttributedString(NSAttributedString(
        string: s, attributes: [.font: font, .foregroundColor: color]))
    let inkBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    ctx.translateBy(x: r.midX, y: r.midY)   // to the slot center…
    ctx.scaleBy(x: 1, y: -1)                // …unflip for CoreText (y-up)
    ctx.textMatrix = .identity
    ctx.translateBy(x: -inkBounds.midX, y: -inkBounds.midY)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

extension NSFont {
    // SF Pro, tabular digits — the clock's voice, weight-matched to the strokes
    static func tabular(_ size: CGFloat, _ weight: NSFont.Weight = .medium) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}

// MARK: - keyboard brightness
//
// CoreBrightness (private framework, linked in install.sh): its
// KeyboardBrightnessClient class is what the system itself uses for the
// F5/F6 keys. value is a Float 0–1, no permissions required. the hardware
// is the state — the slider reads it at launch and writes it on drag.
enum KeyboardBrightness {
    private static var client: NSObject = {
        (NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type)?.init() ?? NSObject()
    }()

    static var available: Bool {
        client.responds(to: NSSelectorFromString("setBrightness:forKeyboard:"))
    }

    static func get() -> Float {
        typealias Fn = @convention(c) (AnyObject, Selector, Int) -> Float
        let sel = NSSelectorFromString("brightnessForKeyboard:")
        guard client.responds(to: sel) else { return 0 }
        return unsafeBitCast(client.method(for: sel), to: Fn.self)(client, sel, 1)
    }

    static func set(_ value: Float) {
        typealias Fn = @convention(c) (AnyObject, Selector, Float, Int) -> Void
        let sel = NSSelectorFromString("setBrightness:forKeyboard:")
        guard client.responds(to: sel) else { return }
        unsafeBitCast(client.method(for: sel), to: Fn.self)(client, sel, max(0, min(1, value)), 1)
    }
}

// MARK: - widgets
//
// heroicons, verbatim: the svg `d` strings, stroked at their authored 1.5
// on the 24 grid — one consistent ink, weight-matched to the tabular
// digits. sources are permission-free: IOKit power sources, the clock,
// ProcessInfo low-power state.

// IOKit power sources — the same thing the native battery item reads
func batteryLevel() -> (pct: Int, charging: Bool)? {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for ps in list {
        guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
              let cap = d[kIOPSCurrentCapacityKey] as? Int,
              let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
        return (Int((Double(cap) / Double(max) * 100).rounded()), d[kIOPSIsChargingKey] as? Bool == true)
    }
    return nil
}

// heroicons battery, verbatim — no fill, just the glyph; the percentage
// sits optically centered in the body. low power mode: icon + number in
// one amber.
func drawBattery(in slot: NSRect) {
    guard let (pct, _) = batteryLevel() else { return }
    let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    let color = lowPower ? Theme.lpm : Theme.ink
    Heroicon.draw(SVGPath.battery, color: color, in: slot)

    // the number, inside the body (svg rect x1.5–21, y7.5–18): same tabular
    // font as the clock, semibold so its stems match the icon's 1.5pt
    // stroke, sized to fill the body VERTICALLY (SF Pro cap height ≈ 0.72em)
    let body = Heroicon.gridRect(CGRect(x: 2.5, y: 8, width: 17.5, height: 9.5), in: slot)
    var size = body.height / 0.72
    // "100" has to fit the body width too — shrink only if it wouldn't
    let wide = ("100" as NSString).size(withAttributes: [.font: NSFont.tabular(size, .semibold)]).width
    if wide > body.width { size *= body.width / wide }
    drawText("\(pct)", font: .tabular(size, .semibold), color: color, in: body)
}

// heroicons calendar-days, verbatim
func drawCalendar(in slot: NSRect) {
    Heroicon.draw(SVGPath.calendar, color: Theme.ink, in: slot)
}

// time: hour over minute — one CELL slot each, tabular SF Pro centered
func drawClock(_ component: Calendar.Component, in slot: NSRect) {
    let value = String(format: "%02d", Calendar.current.component(component, from: Date()))
    drawText(value, font: .tabular(Theme.typeSize), color: Theme.ink, in: slot)
}

// material design 3 slider, vertical, in smalt's skin — M3's own metrics
// (4dp track, round handle) drawn with CG, but inked
// in the palette instead of M3's. one CELL slot below the time. v0 draws
// the live keyboard backlight (CoreBrightness); drag writes straight to it.
func drawSlider(in slot: NSRect) {
    let v = max(0, min(1, Theme.sliderDisplay))
    let cx = slot.midX
    let knobSize = Theme.sliderHandle

    // handle center travel: v=0 parks at the bottom, v=1 at the top —
    // up means more, matching updateSliderValue's drag mapping
    let yBottom = slot.maxY - knobSize / 2
    let yTop = slot.minY + knobSize / 2
    let hc = yBottom + (yTop - yBottom) * v

    // track: one thick rounded bar the full slot height. the quiet run is
    // the value color held to 30%; below the knob it runs solid #75564F
    let trackRect = NSRect(x: cx - Theme.sliderTrack / 2, y: slot.minY,
                           width: Theme.sliderTrack, height: slot.height)
    Theme.sliderFill.withAlphaComponent(0.3).setFill()
    NSBezierPath(roundedRect: trackRect, xRadius: Theme.sliderTrack / 2,
                 yRadius: Theme.sliderTrack / 2).fill()
    // active run: FLAT-top fill from the knob's center line down. a rounded
    // top here bulges up at the center while the knob's circle bulges down —
    // two opposing arcs with air at the sides (the gap). flat meets the knob
    // exactly; 1px of overlap kills the antialiasing seam. clipped to the
    // track so the stadium silhouette survives.
    if let ctx = NSGraphicsContext.current?.cgContext {
        ctx.saveGState()
        NSBezierPath(roundedRect: trackRect, xRadius: Theme.sliderTrack / 2,
                     yRadius: Theme.sliderTrack / 2).addClip()
        Theme.sliderFill.setFill()
        NSBezierPath(rect: NSRect(x: trackRect.minX, y: hc - 1,
                                  width: trackRect.width,
                                  height: trackRect.maxY - hc + 1)).fill()
        ctx.restoreGState()
    }

    // knob: solid dark disc — the fill IS the weight, no stroke
    let handle = NSRect(x: cx - knobSize / 2, y: hc - knobSize / 2,
                        width: knobSize, height: knobSize)
    Theme.knob.setFill()
    NSBezierPath(ovalIn: handle).fill()

    // the face: implode/explode — the outgoing glyph collapses into the
    // knob's center while the incoming one grows out of it. scale carries
    // the motion; alpha only cleans up the sub-pixel ends.
    let face = max(0, min(1, Theme.sliderFace))
    let edgeAlpha: (CGFloat) -> CGFloat = { min(1, $0 * 4) }

    // the % — tabular semibold, shrink-to-fit like the battery's "100".
    // the size + stroke live in KnobFace so the sun below is built from
    // the digits' own rendered metrics, by construction.
    let pct = Int((Theme.sliderValue * 100).rounded())
    let pctFont = NSFont.tabular(KnobFace.base, .semibold)

    if face > 0 {
        drawText("\(pct)", font: .tabular(KnobFace.base * face, .semibold),
                 color: Theme.glass.withAlphaComponent(edgeAlpha(face)), in: handle)
    }

    if face < 1 {
        // the sun, generated from the digits' own metrics — not a borrowed
        // glyph (the old Phosphor path shipped 1.125pt strokes against
        // 1.24pt stems). the stroke IS KnobFace.stem — measured off the
        // rendered '0', because that's what the eye weighs the ring
        // against — and the disc IS the cap height.
        let f = 1 - face
        let stem = KnobFace.stem
        let cap = pctFont.capHeight
        let discD = cap                 // disc outer diameter == cap height
        let air   = 1.1 * stem          // disc→ray air, a shade over a stem
        let ray   = 1.4 * stem          // ray length: a stroke, not a dot
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.saveGState()
        ctx.translateBy(x: handle.midX, y: handle.midY)
        ctx.scaleBy(x: f, y: f)         // implode/explode carries the crossfade
        ctx.setLineWidth(stem)
        ctx.setLineCap(.round)
        Theme.glass.withAlphaComponent(edgeAlpha(f)).setStroke()
        // ring: stroke is centered on the path, so radius = disc outer − stem/2
        ctx.addArc(center: .zero, radius: discD / 2 - stem / 2,
                   startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        // eight rays, round caps — the pill's one stroke language, everywhere
        for i in 0..<8 {
            let a = CGFloat(i) * .pi / 4
            let c = cos(a), s = sin(a)
            ctx.move(to: CGPoint(x: c * (discD / 2 + air), y: s * (discD / 2 + air)))
            ctx.addLine(to: CGPoint(x: c * (discD / 2 + air + ray), y: s * (discD / 2 + air + ray)))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
}

// the knob face's shared numbers — one font for the % and one stroke
// width for both faces, measured (not estimated) so they can't drift.
enum KnobFace {
    // the shrink-to-fit size drawSlider's % settles at ("100" must fit)
    static let base: CGFloat = {
        var b: CGFloat = 12
        let wide = ("100" as NSString).size(withAttributes: [.font: NSFont.tabular(b, .semibold)]).width
        return wide > Theme.sliderHandle - 6 ? b * (Theme.sliderHandle - 6) / wide : b
    }()

    // the stroke width the eye actually sees on the digits: a scanline
    // through an 8× rendered '0'. SF Pro cuts curved strokes fatter than
    // the 'l' stem (~12% here — optical compensation), so measuring 'l'
    // left the sun's ring visibly thin next to the number it swaps with.
    static let stem: CGFloat = {
        let font = NSFont.tabular(base, .semibold)
        let s = 8, w = 32, h = 32
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w * s, pixelsHigh: h * s,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .calibratedRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = ctx
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "0", attributes: [.font: font, .foregroundColor: NSColor.black]))
        ctx.cgContext.translateBy(x: 8, y: 8)   // clear of the edges
        ctx.cgContext.textMatrix = .identity
        CTLineDraw(line, ctx.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        // locate the ink, then scan the row through its vertical middle —
        // the '0' is widest at mid-height (vertical-tangent bowls), and
        // anchoring to the rendered ink instead of the baseline makes the
        // scan immune to context orientation/offset quirks.
        var minX = w * s, maxX = 0, minY = h * s, maxY = 0
        for py in 0..<(h * s) { for px in 0..<(w * s) {
            if rep.colorAt(x: px, y: py)!.alphaComponent > 0.1 {
                minX = min(minX, px); maxX = max(maxX, px)
                minY = min(minY, py); maxY = max(maxY, py)
            }
        } }
        guard maxX > minX else { return 1 }
        let py = (minY + maxY) / 2
        var best = CGFloat(0), run = 0
        for px in 0..<(w * s) {
            if rep.colorAt(x: px, y: py)!.alphaComponent > 0.5 {
                run += 1
            } else if run > 0 {
                best = max(best, CGFloat(run) / CGFloat(s)); run = 0
            }
        }
        if run > 0 { best = max(best, CGFloat(run) / CGFloat(s)) }
        return best > 0 ? best : 1
    }()
}

// MARK: - state

// stderr debug tracing — off unless built with -D SMALT_DEBUG (stderr → /tmp/smalt.err)
func dbg(_ s: String) {
#if SMALT_DEBUG
    FileHandle.standardError.write(Data((s + "\n").utf8))
#endif
}

var stripVisible = false       // hidden until the cursor hovers the right edge

// the slider's state IS the hardware: read the real keyboard backlight once
// at launch, then every drag writes straight through to it
if KeyboardBrightness.available {
    let hw = CGFloat(KeyboardBrightness.get())
    Theme.sliderValue = hw
    Theme.sliderDisplay = hw
} else {
    dbg("keyboard brightness: KeyboardBrightnessClient unavailable — slider is visual-only")
}
var evalItem: DispatchWorkItem?
var pendingRelease = false     // key-drop deferred until the exit spring parks the glass

func mainScreen() -> NSScreen? {
    // the CG main display — cursor global coordinates are relative to THIS
    // screen's arrangement, so the pill must anchor to the same one.
    NSScreen.screens.first { displayID($0) == CGMainDisplayID() } ?? NSScreen.main
}

// where the WINDOW lives: docked, permanently, from launch. the cursor
// always lands on smalt at the screen edge — chrome's `<>` border never
// gets it. the window extends TAB_TRAVEL + TAB_MARGIN past the screen
// edge; that off-screen slack is where the hidden glass parks.
func pillFrame() -> NSRect {
    guard let screen = mainScreen() else { return .zero }
    let f = screen.frame
    let w = PILL_WIDTH + 2 * TAB_MARGIN + TAB_TRAVEL
    return NSRect(x: f.maxX - TAB_MARGIN - PILL_WIDTH, y: f.minY + (f.height - PILL_HEIGHT) / 2,
                  width: w, height: PILL_HEIGHT)
}

// MARK: - the spring
//
// one driver, one target, retargetable mid-flight. driven by a screen-
// attached CADisplayLink — display-synced, and tied to the SCREEN rather
// than the pill's view, so it keeps firing while the pill's window is
// off-screen (the pill's resting state). ticks land on the main run loop.
// a watchdog falls back to a plain timer if the link ever goes quiet (and
// for pre-14 systems). measured dt: physics time is wall time. when the
// spring settles, the link is stopped — zero CPU between animations.

final class SpringDriver: NSObject {
    private var link: CADisplayLink?
    private var fallbackTimer: Timer?
    private(set) var running = false
    var x: CGFloat = 0
    var v: CGFloat = 0
    var target: CGFloat = 0
    var last: CFTimeInterval = 0

    var onSettle: (() -> Void)?

    func chase(_ targetX: CGFloat) {
        target = targetX
        guard !running else { return }             // already chasing — just retargeted
        x = tab.frame.origin.x
        v = 0
        last = 0
        if #available(macOS 14.0, *), let screen = mainScreen() {
            let dl = screen.displayLink(target: self, selector: #selector(tick(_:)))
            dl.add(to: .main, forMode: .common)
            link = dl
            running = true
            // watchdog: if the link never fires (occluded-screen edge cases),
            // fall back to a plain timer rather than freezing mid-flight
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.running, self.last == 0 else { return }
                self.link?.invalidate()
                self.link = nil
                self.startFallbackTimer()
            }
        } else {
            startFallbackTimer()
        }
    }

    private func startFallbackTimer() {
        let t = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] _ in self?.integrate() }
        t.tolerance = 1 / 240
        RunLoop.main.add(t, forMode: .common)
        fallbackTimer = t
        running = true
    }

    @objc private func tick(_ dl: CADisplayLink) { integrate() }

    private func integrate() {
        guard running else { return }
        let now = CACurrentMediaTime()
        var dt = last == 0 ? 1 / 120 : CGFloat(now - last)
        last = now
        dt = min(dt, 1 / 30)                       // clamp huge gaps (display sleep, etc.)
        let accel = -SPRING_K * (x - target) - SPRING_C * v
        v += accel * dt
        x += v * dt
        var f = tab.frame
        f.origin.x = x.rounded()               // whole pixels: no subpixel shimmer on the glass
        tab.setFrameSize(f.size); tab.setFrameOrigin(f.origin)
        tab.needsDisplay = true
        if abs(x - target) < 0.25, abs(v) < 2 {
            f.origin.x = target
            tab.setFrameSize(f.size); tab.setFrameOrigin(f.origin)
            tab.needsDisplay = true
            stop()
            onSettle?()
            onSettle = nil
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        running = false
        last = 0
    }
}

let spring = SpringDriver()

func applyVisibility(_ desired: Bool, animate: Bool = true) {
    // click-through follows visibility: while the glass is hidden smalt is
    // invisible at the edge, so it must not eat clicks there either — the
    // apps beneath get their edge back. visible glass: smalt takes the
    // click (and the keyboard — see takeAttention, hover attention).
    let clickThrough = cmdOverride || !desired
    if strip.ignoresMouseEvents != clickThrough { strip.ignoresMouseEvents = clickThrough }
    let changed = desired != stripVisible
    stripVisible = desired
    if changed { dbg("applyVisibility → \(desired)") }
    if desired { pendingRelease = false }   // back on stage — attention wanted again
    else { releaseAttention() }             // off the stage → hand focus back (deferred till parked)
    guard changed else { return }
    // summoning while the lock zoom is coming up: verify once before the
    // spring starts — otherwise the glass animates out mid-transition and
    // the user watches it race the login screen
    if desired, !sessionLocked, loginWindowOnScreen() {
        setSessionLocked(true)              // parks + orders out synchronously
        return
    }
    // (visibility = glass position; see below)
    // the window never moves. but it's only ON STAGE while the glass is:
    // parked = ordered out. the old design kept the window fronted forever
    // ("it owns the screen edge") with the glass parked in its off-screen
    // slack — which the lock-screen zoom then composites un-clipped, flash-
    // ing the parked glass mid-animation even with the cursor nowhere near
    // the edge. while hidden the window is click-through and transparent:
    // it owns nothing. out it goes; summon re-fronts before the glass moves.
    spring.stop()
    spring.onSettle = nil
    if desired { strip.orderFrontRegardless() }   // back on stage before the glass moves
    if !animate {
        var g = tab.frame
        g.origin.x = glassX(docked: desired)
        tab.setFrameSize(g.size); tab.setFrameOrigin(g.origin)
        tab.needsDisplay = true
        if !desired { flushPendingRelease() }   // parked instantly — release now
        return
    }
    spring.chase(glassX(docked: desired))
    if !desired { spring.onSettle = { flushPendingRelease() } }   // release after the exit spring lands
}

// current cursor position. CGEvent coordinates are global, top-left origin —
// NOT relative to any screen. cocoa x == cg x; cg y = globalTop − cocoa y.
// the cg origin is the top-left of the CG PRIMARY display = NSScreen index
// 0 — NOT the top of the tallest display. (the old version used max maxY:
// correct on one monitor, silently broken the moment a taller monitor sits
// above the primary — the summon zone landed 1440px into empty space and
// the pill could never appear at all.)
var globalCocoaTopY: CGFloat {
    NSScreen.screens.first { $0.frame.origin == NSPoint.zero }?.frame.maxY
        ?? NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
}
func cursorXFromRight() -> CGFloat {
    guard let loc = CGEvent(source: nil)?.location, let screen = mainScreen() else { return .infinity }
    return screen.frame.maxX - loc.x
}

// the pill's vertical band, in CG top-left coordinates — the same space the
// cursor reports in. (the old version mixed coordinate spaces: on any
// display arrangement where the main display wasn't at the global origin,
// the summon zone stopped matching the pill's real position.)
func pillBandCG() -> (top: CGFloat, bottom: CGFloat) {
    let fr = pillFrame()
    let top = globalCocoaTopY - fr.maxY
    return (top, top + fr.height)
}

// cmd override: while command is held, smalt gets out of the way
// entirely — the window goes click-through ("ignores mouse events") so
// anything underneath is reachable right up to the screen edge, and the
// glass hides. checked on every mouse event via the event source's flag
// state (no key monitoring, no permissions); a bool cache avoids
// re-toggling the window on every move.
var cmdOverride = false

func setCmdOverride(_ on: Bool) {
    guard on != cmdOverride else { return }
    cmdOverride = on
    applyVisibility(on ? false : stripVisible)
}

func cmdHeld() -> Bool {
    CGEventSource.flagsState(.hidSystemState).contains(.maskCommand)
}

// MARK: - hover attention
//
// the base macOS truth this used to fight: a window's cursor rects (what
// pins the arrow) only go live while that window is KEY — and keystrokes
// flow to the key window. a background overlay's rects can be overridden
// by any redraw of the active app, and its windows never see keystrokes.
// the menu bar doesn't fight this because WindowServer owns it.
//
// the escape hatch smalt already had: a .nonactivatingPanel can hold KEY
// status without its app ever becoming active — floating-palette rules.
// that is exactly what clicking the pill used to do (fixing the cursor
// AND taking the keystrokes) — the catch was the panel held key forever
// after, which is where the re-click-everything tax came from.
//
// so attention is now just that, automated:
//   hover-enter  → strip.makeKey()   — arrow is law, keys land on the pill
//   hover-exit   → drop key (orderOut, no activation) and
//                  the active app's window regains key on its own
// no activation anywhere: no menu-bar flash, no cooperative-activation
// denial, nothing to hand back — the app beneath stays active the whole
// time and simply gets its key window back when smalt lets go.

func takeAttention() {
    pendingRelease = false   // attending again — cancel any deferred release
    guard !strip.isKeyWindow else { return }
    strip.makeKey()
    dbg("attention taken: key=\(strip.isKeyWindow)")
}

func releaseAttention() {
    // HOLD key while the glass is anywhere on stage — docked or mid-spring.
    // dropping key orderOuts the window, and doing that mid-animation is
    // what made the pill flicker itself to death near the band edges: the
    // exit spring gets murdered, the glass blinks out instead of animating
    // outwards, the poll re-summons, repeat. the release lands the moment
    // the glass is parked (spring settle / snap / immediate when parked).
    if tab.frame.origin.x < glassX(docked: false) - 1 { pendingRelease = true; return }
    flushPendingRelease()
}

func flushPendingRelease() {
    pendingRelease = false
    // parked = off stage ENTIRELY: order out and stay out. the parked glass
    // lives in the window's off-screen slack, and an ordered-in window with
    // off-screen content is exactly what the lock-screen zoom reveals (it
    // composites un-clipped mid-animation). the key drop comes free: the
    // active app regains key the instant we resign. summon re-fronts.
    strip.orderOut(nil)
    dbg("attention released: window ordered out")
}

// MARK: - fullscreen + mission control detection
// same trick as cobalt-60: a layer-0 window matching a display's bounds
// means that display is owned by a fullscreen app. mission control fakes
// it (every space's windows are "onscreen" up there) — the dock's
// full-screen backdrop is the signal that MC is active.

func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
    screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
}

func mainDisplayFullscreen() -> Bool {
    guard let screen = mainScreen(), let id = displayID(screen) else { return false }
    let db = CGDisplayBounds(id)
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
    return list.contains { d in
        guard (d[kCGWindowLayer as String] as? Int) == 0,
              let b = d[kCGWindowBounds as String] as? [String: NSNumber] else { return false }
        let w = CGRect(x: b["X"]?.doubleValue ?? 0, y: b["Y"]?.doubleValue ?? 0,
                       width: b["Width"]?.doubleValue ?? 0, height: b["Height"]?.doubleValue ?? 0)
        return abs(w.minX - db.minX) <= 2 && abs(w.minY - db.minY) <= 2 &&
               w.width >= db.width - 2 && w.height >= db.height - 2
    }
}

func missionControlActive() -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
    let main = CGDisplayBounds(CGMainDisplayID())
    return list.contains { d in
        guard let owner = d[kCGWindowOwnerName as String] as? String, owner == "Dock",
              let layer = d[kCGWindowLayer as String] as? Int, layer > 0,
              let b = d[kCGWindowBounds as String] as? [String: NSNumber],
              let w = b["Width"]?.doubleValue, let h = b["Height"]?.doubleValue else { return false }
        return w >= main.width * 0.9 && h >= main.height * 0.9
    }
}

// MARK: - evaluation

var mcActive = false              // cached mission-control state (re-checked on space/app changes)

func updateStrip() {
    guard !sessionLocked else { return }           // locked: notifications don't summon
    mcActive = missionControlActive()
    if mcActive {
        applyVisibility(false)                                 // mission control: off the stage
    } else {
        // hover decides: visible iff the cursor is in the summon zone —
        // within 12px of the right edge, level with the pill.
        let (top, bottom) = pillBandCG()
        guard let loc = CGEvent(source: nil)?.location else { return }
        let inBand = loc.y >= top - 26 && loc.y <= bottom + 26
        let xr = cursorXFromRight()
        // a hovered glass stays on stage even if a notification lands here
        // (app switch, quit, space change) — the summon zone only decides
        // the hidden → visible transition, never "you were hovering, bye"
        let hovered = stripVisible && xr <= PILL_WIDTH && inBand
        applyVisibility(xr <= REVEAL_WIDTH && inBand || hovered)
    }
}

// debounce — space/app transitions fire notification bursts
func scheduleUpdate() {
    evalItem?.cancel()
    let item = DispatchWorkItem { updateStrip() }
    evalItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
}

// MARK: - session lock
//
// the lock screen composites level-21 canJoinAllSpaces windows above its
// UI — and nothing here knew the difference. the 30Hz poll happily chased
// the cursor around the login window, so smalt sat on the lock screen
// springing in and out of the edge. while locked: window OUT, every cursor
// path dead, nothing renders on the login screen at all.
//
// ground truth is the CGWindowList scan below: the lock screen IS a
// fullscreen loginwindow window, and it's on screen from the first frame
// of the zoom — faster than any notification (the distributed lock notice
// and the workspace session notices all lag the animation, which is how
// the summon logic kept racing the transition). the scan costs ~1ms, so
// it runs where that buys something: every tick the glass is on stage
// (the flash case), throttled while locked, never at idle. notifications
// stay as the fast path.
var sessionLocked = false
var pollTick = 0

func setSessionLocked(_ locked: Bool) {
    guard locked != sessionLocked else { return }
    sessionLocked = locked
    if locked {
        spring.stop()
        applyVisibility(false, animate: false)   // park instantly — no spring on the way out
        releaseAttention()                        // drop any key/focus claim
        strip.orderOut(nil)                       // gone from the lock screen entirely
    } else {
        strip.orderFrontRegardless()              // back on every space
        scheduleUpdate()                          // re-derive hover state from the live cursor
    }
}

// is the lock screen (or its zoom) on stage? a loginwindow-owned window
// covering the main display — same shape as missionControlActive's Dock check
func loginWindowOnScreen() -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
    let main = CGDisplayBounds(CGMainDisplayID())
    return list.contains { d in
        guard let owner = d[kCGWindowOwnerName as String] as? String, owner == "loginwindow",
              let b = d[kCGWindowBounds as String] as? [String: NSNumber],
              let w = b["Width"]?.doubleValue, let h = b["Height"]?.doubleValue else { return false }
        return w >= main.width * 0.9 && h >= main.height * 0.9
    }
}

// MARK: - the pill (window)

// MARK: - the pill (window + glass subview)
//
// the window spans docked-glass + slack on both sides; the glass tab is a
// SUBVIEW whose x the spring drives between docked (flush with the screen
// edge) and hidden (fully off-screen). the window is only ever in one of
// two places — docked (summon: instant, so the cursor lands on it at once)
// or off-screen (hidden, after the exit spring settles).

let tab: StripView = {
    let v = StripView(frame: NSRect(origin: .zero, size: NSSize(width: PILL_WIDTH, height: PILL_HEIGHT)))
    return v
}()

// where the glass sits inside the window: docked (flush at the screen edge
// with TAB_MARGIN of overshoot slack to its left) vs hidden (past the edge)
func glassX(docked: Bool) -> CGFloat { docked ? TAB_MARGIN : TAB_MARGIN + TAB_TRAVEL }

// the panel is key-capable but never main. being KEY is the point: cursor
// rects only go live while the window is key, and keystrokes flow to the
// key window — hover attention (takeAttention) makes the panel key while
// the cursor is on the glass. borderless panels refuse key status by
// default, so this override is what makes the whole attention model legal.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

let strip: NSWindow = {
    let frame = pillFrame()
    let win = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    win.backgroundColor = .clear
    win.isOpaque = false
    win.hasShadow = true
    win.ignoresMouseEvents = false
    win.level = NSWindow.Level(rawValue: 21)
    win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
    container.addSubview(tab)
    win.contentView = container
    return win
}()

// MARK: - daemon

func runDaemon() -> Never {
    // NSApplication is required for workspace/screen notifications to fire.
    // accessory = no dock icon.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    // hardware sync: F5/F6 and the auto-brightness daemon change the
    // backlight behind our back. there is no push channel at our privilege
    // level — proven empirically: CoreBrightness posts no darwin
    // notification and the Keyboard Backlight HID device rejects listeners
    // (privileged) — so sample. adaptive rate: 30Hz while the glass is on
    // stage (52µs per read → 0.16% of a core), 2Hz hidden. the RENDER is
    // decoupled from the SAMPLE: the handle springs to each new value at
    // 120fps, so even coarse samples glide like the system's own bezel.
    let hwSync = DispatchSource.makeTimerSource(queue: .main)
    enum HwSync {
        static let liveInterval: TimeInterval = 1.0 / 30.0   // visible: 0.16% CPU, reads track live
        static let idleInterval: TimeInterval = 0.5          // hidden: nobody's watching
        static var deadline: DispatchTime = .now()
    }
    func scheduleHwSync() {
        let dt = stripVisible ? HwSync.liveInterval : HwSync.idleInterval
        HwSync.deadline = .now() + dt
        hwSync.schedule(deadline: HwSync.deadline)
    }
    hwSync.setEventHandler {
        defer { scheduleHwSync() }
        guard KeyboardBrightness.available else { return }
        guard tab.dragSlot == nil else { return }   // mid-drag: we ARE the writer
        let hw = CGFloat(KeyboardBrightness.get())
        if abs(hw - Theme.sliderValue) > 0.001 {
            Theme.sliderValue = hw
            if stripVisible { tab.beginValueSpring() }
            else { Theme.sliderDisplay = hw }
        }
    }
    scheduleHwSync()
    hwSync.resume()

    // the window is docked from this moment on — it owns the screen edge
    // while on stage (that's the cursor fix); only the glass ever moves.
    // parked at launch = ordered out: an ordered-in window with off-screen
    // content is what the lock-screen zoom reveals.
    strip.setFrame(pillFrame(), display: true)
    var g = tab.frame
    g.origin.x = glassX(docked: false)   // glass parked off-screen at launch
    tab.setFrameSize(g.size); tab.setFrameOrigin(g.origin)
    applyVisibility(false, animate: false)   // parked = click-through at the edge → window OUT

    // the summon. a global mouse monitor — not an event tap — so there is
    // nothing to intercept and nothing to grant. the cursor entering the
    // right edge, level with the pill, springs it out; dropping left of the
    // pill (or past its band) springs it away. hysteresis between the two
    // lines means edge jitter can't flicker it — and the spring retargets,
    // so even fast in-out is a smooth reversal, never a glitch.
    NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .otherMouseDragged]) { _ in
        guard !sessionLocked else { return }       // lock screen: the edge is nobody's
        // cmd held: the edge is yours — no window, no glass, no cursor take-over
        setCmdOverride(cmdHeld())
        if cmdOverride { return }
        let (top, bottom) = pillBandCG()
        guard let loc = CGEvent(source: nil)?.location else { return }
        let y = loc.y
        let xr = cursorXFromRight()
        // cursor defense: while the cursor is over smalt's window (the tab
        // band, at the edge), smalt owns the cursor — apps underneath
        // re-assert their I-beam/resize cursors on redraw, so re-win it
        // on every move. arrow regardless of modifier flags — cmd never
        // changes anything here. one NSCursor.set, no tap, no permissions.
        // cursor defense, active side: while the cursor is over the glass,
        // smalt owns the cursor — apps underneath re-assert their I-beam/
        // resize cursors, so re-win on every move. (the old check, xr <= 0,
        // meant "cursor past the screen edge" — it almost never fired, which
        // is why the I-beam kept leaking through.)
        if stripVisible, xr <= PILL_WIDTH, y >= top, y <= bottom {
            tab.reassertCursor()
        }
        if xr <= REVEAL_WIDTH, y >= top - 26, y <= bottom + 26 {
            applyVisibility(true)
        } else if xr > PILL_WIDTH + HIDE_MARGIN || y > bottom + HIDE_BAND || y < top - HIDE_BAND {
            applyVisibility(false)
        }
    }

    let wnc = NSWorkspace.shared.notificationCenter
    _ = [
        wnc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in scheduleUpdate() },
        wnc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in scheduleUpdate() },
        wnc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { _ in scheduleUpdate() },
        // lock/unlock: screen lock comes via distributed notifications, fast
        // user switching via the session lifecycle — cover both.
        wnc.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { _ in setSessionLocked(true) },
        wnc.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { _ in setSessionLocked(false) },
    ]
    let dnc = DistributedNotificationCenter.default()
    dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in setSessionLocked(true) }
    dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in setSessionLocked(false) }

    // display reconfiguration: resolution switch, monitor plug/unplug
    NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification,
        object: nil, queue: .main
    ) { _ in
        updateStrip()
        applyVisibility(stripVisible, animate: false)   // snap to the new geometry, don't slide
    }

    // widgets tick — the clock is minute-grade, a 10s repaint is plenty
    // (and cheap: the window only repaints on demand)
    Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
        strip.contentView?.needsDisplay = true
    }

    // the attention engine — the poll that drives the whole hover state
    // machine. the global monitor stays as the fast path for real mouse
    // moves, but the state itself is POSITION-driven here: summon, hide,
    // and attention all follow the cursor whether or not an event made it
    // to the monitor (programmatic warps, missed coalesced events, etc).
    // cursor on the glass → take activation + key (arrow is then guaranteed:
    // the active app's cursor rects can't be overridden by a background
    // redraw); cursor off the glass → focus hands straight back. cmd is
    // re-checked here too, because while smalt is active its own window
    // swallows mouse events — the global monitor goes quiet.
    Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { _ in
        // lock ground truth. the flash budget: a glass that's on stage at
        // lock-press (hovering, or mid-spring) is what rides the zoom — so
        // while VISIBLE, scan EVERY tick (≤33ms ≈ one zoom frame, ≤3% of a
        // core for the seconds the user is actually at the edge); while
        // LOCKED, throttled self-heal only (nobody's watching, save the
        // battery); idle + unlocked — the resting state — pays nothing.
        pollTick += 1
        if stripVisible || (sessionLocked && pollTick % 4 == 0) {
            let locked = loginWindowOnScreen()
            if locked != sessionLocked { setSessionLocked(locked) }
        }
        guard !sessionLocked else { return }       // locked: no summon, no attention, nothing
        setCmdOverride(cmdHeld())
        if cmdOverride { releaseAttention(); return }
        if mcActive { applyVisibility(false); releaseAttention(); return }
        guard let loc = CGEvent(source: nil)?.location else { return }
        let (top, bottom) = pillBandCG()
        let y = loc.y
        let xr = cursorXFromRight()
        // summon / hide — same hysteresis as the monitor (and wider on y:
        // dismiss only past ±HIDE_BAND, so band-edge jitter can't flap it)
        if xr <= REVEAL_WIDTH, y >= top - 26, y <= bottom + 26 {
            applyVisibility(true)
        } else if xr > PILL_WIDTH + HIDE_MARGIN || y > bottom + HIDE_BAND || y < top - HIDE_BAND {
            applyVisibility(false)
        }
        // attention — cursor on the glass owns the moment
        if stripVisible, xr <= PILL_WIDTH, y >= top, y <= bottom {
            takeAttention()
            tab.reassertCursor()           // belt + suspenders during the activation handoff
        } else {
            releaseAttention()
        }
    }

    // low power mode toggles repaint the battery instantly
    NotificationCenter.default.addObserver(
        forName: NSNotification.Name("NSProcessInfoPowerStateDidChangeNotification"), object: nil, queue: .main
    ) { _ in
        strip.contentView?.needsDisplay = true
    }

    app.run() // full app run loop — runs the monitors and notifications
    exit(0)
}

// MARK: - subcommands (thin launchctl wrappers — install/uninstall lives in install.sh)

@discardableResult
func sh(_ command: String) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", command]
    p.standardOutput = Pipe()
    p.standardError = Pipe()
    do { try p.run() } catch { return 1 }
    p.waitUntilExit()
    return p.terminationStatus
}

let label = "dev.cobalt.smalt"
let name = "smalt"
let gui = "gui/\(getuid())"
let errLog = "/tmp/smalt.err"
let plistPath = FileManager.default.homeDirectoryForCurrentUser.path
    + "/Library/LaunchAgents/\(label).plist"

func agentLoaded() -> Bool {
    sh("launchctl print \(gui)/\(label) >/dev/null 2>&1") == 0
}

// the daemon registers as "smalt" — but so does this CLI invocation,
// so exclude our own pid from the check
func daemonRunning() -> Bool {
    sh("pgrep -x \(name) | grep -vw \(getpid()) >/dev/null 2>&1") == 0
}

func cmdOn() {
    guard FileManager.default.fileExists(atPath: plistPath) else {
        print("not installed — run install.sh first"); exit(1)
    }
    if !agentLoaded() {
        sh("launchctl bootstrap \(gui) '\(plistPath)'")
    }
    sh("launchctl kickstart -k \(gui)/\(label)")
    print(daemonRunning()
        ? "smalt is up — the glass is on"
        : "starting… if it won't stay up, check \(errLog)")
}

func cmdOff() {
    guard agentLoaded() || daemonRunning() else {
        print("already off"); exit(0)
    }
    sh("launchctl bootout \(gui)/\(label)")
    sh("pkill -x \(name) 2>/dev/null")
    print("smalt is down (starts again at next login — plist kept)")
}

func cmdStatus() {
    let installed = FileManager.default.fileExists(atPath: plistPath)
    let loaded = agentLoaded()
    let running = daemonRunning()

    print("agent:    \(installed ? "installed (\(plistPath))" : "not installed — run install.sh")")
    print("launchd:  \(loaded ? "loaded" : "not loaded")")
    print("process:  \(running ? "running" : "not running")")

    if running {
        print("pill:     up — cream glass, mid-right edge (summon zone: \(Int(REVEAL_WIDTH))px)")
    } else if loaded {
        print("pill:     down — launchd is retrying; check \(errLog)")
        if let tail = try? String(contentsOfFile: errLog, encoding: .utf8).suffix(200) {
            print("log:      \(tail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    } else {
        print("pill:     off (starts again at next login)")
    }
}

// MARK: - entry

switch CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "run" {
case "run":              runDaemon()
case "on", "enable":     cmdOn()
case "off", "disable":   cmdOff()
case "status":           cmdStatus()
default:
    print("""
    usage: smalt [command]

      (none)          daemon mode — the pill (what launchd runs)
      on, enable      start the daemon
      off, disable    stop the daemon (starts again at next login)
      status          installed / loaded / running

    install & uninstall: ./install.sh in the repo folder
    """)
    exit(1)
}
