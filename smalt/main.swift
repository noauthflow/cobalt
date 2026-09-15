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
//   the pill shows six widgets on one grid, each in its own fixed slot:
//   battery · calendar · hour · minute · headphones · bluetooth · microphone
//   (the span-5 brightness slider rides below the stack)
//   mission control    off the stage — it's not part of the expose grid
//
// zero permissions: the reveal is a global mouse monitor, not an event
// tap. nothing is intercepted, nothing is rewritten, nothing is polled.

// MARK: - the design system
//
// palette + grid + type — the ONLY place visual constants exist. every
// SVG icons and type are optically centered
// inside one uniform CELL × CELL slot; the pill is exactly its grid, nothing
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
        case battery27, calendar, hour, minute, slider, headphones, bluetooth, microphone
    }
    struct SlotDef {
        let kind: Kind
        let span: Int
        init(_ kind: Kind, span: Int = 1) { self.kind = kind; self.span = span }
    }
    static let slots: [SlotDef] = [
        .init(.battery27),
        .init(.calendar),
        .init(.hour),
        .init(.minute),
        .init(.headphones),
        .init(.bluetooth),
        .init(.microphone),
        .init(.slider, span: 5),
    ]
    static var slotCount: Int { slots.count }

    // SVG icons use one shared 24 grid and one uniform scale. AppKit loads
    // the assets; SVGIcon caches them and draws them in these slots.
    static let iconSize: CGFloat = 30       // grid 24 → 30pt, all icons

    // grid debug: stroke every slot + the padding bounds so the layout is
    // visible. red = widget slots, blue = where the padding ends. flip to
    // false when done squinting at it.
    static let debugGrid = false

    // type — SF Pro tabular digits at a weight whose stems sit at the icon
    // stroke weight (medium at 15pt ≈ 1.2pt vs 1.25pt strokes)
    static let typeSize: CGFloat = 19     // clock digits
    static let dateSize: CGFloat = 12     // sized for the calendar's number area

    // slider — material design 3's shape language in smalt's skin: 4dp
    // track, round handle. vertical, one CELL tall... spans 5 below the
    // time. v0 drew a fixed value; the live hardware wiring is further down.
    static let sliderTrack: CGFloat = 24   // = sliderHandle: knob and track are the same width
    static let sliderHandle: CGFloat = 24
    static let sliderFill = NSColor(srgbRed: 0x75/255.0, green: 0x56/255.0, blue: 0x4F/255.0, alpha: 1)  // #75564F value run
    static let knob      = NSColor(srgbRed: 0x3A/255.0, green: 0x2D/255.0, blue: 0x27/255.0, alpha: 1)  // #3A2D27 knob bg
    static var sliderValue: CGFloat = 0.5    // the hardware's current level (sampled)
    static var sliderDisplay: CGFloat = 0.5  // what the handle draws — springs toward sliderValue
    static var sliderFace: CGFloat = 0       // knob face crossfade: 0 = Night-Day, 1 = %

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
let SUMMON_BAND: CGFloat = 26    // vertical summon band: cursor within this of the pill's
                                 // top/bottom edge (level with the pill, with slack)
let HIDE_MARGIN: CGFloat = 6     // cursor must drop this far left of the pill before it springs away
let HIDE_BAND: CGFloat = 40      // vertical hysteresis: summon at ±26px, dismiss only past ±40px —
                                 // without it, 1px of hand jitter at the band edge flips the
                                 // state every poll and the pill flaps itself to death
// spring constants: ω ≈ 23.7 rad/s, ζ ≈ 0.68 — a crisp pop with ~5% overshoot
let SPRING_K: CGFloat = 560
let SPRING_C: CGFloat = 32
// entrance head start, pt/s: a spring launched from rest spends its first
// ~50ms covering ~18px — all of it in the off-screen slack — so the visible
// glass TRICKLES out of the edge before the spring reaches speed. the kick
// skips the dead zone: the glass crosses the screen edge already moving.
// (sign handled at the call site; ~55% of this spring's natural peak
// velocity of ~550pt/s at full travel — enough to read, not enough to
// shrink the overshoot to nothing.)
let SUMMON_KICK: CGFloat = 300

// a 120fps chase timer: drives one CGFloat toward a target with a
// proportional step, self-stops once it has arrived, and keeps running in
// .common so it survives modal tracking (slider drags). it holds no state
// of its own — the value lives where Theme says it must (single source of
// truth), the timer only moves it. one instance per animated value.
final class ChaseTimer {
    private var timer: Timer?
    private let get: () -> CGFloat
    private let set: (CGFloat) -> Void
    private let target: () -> CGFloat
    private let rate: CGFloat      // fraction of the remaining distance per tick
    private let epsilon: CGFloat   // close enough = done

    init(get: @escaping () -> CGFloat, set: @escaping (CGFloat) -> Void,
         target: @escaping () -> CGFloat, rate: CGFloat, epsilon: CGFloat) {
        self.get = get; self.set = set
        self.target = target; self.rate = rate; self.epsilon = epsilon
    }

    func start() {
        guard timer == nil else { return }   // already chasing — target() moved under us
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let d = self.target() - self.get()
            if abs(d) < self.epsilon {
                self.timer?.invalidate(); self.timer = nil
                self.set(self.target())
            } else {
                self.set(self.get() + d * self.rate)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // finish instantly — the cursor takes over from the spring
    func stop() {
        timer?.invalidate(); timer = nil
        set(target())
    }
}

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
        // one arrow rect for the whole window — the baseline. the slider's
        // hand is set IMPERATIVELY by position (see overSlider), never by
        // rect: a hand rect here is event-driven and fights the spring
        // mid-slide (the flicker), and rects can't see a cursor the glass
        // slid under without a mouse event.
        addCursorRect(bounds, cursor: .arrow)
    }

    // where is the cursor, right now, in view coords — a live query, not
    // event history. NSEvent.mouseLocation reads the window server's current
    // position, so it answers correctly even when the last mouse event is
    // stale (the glass just slid under a stationary cursor).
    private var cursorPoint: NSPoint? {
        guard let win = window else { return nil }
        let p = win.convertFromScreen(NSRect(origin: NSEvent.mouseLocation, size: .zero)).origin
        return convert(p, from: nil)
    }

    // the pointing-hand decision, position-driven: over the slider slot of a
    // PARKED glass. no tracking-area dependency — hoverSlot only updates on
    // mouse events, and the first hover can happen with zero of those.
    private func overSlider() -> Bool {
        guard glassDocked, let p = cursorPoint else { return false }
        return slotIndex(at: p).map { Theme.slots[$0].kind == .slider } ?? false
    }

    override func cursorUpdate(with event: NSEvent) {
        // apps beneath push their cursors on redraw; re-win by position
        if overSlider() {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    // re-win the cursor on demand: apps beneath push their cursors when they
    // REDRAW — no mouse event fires, so nothing above catches it. called from
    // the 30Hz poll and the mouse monitor, so a stationary cursor over the
    // slider gets the hand within one tick of the glass parking.
    func reassertCursor() {
        window?.invalidateCursorRects(for: self)   // window server re-reads resetCursorRects
        if overSlider() {
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

    // spring-render: the two display values chase their targets at 120fps so
    // a sampled hardware change arrives as one smooth glide (the bezel's own
    // ~250ms feel), never a jump. each timer runs only while it has distance
    // to cover; drags bypass the value spring — the cursor is the only spring
    // that matters there.
    private var faceTarget: CGFloat = 0
    private lazy var valueSpring = ChaseTimer(
        get: { Theme.sliderDisplay },
        set: { [weak self] v in Theme.sliderDisplay = v; self?.needsDisplay = true },
        target: { Theme.sliderValue },
        rate: 0.22, epsilon: 0.0004)
    private lazy var faceSpring = ChaseTimer(
        get: { Theme.sliderFace },
        set: { [weak self] v in Theme.sliderFace = v; self?.needsDisplay = true },
        target: { [weak self] in self?.faceTarget ?? 0 },
        rate: 0.25, epsilon: 0.002)

    // crossfade the knob face (Night-Day ⇄ %) — the face spring runs only while the
    // blend has distance to cover
    private func setFaceTarget(_ target: CGFloat) {
        faceTarget = target
        faceSpring.start()
    }

    func beginValueSpring() {
        valueSpring.start()   // no-op if already within epsilon of the hardware
    }

    private func updateSliderValue(at p: NSPoint) {
        guard let i = dragSlot else { return }
        let r = Theme.slot(i, in: bounds)
        // flipped coords: slot top (minY) = 1.0, bottom = 0.0
        let v = min(1, max(0, (r.maxY - p.y) / r.height))
        Theme.sliderValue = v
        KeyboardBrightness.set(Float(v))   // the F5/F6 keys' own call path
        valueSpring.stop()                 // the cursor is the only spring that matters here
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = slotIndex(at: p) {
            switch Theme.slots[i].kind {
            case .slider:
                dragSlot = i
                setFaceTarget(1)
            case .battery27:
                batteryPctOverride = Int.random(in: 0...100)   // test dial: next random iteration
            default:
                break
            }
        }
        updateSliderValue(at: p)
    }

    override func mouseDragged(with event: NSEvent) {
        updateSliderValue(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        dragSlot = nil
        setFaceTarget(0)   // back to the Night-Day icon on release — no debounce
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
            case .battery27: drawBattery(in: r)
            case .calendar: drawCalendar(in: r)
            case .headphones: drawHeadphones(in: r)
            case .bluetooth: drawBluetooth(in: r)
            case .microphone: drawMicrophone(in: r)
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
//   · SVG icons draw on their shared 24×24 grid, centered in each slot
//   · text draws centered by INK (glyph bounds), not line height —
//     line-height centering leaves digits riding high, which is exactly
//     the "percentage isn't in the middle" bug

// MARK: - SVG icons
// AppKit loads the five SVG assets directly. The same loader, tint, cache,
// and 24-unit layout apply to every SVG widget.
enum SVGIcon {
    enum Name: String {
        case battery27 = "battery-27"
        case bolt = "bolt"
        case calendar = "calendar-today"
        case nightDay = "Night-Day"
        case headphones, bluetooth, mic
    }

    private static let assetDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/smalt")
    private static var cache: [String: NSImage] = [:]

    private static func hex(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return nil }
        return String(format: "#%02X%02X%02X",
                      Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()),
                      Int((rgb.blueComponent * 255).rounded()))
    }

    private static func image(_ name: Name, color: NSColor) -> NSImage? {
        guard let tint = hex(color) else { return nil }
        let key = name.rawValue + tint
        if let cached = cache[key] { return cached }
        let url = assetDirectory.appendingPathComponent(name.rawValue + ".svg")
        guard let xml = try? String(contentsOf: url, encoding: .utf8),
              let data = xml.replacingOccurrences(of: "#e3e3e3", with: tint)
                  .data(using: .utf8),
              let image = NSImage(data: data) else { return nil }
        cache[key] = image
        return image
    }

    static func gridRect(_ r: CGRect, in slot: NSRect) -> NSRect {
        let s = Theme.iconSize / 24
        return NSRect(x: slot.midX + (r.minX - 12) * s,
                      y: slot.midY + (r.minY - 12) * s,
                      width: r.width * s, height: r.height * s)
    }

    static func draw(_ name: Name, color: NSColor, in slot: NSRect) {
        let rect = gridRect(CGRect(x: 0, y: 0, width: 24, height: 24), in: slot)
        draw(name, color: color, inRect: rect)
    }

    static func draw(_ name: Name, color: NSColor, inRect rect: NSRect,
                     fraction: CGFloat = 1) {
        image(name, color: color)?.draw(in: rect, from: .zero,
                                        operation: .sourceOver, fraction: fraction,
                                        respectFlipped: true, hints: nil)
    }
}

// text centered on its ink — CoreText glyph bounds, not the line box
func drawText(_ s: String, font: NSFont, color: NSColor, in r: NSRect,
              kern: CGFloat = 0, hScale: CGFloat = 1) {
    let line = CTLineCreateWithAttributedString(NSAttributedString(
        string: s, attributes: [.font: font, .foregroundColor: color, .kern: kern]))
    let inkBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    ctx.translateBy(x: r.midX, y: r.midY)   // to the slot center…
    ctx.scaleBy(x: 1, y: -1)                // …unflip for CoreText (y-up)
    ctx.scaleBy(x: hScale, y: 1)            // horizontal squeeze, ink stays centered
    ctx.textMatrix = .identity              // reset: CTLineDraw leaves a mutated
                                            // text matrix behind, which would
                                            // squish every widget drawn after us
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
// The SVG widgets use the shared AppKit loader above. Widget state comes
// from IOKit power sources, the clock, and ProcessInfo low-power state.

// IOKit power sources — the same thing the native battery item reads.
// IOKit is not free, and every widget repaints at up to 120fps mid-spring —
// cache the reading (nil included, desktop macs have no power source). 5s of
// staleness is finer than the 10s widget tick that drives most repaints.
var batteryCache: (result: (pct: Int, charging: Bool)?, stamp: CFTimeInterval)?

func batteryLevel() -> (pct: Int, charging: Bool)? {
    let now = CACurrentMediaTime()
    if let c = batteryCache, now - c.stamp < 5 { return c.result }
    let result = readBatteryLevel()
    batteryCache = (result, now)   // cache hits and misses alike
    return result
}

func readBatteryLevel() -> (pct: Int, charging: Bool)? {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for ps in list {
        guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
              let cap = d[kIOPSCurrentCapacityKey] as? Int,
              let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
        // charging = on AC power, NOT kIOPSIsChargingKey — macOS pauses
        // charge current (health management, full battery) while still
        // attached, and IsCharging drops to false at exactly the moment the
        // user would say "I'm charging". the power source state is the truth.
        let charging = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        return (Int((Double(cap) / Double(max) * 100).rounded()), charging)
    }
    return nil
}

// the battery — iOS 27 style: a faint shell (Vector.svg, 27×14 grid:
// capsule body + nub) with the charge fill drawn ON TOP of it as a solid
// capsule. the shell shows through the empty side at every charge level,
// and the fill always lays a floor behind whatever sits in the body later.
enum Battery {
    // the svg's own grid: body 0..24.7 wide, nub out to 27
    static let grid = CGSize(width: 27, height: 14)
    static let bodyWidth: CGFloat = 24.6981

    // the shell body's EXACT path, traced from Vector.svg — a squircle, not
    // a circular capsule. the fill clips to this so the fill's corners sit
    // exactly on the shell's corners instead of rounding past them.
    private static let bodyPath: NSBezierPath = {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 0.665982, y: 1.77772))
        p.curve(to: NSPoint(x: 0.0, y: 7.0),
                controlPoint1: NSPoint(x: 0.0, y: 2.78661),
                controlPoint2: NSPoint(x: 0.0, y: 4.19108))
        p.curve(to: NSPoint(x: 0.665982, y: 12.2223),
                controlPoint1: NSPoint(x: 0.0, y: 9.80892),
                controlPoint2: NSPoint(x: 0.0, y: 11.2134))
        p.curve(to: NSPoint(x: 1.75625, y: 13.3259),
                controlPoint1: NSPoint(x: 0.954292, y: 12.659),
                controlPoint2: NSPoint(x: 1.32477, y: 13.034))
        p.curve(to: NSPoint(x: 6.91548, y: 14.0),
                controlPoint1: NSPoint(x: 2.75297, y: 14.0),
                controlPoint2: NSPoint(x: 4.14047, y: 14.0))
        p.line(to: NSPoint(x: 17.7827, y: 14.0))
        p.curve(to: NSPoint(x: 22.9419, y: 13.3259),
                controlPoint1: NSPoint(x: 20.5577, y: 14.0),
                controlPoint2: NSPoint(x: 21.9452, y: 14.0))
        p.curve(to: NSPoint(x: 24.0322, y: 12.2223),
                controlPoint1: NSPoint(x: 23.3734, y: 13.034),
                controlPoint2: NSPoint(x: 23.7438, y: 12.659))
        p.curve(to: NSPoint(x: 24.6981, y: 7.0),
                controlPoint1: NSPoint(x: 24.6981, y: 11.2134),
                controlPoint2: NSPoint(x: 24.6981, y: 9.80892))
        p.curve(to: NSPoint(x: 24.0322, y: 1.77772),
                controlPoint1: NSPoint(x: 24.6981, y: 4.19108),
                controlPoint2: NSPoint(x: 24.6981, y: 2.78661))
        p.curve(to: NSPoint(x: 22.9419, y: 0.674122),
                controlPoint1: NSPoint(x: 23.7438, y: 1.34096),
                controlPoint2: NSPoint(x: 23.3734, y: 0.965956))
        p.curve(to: NSPoint(x: 17.7827, y: 0.0),
                controlPoint1: NSPoint(x: 21.9452, y: 0.0),
                controlPoint2: NSPoint(x: 20.5577, y: 0.0))
        p.line(to: NSPoint(x: 6.91548, y: 0.0))
        p.curve(to: NSPoint(x: 1.75625, y: 0.674122),
                controlPoint1: NSPoint(x: 4.14047, y: 0.0),
                controlPoint2: NSPoint(x: 2.75297, y: 0.0))
        p.curve(to: NSPoint(x: 0.665982, y: 1.77772),
                controlPoint1: NSPoint(x: 1.32477, y: 0.965956),
                controlPoint2: NSPoint(x: 0.954292, y: 1.34096))
        p.close()
        return p
    }()

    // the nub — the svg's second path, the tip outside the body. part of
    // the shell (#CDCDCD) at every level; joins the fill only at 100% —
    // full means full, tip included
    private static let nubPath: NSBezierPath = {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 27, y: 6.75))
        p.curve(to: NSPoint(x: 25.6861, y: 8.75),
                controlPoint1: NSPoint(x: 27, y: 7.62313),
                controlPoint2: NSPoint(x: 26.4822, y: 8.41122))
        p.line(to: NSPoint(x: 25.6861, y: 4.75))
        p.curve(to: NSPoint(x: 27, y: 6.75),
                controlPoint1: NSPoint(x: 26.4822, y: 5.08878),
                controlPoint2: NSPoint(x: 27, y: 5.87687))
        p.close()
        return p
    }()

    // the figma palette — fixed in ALL states: the shell never changes,
    // the digits and bolt are always white; only the fill answers charge
    static let shellColor = NSColor(srgbRed: 0xCD/255.0, green: 0xCD/255.0, blue: 0xCD/255.0, alpha: 1)   // #CDCDCD
    static let textColor = NSColor.white                                                                 // #FFFFFF
    static let fillNormal = NSColor(srgbRed: 0x12/255.0, green: 0x12/255.0, blue: 0x12/255.0, alpha: 1)  // #121212
    static let fillCharging = NSColor(srgbRed: 0x34/255.0, green: 0xC7/255.0, blue: 0x59/255.0, alpha: 1)       // #34C759
    static let fillLowPower = NSColor(srgbRed: 1, green: 0xCC/255.0, blue: 0x0A/255.0, alpha: 1)         // #FFCC0A
    static let fillLow = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)                                // #FF0000

    static func draw(pct: Int, charging: Bool, in slot: NSRect) {
        let f = CGFloat(max(0, min(100, pct))) / 100
        let fillColor = charging ? (pct < 20 ? fillLow : fillCharging)
            : pct < 20 ? fillLow
            : ProcessInfo.processInfo.isLowPowerModeEnabled ? fillLowPower : fillNormal

        // fit the svg's grid to the slot width, vertically centered — the
        // grid decides, nothing hand-placed
        let s = slot.width / grid.width
        let frame = NSRect(x: slot.midX - grid.width * s / 2,
                           y: slot.midY - grid.height * s / 2,
                           width: grid.width * s, height: grid.height * s)

        // the shell: #CDCDCD in every state, low power included
        SVGIcon.draw(.battery27, color: shellColor, inRect: frame)

        // the charge: the shell's own body path as the clip, filled from the
        // left edge → f — corners exactly on the shell's corners
        if f > 0 {
            let context = NSGraphicsContext.current!.cgContext
            context.saveGState()
            context.translateBy(x: frame.minX, y: frame.minY)
            context.scaleBy(x: s, y: s)
            bodyPath.addClip()
            fillColor.setFill()
            NSRect(x: 0, y: 0, width: bodyWidth * f, height: grid.height).fill()
            context.restoreGState()
            // at 100% the nub joins the fill — drawn OUTSIDE the body clip,
            // which would otherwise erase it (the nub lives past the body)
            if pct >= 100 {
                context.saveGState()
                context.translateBy(x: frame.minX, y: frame.minY)
                context.scaleBy(x: s, y: s)
                fillColor.setFill()
                nubPath.fill()
                context.restoreGState()
            }
        }

        // the percentage: SF Pro Bold 11, −0.5 tracking, white in all
        // states. while charging below 100, the bolt stands beside the
        // digits and the run centers as ONE collective — no shrinking, the
        // digits draw at their natural size. at 100% the bolt is dropped:
        // on a full battery macOS still reports AC power, but nothing is
        // charging.
        let text = "\(pct)"
        let font = NSFont.systemFont(ofSize: 11, weight: .bold)
        let boltH: CGFloat = 11
        let boltW = boltH * 6.07094 / 8.26108   // the bolt glyph's tight bounds
        let gap: CGFloat = 0.5
        let showBolt = charging && pct < 100
        let boltRun: CGFloat = showBolt ? gap + boltW : 0

        func inkWidth() -> CGFloat {
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: text, attributes: [.font: font, .kern: -0.5]))
            return CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).width
        }
        let textW = inkWidth()

        // centered on the BODY (not the nub), placed by INK width so side
        // bearings can't shove the bolt right of where the math put it
        let bodyCenter = frame.minX + bodyWidth * s / 2
        let x0 = bodyCenter - (textW + boltRun) / 2
        drawText(text, font: font, color: textColor, in: NSRect(
            x: x0, y: frame.minY, width: textW, height: frame.height),
            kern: -0.5)
        if showBolt {
            SVGIcon.draw(.bolt, color: textColor, inRect: NSRect(
                x: x0 + textW + gap, y: frame.midY - boltH / 2,
                width: boltW, height: boltH))
        }
    }
}

// demo override: click the battery slot to cycle the displayed % through
// random values (a test dial, not a state) — charging and low-power still
// answer to the hardware, so fills/bolt/reactivity stay honest
var batteryPctOverride: Int? = nil

func drawBattery(in slot: NSRect) {
    guard let hw = batteryLevel() else { return }
    Battery.draw(pct: batteryPctOverride ?? hw.pct, charging: hw.charging, in: slot)
}

// The calendar SVG leaves a 14×10-unit body for the day number.
func drawCalendar(in slot: NSRect) {
    SVGIcon.draw(.calendar, color: Theme.ink, in: slot)
    let day = Calendar.current.component(.day, from: Date())
    let body = SVGIcon.gridRect(CGRect(x: 5, y: 10, width: 14, height: 10), in: slot)
    // Bold compensates for the smaller date size so its strokes sit beside
    // the clock's 19pt medium digits.
    drawText("\(day)", font: .tabular(Theme.dateSize, .bold),
             color: Theme.ink, in: body)
}

// md3 audio glyphs, verbatim — headphones (out), bluetooth, mic (in)
func drawHeadphones(in slot: NSRect) {
    SVGIcon.draw(.headphones, color: Theme.ink, in: slot)
}

func drawBluetooth(in slot: NSRect) {
    SVGIcon.draw(.bluetooth, color: Theme.ink, in: slot)
}

func drawMicrophone(in slot: NSRect) {
    SVGIcon.draw(.mic, color: Theme.ink, in: slot)
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
    let stadium = NSBezierPath(roundedRect: trackRect, xRadius: Theme.sliderTrack / 2,
                               yRadius: Theme.sliderTrack / 2)
    Theme.sliderFill.withAlphaComponent(0.3).setFill()
    stadium.fill()
    // active run: FLAT-top fill from the knob's center line down. a rounded
    // top here bulges up at the center while the knob's circle bulges down —
    // two opposing arcs with air at the sides (the gap). flat meets the knob
    // exactly; 1px of overlap kills the antialiasing seam. clipped to the
    // track so the stadium silhouette survives.
    if let ctx = NSGraphicsContext.current?.cgContext {
        ctx.saveGState()
        stadium.addClip()
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

    // the % — tabular semibold, sized so "100" fits inside the knob.
    let pct = Int((Theme.sliderValue * 100).rounded())

    if face > 0 {
        drawText("\(pct)", font: .tabular(KnobFace.base * face, .semibold),
                 color: Theme.glass.withAlphaComponent(edgeAlpha(face)), in: handle)
    }

    if face < 1 {
        let f = 1 - face
        let size = (knobSize - 6) * f
        let iconRect = NSRect(x: handle.midX - size / 2,
                              y: handle.midY - size / 2,
                              width: size, height: size)
        SVGIcon.draw(.nightDay, color: Theme.glass, inRect: iconRect,
                     fraction: edgeAlpha(f))
    }
}

// The percentage face shrinks just enough for "100" to fit inside the knob.
enum KnobFace {
    static let base: CGFloat = {
        var b: CGFloat = 12
        let wide = ("100" as NSString).size(withAttributes: [.font: NSFont.tabular(b, .semibold)]).width
        return wide > Theme.sliderHandle - 6 ? b * (Theme.sliderHandle - 6) / wide : b
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

    func chase(_ targetX: CGFloat, initialVelocity: CGFloat = 0) {
        target = targetX
        guard !running else { return }             // already chasing — just retargeted
        x = tab.frame.origin.x
        v = initialVelocity
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
        setGlassX(x.rounded())                     // whole pixels: no subpixel shimmer on the glass
        if abs(x - target) < 0.25, abs(v) < 2 {
            setGlassX(target)
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
        setGlassX(glassX(docked: desired))
        if !desired { flushPendingRelease() }   // parked instantly — release now
        return
    }
    spring.chase(glassX(docked: desired),
                 initialVelocity: desired ? -SUMMON_KICK : 0)   // entrance kicks toward the dock; exit starts from rest
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

// the cursor, in the two spaces the reveal logic cares about: distance from
// the main screen's right edge, and global CG top-left y. nil when the event
// source can't tell us (rare; callers treat it as "no cursor").
func cursorCG() -> (xr: CGFloat, y: CGFloat)? {
    guard let loc = CGEvent(source: nil)?.location, let screen = mainScreen() else { return nil }
    return (screen.frame.maxX - loc.x, loc.y)
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

// the shared hover rule — ONE source of truth for summon / hide, used by the
// global monitor, the 30Hz poll and the workspace-notification path:
//   true   cursor is in the summon zone (right edge, level with the pill)
//   false  cursor is past the hide margin (x) or the hysteresis band (y)
//   nil    inside the hysteresis band — keep whatever state we're in
// (a hovered glass stays on stage even if a notification lands here — app
// switch, quit, space change — the summon zone only ever decides the
// hidden → visible transition, never "you were hovering, bye")
func hoverVisibility(xr: CGFloat, y: CGFloat, top: CGFloat, bottom: CGFloat) -> Bool? {
    if xr <= REVEAL_WIDTH, y >= top - SUMMON_BAND, y <= bottom + SUMMON_BAND { return true }
    if xr > PILL_WIDTH + HIDE_MARGIN || y > bottom + HIDE_BAND || y < top - HIDE_BAND { return false }
    return nil
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
    // the key-drop dance, in full: orderOut drops key (the bg app regains it
    // and its cursor rects — the automatic un-re-click), orderFrontRegardless
    // forces the window server to settle the handback. skipping the re-front
    // leaves key dangling on the resigned panel: no refocus, wrong cursors.
    strip.orderOut(nil)
    strip.orderFrontRegardless()
    // then leave the stage — the parked glass sits in off-screen slack, and
    // an ordered-in window with off-screen content is exactly what the
    // lock-screen zoom composites un-clipped. the window is not key here,
    // so this last orderOut is inert to focus: off it goes.
    strip.orderOut(nil)
    dbg("attention released: key dropped, window off stage")
}

// MARK: - fullscreen + mission control detection
// same trick as cobalt-60: a layer-0 window matching a display's bounds
// means that display is owned by a fullscreen app. mission control fakes
// it (every space's windows are "onscreen" up there) — the dock's
// full-screen backdrop is the signal that MC is active.

func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
    screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
}

// shared CGWindowList scan: is there an on-screen window owned by `owner`
// that covers ~all of the main display (and passes the layer predicate)?
// the lock screen IS such a loginwindow window; mission control raises a
// Dock-owned backdrop of the same shape (layer > 0, to skip its layer-0
// wallpaper).
func fullscreenWindow(owner: String, layer: ((Int) -> Bool)? = nil) -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
    let main = CGDisplayBounds(CGMainDisplayID())
    return list.contains { d in
        guard d[kCGWindowOwnerName as String] as? String == owner,
              let b = d[kCGWindowBounds as String] as? [String: NSNumber],
              let w = b["Width"]?.doubleValue,
              let h = b["Height"]?.doubleValue else { return false }
        if let layer, !layer(d[kCGWindowLayer as String] as? Int ?? 0) { return false }
        return w >= main.width * 0.9 && h >= main.height * 0.9
    }
}

func missionControlActive() -> Bool {
    fullscreenWindow(owner: "Dock", layer: { $0 > 0 })
}

// MARK: - evaluation

var mcActive = false              // cached mission-control state (re-checked on space/app changes)

func updateStrip() {
    guard !sessionLocked else { return }           // locked: notifications don't summon
    guard tab.dragSlot == nil else { return }      // mid-drag: collapse only on release
    mcActive = missionControlActive()
    guard !mcActive else { applyVisibility(false); return }   // mission control: off the stage
    guard let c = cursorCG() else { return }
    let (top, bottom) = pillBandCG()
    // the same hover rule the monitor and poll use — see hoverVisibility
    switch hoverVisibility(xr: c.xr, y: c.y, top: top, bottom: bottom) {
    case true:  applyVisibility(true)
    case false: applyVisibility(false)
    case nil:   break
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
        tab.dragSlot = nil                  // a lock mid-drag kills the drag —
                                            // otherwise dragSlot pins the glass open forever
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
    fullscreenWindow(owner: "loginwindow")
}

// MARK: - the pill (window)

// MARK: - the pill (window + glass subview)
//
// the window spans docked-glass + slack on both sides; the glass tab is a
// SUBVIEW whose x the spring drives between docked (flush with the screen
// edge) and hidden (fully off-screen). the window is only ever in one of
// two places — docked (summon: instant, so the cursor lands on it at once)
// or off-screen (hidden, after the exit spring settles).

let tab = StripView(frame: NSRect(origin: .zero, size: NSSize(width: PILL_WIDTH, height: PILL_HEIGHT)))

// where the glass sits inside the window: docked (flush at the screen edge
// with TAB_MARGIN of overshoot slack to its left) vs hidden (past the edge)
func glassX(docked: Bool) -> CGFloat { docked ? TAB_MARGIN : TAB_MARGIN + TAB_TRAVEL }

// move the glass: origin only. the tab's size never changes, and setting it
// anyway invalidated tracking areas (a full rebuild) on every spring tick.
func setGlassX(_ x: CGFloat) {
    tab.setFrameOrigin(NSPoint(x: x, y: tab.frame.origin.y))
    tab.needsDisplay = true
}

// the glass is fully docked = the reveal spring has parked. until then the
// cursor is arrow-only everywhere: the panel takes KEY while the cursor is
// over the glass — mid-slide — and a hand cursor flipping in and out while
// the glass moves under a stationary cursor reads as flicker.
var glassDocked: Bool {
    tab.frame.origin.x <= glassX(docked: true) + 0.5
}

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
    setGlassX(glassX(docked: false))   // glass parked off-screen at launch
    applyVisibility(false, animate: false)   // parked = click-through at the edge → window OUT

    // the summon. a global mouse monitor — not an event tap — so there is
    // nothing to intercept and nothing to grant. the cursor entering the
    // right edge, level with the pill, springs it out; dropping left of the
    // pill (or past its band) springs it away. hysteresis between the two
    // lines means edge jitter can't flicker it — and the spring retargets,
    // so even fast in-out is a smooth reversal, never a glitch.
    NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .otherMouseDragged]) { _ in
        guard !sessionLocked else { return }       // lock screen: the edge is nobody's
        guard tab.dragSlot == nil else { return }  // mid-drag: the cursor is the knob —
                                                   // nobody summons or collapses mid-drag
        // cmd held: the edge is yours — no window, no glass, no cursor take-over
        setCmdOverride(cmdHeld())
        if cmdOverride { return }
        let (top, bottom) = pillBandCG()
        guard let c = cursorCG() else { return }
        // cursor defense, active side: while the cursor is over the glass,
        // smalt owns the cursor — apps underneath re-assert their I-beam/
        // resize cursors on redraw, so re-win it on every move. arrow
        // regardless of modifier flags — cmd never changes anything here.
        // one NSCursor.set, no tap, no permissions. (the old check, xr <= 0,
        // meant "cursor past the screen edge" — it almost never fired, which
        // is why the I-beam kept leaking through.)
        if stripVisible, c.xr <= PILL_WIDTH, c.y >= top, c.y <= bottom {
            tab.reassertCursor()
        }
        switch hoverVisibility(xr: c.xr, y: c.y, top: top, bottom: bottom) {
        case true:  applyVisibility(true)
        case false: applyVisibility(false)
        case nil:   break
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
    // (and cheap: the window only repaints on demand). hidden glass doesn't
    // repaint at all — the spring marks needsDisplay every frame on the way
    // out anyway, so the reveal is never stale.
    Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
        guard stripVisible else { return }
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
        // mid-drag: the cursor IS the knob — the glass stays on stage wherever
        // the cursor goes; the hide decision (and cmd override, which would
        // murder the drag mid-grip) waits for mouseUp. attention still runs,
        // so sliding back over the glass re-keys; releaseAttention defers the
        // key-drop to parking (pendingRelease), never mid-drag.
        let dragging = tab.dragSlot != nil
        if !dragging {
            setCmdOverride(cmdHeld())
            if cmdOverride { releaseAttention(); return }
            if mcActive { applyVisibility(false); releaseAttention(); return }
        }
        guard let c = cursorCG() else { return }
        let (top, bottom) = pillBandCG()
        if !dragging {
            // summon / hide — the shared hover rule (hysteresis: dismiss only past
            // ±HIDE_BAND, so band-edge jitter can't flap it)
            switch hoverVisibility(xr: c.xr, y: c.y, top: top, bottom: bottom) {
            case true:  applyVisibility(true)
            case false: applyVisibility(false)
            case nil:   break
            }
        }
        // attention — cursor on the glass owns the moment
        if stripVisible, c.xr <= PILL_WIDTH, c.y >= top, c.y <= bottom {
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
