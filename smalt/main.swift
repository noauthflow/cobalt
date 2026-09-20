import AppKit
import QuartzCore
import ApplicationServices
import CoreText
import CoreWLAN
import IOKit
import IOKit.ps
import IOBluetooth
import Carbon

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
//   the pill shows seven widgets on one grid, each in its own fixed slot:
//   hour · minute · battery · audio · bluetooth · microphone · wifi
//   (the span-5 slider rides below the stack — Night Shift strength —
//   power below that)
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

// LEGACY: the trio — the capsule with the wifi · bluetooth · audio · mic
// runes — is retired. the code stays (drawing, icons, the anchor grammar
// it fed), parked behind this flag: false = the slot vanishes from the
// grid and the pill closes up after the slider. flip to true to resurrect.
let LEGACY_TRIO = false

enum Theme {
    // palette
    static let glass   = NSColor(srgbRed: 0xFA/255.0, green: 0xF6/255.0, blue: 0xF3/255.0, alpha: 1)  // #FAF6F3 pill glass
    static let ink     = NSColor(srgbRed: 0x99/255.0, green: 0x94/255.0, blue: 0x7F/255.0, alpha: 1)  // #99947F strokes + labels
    static let inkDeep = NSColor(srgbRed: 0x3D/255.0, green: 0x38/255.0, blue: 0x29/255.0, alpha: 1)  // #3D3829 the darker on-palette ink
    static let trioInk = NSColor(srgbRed: 0x70/255.0, green: 0x56/255.0, blue: 0x51/255.0, alpha: 1)  // #705651 the spine's ink — clock · battery, stepped down from plain ink

    // the overlay's dark skin — the pill palette inverted for the dimmed
    // screen. same warm family, flipped: near-black glass, cream ink. the
    // widgets read the SAME state, the ink just points the other way.
    static let darkGlass    = NSColor(srgbRed: 0x24/255.0, green: 0x1E/255.0, blue: 0x19/255.0, alpha: 1)  // #241E19 the card
    static let darkStroke   = NSColor.white.withAlphaComponent(0.10)                                       // the card's hairline
    static let darkText     = NSColor(srgbRed: 0xFA/255.0, green: 0xF6/255.0, blue: 0xF3/255.0, alpha: 1)  // cream — primary ink
    static let darkMuted    = NSColor(srgbRed: 0xA8/255.0, green: 0x9F/255.0, blue: 0x93/255.0, alpha: 1)  // #A89F93 quiet ink
    static let darkShell    = NSColor(srgbRed: 0xC4/255.0, green: 0xB2/255.0, blue: 0x9F/255.0, alpha: 1)  // #C4B29F battery shell + charge fill
    static let darkShellHover = NSColor(srgbRed: 0xE7/255.0, green: 0xDC/255.0, blue: 0xCB/255.0, alpha: 1) // battery hover: one step toward cream
    static let darkShellLPM = NSColor(srgbRed: 0xC9/255.0, green: 0x8F/255.0, blue: 0x3F/255.0, alpha: 1)  // LPM: lighter lamp amber
    static let darkTrack    = NSColor.white.withAlphaComponent(0.15)                                       // the slider's empty run
    static let darkValue    = NSColor(srgbRed: 0xC4/255.0, green: 0xB2/255.0, blue: 0x9F/255.0, alpha: 1)   // the slider's value run
    static let darkValueHover = NSColor(srgbRed: 0xE7/255.0, green: 0xDC/255.0, blue: 0xCB/255.0, alpha: 1) // value run under the cursor — one step brighter

    // the trio's ink standard: every glyph renders with the SAME ink
    // footprint area (345pt² of bounding box), tuned so the widest glyph
    // (the speaker) matches the knob faces' ~19pt of ink at the current
    // sliderHandle. equal area keeps the different aspects — the tall
    // rune, the square speaker, the tall mic — at identical visual mass.
    static let trioInkArea: CGFloat = 345

    // the trio is ONE library now — all four glyphs are Material Symbols
    // (rounded, filled), which are designed with equal optical weight across
    // the set. measured ink: wifi 137.5, bluetooth 105.4, audio 132.1,
    // mic 93.2 u² — the library's own balance, no per-glyph equalizer
    // needed. one scale for all: 1.0 → 22.25pt grid box in each quarter.
    static let trioScale: [String: CGFloat] = [
        "bluetooth": 1.0, "audio": 1.0, "mic": 1.0, "wifi": 1.0,
    ]

    // grid — one uniform CELL slot per widget, stacked top to bottom
    static let cell: CGFloat = 30
    static let slotWidth: CGFloat = 34   // the widget column's width — cell is heights only
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
    //
    // the column reads as a narrative, top to bottom:
    //   time → device power → connection
    //   (the quiet capsule) → control (the sliders) → sleep (power)
    enum Kind {
        case battery, hour, minute, trio, slider, night, audio, bluetooth, microphone, wifi, power
    }
    struct SlotDef {
        let kind: Kind
        let span: Int
        init(_ kind: Kind, span: Int = 1) { self.kind = kind; self.span = span }
    }
    static let slots: [SlotDef] = [
        .init(.hour),
        .init(.minute),
        .init(.battery),       // status groups with status: charge above connection
        .init(.slider, span: 5),   // same M3 styling as ever (cool taupe, Night-Day face) —
                                   // the value it reads/writes is Night Shift strength now
        // .init(.night, span: 5), // ← the warm moon-slider variant, parked
    ] + (LEGACY_TRIO ? [
        .init(.trio, span: 4),   // bluetooth · wifi · audio · mic — one flush slot: no seams between the icons,
        .init(.power),           // each icon's padding lives inside its own quarter of the block
    ] : [
        .init(.power),
    ])
    static var slotCount: Int { slots.count }

    // SVG icons are ink-normalized: each glyph's ink is scaled to one
    // optical size (see SVGIcon.frame) and centered in these 30pt slots.
    static let iconSize: CGFloat = 32       // the 24 grid's base scale, all icons

    // the trio's hover band: ONE darkened segment of the quiet capsule, full
    // track width and one cell tall, that GLIDES from icon to icon as the
    // cursor moves (position in slot-index space) and crossfades away when
    // the cursor leaves the trio. two springs: alpha + position.
    static var trioBandAlpha: CGFloat = 0
    static var trioBandPos: CGFloat = 0      // band center, slot-index space
    static var trioBandTarget: Int = -1      // hovered trio slot, -1 = none

    static func isIcon(_ kind: Kind) -> Bool {
        switch kind {
        case .bluetooth, .audio, .microphone, .wifi:
            return true
        default:
            return false
        }
    }

    // grid debug: stroke every slot + the padding bounds so the layout is
    // visible. red = widget slots, blue = where the padding ends. flip to
    // false when done squinting at it.
    static let debugGrid = false

    // type — SF Pro tabular digits, weight-matched to the icon strokes:
    // regular at 19pt stems ≈ 1.9pt vs the icons' rendered ~2.0pt. (medium
    // stems 2.3pt — measurably heavier than every glyph next to it.)
    static let typeSize: CGFloat = 24    // the clock — SF Mono (system mono): digits in
                                         // a true monospace face, one fused two-line block

    // slider — material design 3's shape language in smalt's skin. the
    // track is the glyphs' FULL ink width (iconSize/24 × optical = 26.25),
    // so the two sliders and the trio's quiet capsule align exactly with
    // the battery's span above them — one width, everywhere.
    // the knob stays 24: a disc slightly prouder than its track, M3-style.
    static var sliderTrack: CGFloat { iconSize / 24 * 21 + 2 }   // = 28.25 — glyph width, a touch wider
    static var sliderHandle: CGFloat { sliderTrack }         // the knob: same width, one disc
    static let sliderFill = NSColor(srgbRed: 0x75/255.0, green: 0x56/255.0, blue: 0x4F/255.0, alpha: 1)  // #75564F value run
    static let sliderHoverFill = NSColor(srgbRed: 0x5E/255.0, green: 0x46/255.0, blue: 0x3F/255.0, alpha: 1)  // #5E463F value run under the cursor — one step TOWARD THE KNOB, darker, never near the empty run
    static let knob      = NSColor(srgbRed: 0x3A/255.0, green: 0x2D/255.0, blue: 0x27/255.0, alpha: 1)  // #3A2D27 knob bg
    static var sliderValue: CGFloat = 0.5    // the hardware's current level (sampled)
    static var sliderDisplay: CGFloat = 0.5  // what the handle draws — springs toward sliderValue
    static var sliderFace: CGFloat = 0       // knob face crossfade: 0 = Night-Day, 1 = %
    static var sliderHover: CGFloat = 0      // 0→1 while the cursor is on the slider SLOT — drives the fill tint only

    // the night-shift slider — the brightness slider's own M3 shape
    // language, but the value run is WARM: the ink of a lamp, not the ink
    // of a key. its value IS Night Shift's live strength (CoreBrightness
    // CBBlueLightClient — the Night Shift pane's own client class):
    // 0–1, shallow → intensive. schedule OFF reads as 0 and the knob face
    // says OFF, not 0%.
    static let nightFill = NSColor(srgbRed: 0xA8/255.0, green: 0x73/255.0, blue: 0x2A/255.0, alpha: 1)      // #A8732A value run — lamp amber-brown
    static let nightHoverFill = NSColor(srgbRed: 0x7E/255.0, green: 0x54/255.0, blue: 0x14/255.0, alpha: 1) // #7E5414 value run under the cursor — one step toward the knob, darker
    static var nightValue: CGFloat = 0.35    // Night Shift strength (sampled, 0..1)
    static var nightDisplay: CGFloat = 0.35  // what the handle draws — springs toward nightValue
    static var nightFace: CGFloat = 0        // knob face crossfade: 0 = moon, 1 = %/OFF
    static var nightHover: CGFloat = 0       // 0→1 while the cursor is on the night SLOT — drives the fill tint only
    static var nightOff = false              // true = the Night Shift schedule is Off (face says OFF, not 0%)
    static var knobHover: CGFloat = 0        // 0→1 while the cursor is on the KNOB itself — drives the knob swell
    static var knobPop: CGFloat = 0          // damped wobble (1 → 0, overshooting) fired on the first KNOB hover each summon
    static var nightKnobHover: CGFloat = 0   // the night knob's own swell — same component, warm ink
    static var nightKnobPop: CGFloat = 0     // the night knob's first-hover wobble
    static var powerHover: CGFloat = 0       // 0→1 while the cursor is on the power button — drives its swell, disc tint, and the power⇄moon face crossfade
    static var batteryHover: CGFloat = 0     // 0→1 while the cursor is on the battery slot — the glyph's ink deepens
    static var batteryPop: CGFloat = 0       // damped wobble (1 → 0, overshooting) fired on every battery click (LPM toggle)

    // the pill is exactly its grid — derived from the slot stack, never hand-counted
    static var contentHeight: CGFloat {
        // every widget's full footprint: its cells PLUS the gaps inside its
        // span — then the between-widget gaps on top. omit the internal gaps
        // and the stack overflows the glass (the vanishing bottom margin).
        slots.reduce(0) { $0 + CGFloat($1.span) * cell + CGFloat($1.span - 1) * gap }
            + CGFloat(slotCount - 1) * gap
    }
    static var pillWidth: CGFloat { slotWidth + 2 * pad }
    static var pillHeight: CGFloat { 2 * pad + contentHeight }

    // the slot rect for widget i: its span of cells (no internal gaps),
    // offset by every widget above it — each predecessor's FULL footprint:
    // its cells PLUS the gaps inside its span, then one between-widget gap.
    // flipped coords — y grows downward.
    static func slot(_ index: Int, in bounds: NSRect) -> NSRect {
        var y = pad
        for j in 0..<index { y += CGFloat(slots[j].span) * cell + CGFloat(slots[j].span - 1) * gap + gap }
        let h = CGFloat(slots[index].span) * cell + CGFloat(slots[index].span - 1) * gap
        return NSRect(x: pad, y: y, width: slotWidth, height: h)
    }
}

let PILL_WIDTH = Theme.pillWidth
let PILL_HEIGHT = Theme.pillHeight
let PILL_INSET: CGFloat = 10     // float: the pill hovers this far off the right screen edge
let SHADOW_SLACK: CGFloat = 10   // window slack above + below the glass — the fake
                                 // shadow spills 7pt past every edge, and a window
                                 // that ends at the glass clips its own shadow (the
                                 // pill's bottom shadow used to vanish exactly so)
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

// the knob's hover machine — ONE component, three users: the pill's two
// sliders and the overlay's slider. it answers the cursor↔knob relationship
// wherever sync() is called: the FIRST hover of a session fires the wobble
// (the latch), EVERY arrival fires the haptic tick, and the knob's hover
// blend springs in and out. the surface repaint belongs to the popWrite
// closure — each user marks its own view.
final class KnobHoverMachine {
    private let hovered: () -> Bool
    private let read: () -> CGFloat
    private let write: (CGFloat) -> Void
    private let popWrite: (CGFloat) -> Void
    private let latch: () -> Bool
    private let setLatch: () -> Void
    private let haptic: () -> Void
    private(set) var wasHovered = false
    private lazy var spring = ChaseTimer(
        get: read,
        set: write,
        target: { [weak self] in (self?.hovered() ?? false) ? 1 : 0 },
        rate: 0.25, epsilon: 0.004)
    private var popTimer: Timer?
    private var pop: CGFloat = 0
    private var popV: CGFloat = 0

    init(hovered: @escaping () -> Bool, read: @escaping () -> CGFloat,
         write: @escaping (CGFloat) -> Void, popWrite: @escaping (CGFloat) -> Void,
         latch: @escaping () -> Bool, setLatch: @escaping () -> Void,
         haptic: @escaping () -> Void) {
        self.hovered = hovered; self.read = read
        self.write = write; self.popWrite = popWrite
        self.latch = latch; self.setLatch = setLatch
        self.haptic = haptic
    }

    func sync() {
        let h = hovered()
        if h, !wasHovered, glassDocked {
            haptic()
            if !latch() {
                setLatch()
                firePop()
            }
        }
        wasHovered = h
        spring.start()
    }

    // the first-hover bounce: an underdamped spring released from
    // displacement 1 — the knob swells ~12% and wobbles back to rest
    // (ω ≈ 20.5 rad/s, ζ ≈ 0.34 → two visible overshoots, ~0.5s). its own
    // 120fps integrator, started on demand, self-stopping at rest.
    private func firePop() {
        pop = 1
        popV = 0
        guard popTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let K: CGFloat = 420, C: CGFloat = 14, dt: CGFloat = 1.0 / 120.0
            popV += (-K * pop - C * popV) * dt
            pop += popV * dt
            if abs(pop) < 0.002, abs(popV) < 0.02 {
                pop = 0
                popTimer?.invalidate(); popTimer = nil
            }
            popWrite(pop)
        }
        RunLoop.main.add(t, forMode: .common)
        popTimer = t
    }
}

// battery display state — what the battery slot is currently drawing,
// plus the two crossfade springs: the bolt fades on plug/unplug, the fill
// color fades on low power mode. springs chase targets on the glass's
// repaint loop, same as the slider's.
var batteryShown = (charging: false, lpm: false)   // the state being drawn
var batteryStateInit = false                       // first draw adopts the real state unfaded
var boltAlpha: CGFloat = 0                         // bolt crossfade
var fillFrom = Theme.sliderFill, fillTo = Theme.sliderFill
var fillBlend: CGFloat = 1                         // LPM fill crossfade

// the battery's charge fill — the slider palette end to end: the normal
// state wears the brightness slider's value run, low power mode wears the
// night-shift slider's warm run (the lamp amber, not a separate yellow)
func batteryFillColor(_ lpm: Bool) -> NSColor { lpm ? Theme.nightFill : Theme.trioInk }

// two opaque colors blended on device rgb
func lerp(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
    let x = a.usingColorSpace(.deviceRGB)!, y = b.usingColorSpace(.deviceRGB)!
    return NSColor(srgbRed: x.redComponent + (y.redComponent - x.redComponent) * t,
                   green: x.greenComponent + (y.greenComponent - x.greenComponent) * t,
                   blue: x.blueComponent + (y.blueComponent - x.blueComponent) * t,
                   alpha: 1)
}

let boltSpring = ChaseTimer(get: { boltAlpha },
    set: { boltAlpha = $0; tab.needsDisplay = true },
    target: { batteryShown.charging ? 1 : 0 }, rate: 0.2, epsilon: 0.01)
let fillSpring = ChaseTimer(get: { fillBlend },
    set: { fillBlend = $0; tab.needsDisplay = true },
    target: { 1 }, rate: 0.2, epsilon: 0.005)

// fake shadow: four soft strokes around a shape — drawn as CONTENT, so they
// ride every animation for free (the window server's real shadow re-blurs
// the whole window on every content change; at 120fps that was the unusable
// lag). the fill covers the inner half of each stroke. ONE recipe for every
// smalt surface — the pill and its arm cast the same shadow, which is what
// makes them read as one object. `alpha` fades the whole pass (the arm's
// entrance/exit).
func strokeFakeShadow(_ path: NSBezierPath, alpha: CGFloat = 1) {
    for (w, a) in [(14.0, 0.02), (10.0, 0.035), (6.0, 0.05), (2.0, 0.06)] {
        path.lineWidth = CGFloat(w)
        NSColor.black.withAlphaComponent(CGFloat(a) * alpha).setStroke()
        path.stroke()
    }
}

final class StripView: NSView {
    override var isFlipped: Bool { true }   // y counts down from the pill top

    // the fake shadow spills 7pt past the glass's edges — past this view's
    // bounds. without this override the default bounds clip would cut every
    // stroke's outer half off and the pill would cast no shadow at all.
    override var wantsDefaultClipping: Bool { false }

    // the extension arm paints to the LEFT of this view's bounds (negative x)
    // — one glass, one view, no second window. without this override the
    // default bounds clip would cut it off.

    // the tab: a full capsule — rounded on ALL corners, floating free of the
    // screen edge (PILL_INSET gap). the bottom-left radius parameter is the
    // legacy arm's melt grammar; the arm is retired, every corner is R.
    private func tabPath(in bounds: NSRect, bottomLeftRadius rb: CGFloat? = nil) -> NSBezierPath {
        let R = PILL_RADIUS
        let k: CGFloat = 0.5523
        let W = bounds.width, H = bounds.height
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 0, y: R))
        p.curve(to: NSPoint(x: R, y: 0),
                controlPoint1: NSPoint(x: 0, y: R - k * R),
                controlPoint2: NSPoint(x: R - k * R, y: 0))
        p.line(to: NSPoint(x: W - R, y: 0))
        p.curve(to: NSPoint(x: W, y: R),
                controlPoint1: NSPoint(x: W - R + k * R, y: 0),
                controlPoint2: NSPoint(x: W, y: R - k * R))
        p.line(to: NSPoint(x: W, y: H - R))
        p.curve(to: NSPoint(x: W - R, y: H),
                controlPoint1: NSPoint(x: W, y: H - R + k * R),
                controlPoint2: NSPoint(x: W - R + k * R, y: H))
        p.line(to: NSPoint(x: R, y: H))
        p.curve(to: NSPoint(x: 0, y: H - R),
                controlPoint1: NSPoint(x: R - k * R, y: H),
                controlPoint2: NSPoint(x: 0, y: H - R + k * R))
        p.line(to: NSPoint(x: 0, y: R))
        p.close()
        return p
    }

    // hover: which slot the cursor is over (-1 = none). tracked, not polled.
    // drives the slot-level washes; the slider's knob-level states are
    // position-driven — see syncKnobHover.
    var bouncedThisSummon = false   // file-visible: the daemon poll clears it when the glass parks
    private var hoverSlot: Int = -1 {
        didSet {
            guard hoverSlot != oldValue else { return }
            needsDisplay = true
            if hoverSlot == Theme.slots.firstIndex(where: { $0.kind == .slider })
                || oldValue == Theme.slots.firstIndex(where: { $0.kind == .slider }) {
                hoverSpring.start()
            }
            if hoverSlot == Theme.slots.firstIndex(where: { $0.kind == .night })
                || oldValue == Theme.slots.firstIndex(where: { $0.kind == .night }) {
                nightHoverSpring.start()
            }
            if hoverSlot == Theme.slots.firstIndex(where: { $0.kind == .power })
                || oldValue == Theme.slots.firstIndex(where: { $0.kind == .power }) {
                powerSpring.start()
            }
            if hoverSlot == Theme.slots.firstIndex(where: { $0.kind == .battery })
                || oldValue == Theme.slots.firstIndex(where: { $0.kind == .battery }) {
                batteryHoverSpring.start()
            }
            // hover haptic: the power button only — the one button that gets it.
            if hoverSlot >= 0, Theme.slots[hoverSlot].kind == .power {
                hapticTick(.alignment)
            }
            // the trio's hover band: retarget and wake both springs — the
            // band glides to the hovered third, or crossfades out off the trio
            syncTrioBandTarget()
            trioBandAlphaSpring.start()
            trioBandPosSpring.start()
        }
    }

    // the hovered trio quarter (0–3), or -1 when the cursor isn't on the trio.
    // called from the poll and on hover changes — the cursor can cross quarters
    // without ever leaving the trio's tracking area.
    func syncTrioBandTarget() {
        var target = -1
        if hoverSlot >= 0, Theme.slots[hoverSlot].kind == .trio,
           let p = cursorPoint {
            let r = Theme.slot(hoverSlot, in: bounds)
            target = min(3, max(0, Int((p.y - r.minY) / (r.height / 4))))
        }
        guard target != Theme.trioBandTarget else { return }
        Theme.trioBandTarget = target
        if Theme.trioBandAlpha < 0.001, target >= 0 {
            Theme.trioBandPos = CGFloat(target)   // first show: bloom in place
        }
        trioBandAlphaSpring.start()
        trioBandPosSpring.start()
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
        // the LOCAL mouse-moved feed: while the cursor is on the glass the
        // panel is KEY (hover attention) — and global event monitors are
        // SILENT for an app's own events. without this area, the tooltip
        // only tracks at the 30Hz poll while hovered: visibly slow. with
        // it, mouseMoved arrives at event rate, key or not.
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeAlways],
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
    var cursorPoint: NSPoint? {
        guard let win = window else { return nil }
        let p = win.convertFromScreen(NSRect(origin: NSEvent.mouseLocation, size: .zero)).origin
        return convert(p, from: nil)
    }

    // the battery tooltip lives in its own window above the strip (see
    // refreshBatteryTooltip) — the glass can't clip a window it doesn't own

    // the pointing-hand decision, position-driven: over an interactive slot
    // (slider, power) of a PARKED glass. no tracking-area dependency —
    // hoverSlot only updates on mouse events, and the first hover can happen
    // with zero of those.
    private func overInteractive() -> Bool {
        guard glassDocked, let p = cursorPoint else { return false }
        return slotIndex(at: p).map {
            Theme.slots[$0].kind == .slider || Theme.slots[$0].kind == .night
                || Theme.slots[$0].kind == .power || Theme.slots[$0].kind == .battery
        } ?? false
    }

    override func cursorUpdate(with event: NSEvent) {
        // apps beneath push their cursors on redraw; re-win by position
        syncKnobHover()
        if overInteractive() {
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
        syncKnobHover()                            // 30Hz position-driven knob hover (stationary cursor, moving knob)
        syncTrioBandTarget()                       // 30Hz position-driven band glide (crossing quarters inside the trio)
        // the tooltip rides the cursor in its OWN window above the strip —
        // every move (monitor) and poll tick re-places it; the tab itself
        // never repaints for the tooltip's sake
        refreshBatteryTooltip()
        window?.invalidateCursorRects(for: self)   // window server re-reads resetCursorRects
        if overInteractive() {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        if let slot = event.trackingArea?.userInfo?["slot"] as? Int { hoverSlot = slot }
    }

    override func mouseMoved(with event: NSEvent) {
        // the local feed (see updateTrackingAreas): while the panel is key
        // the global monitor is silent for smalt's own events — this keeps
        // the tooltip and the cursor at EVENT rate, not the poll's 30Hz
        reassertCursor()
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
    private lazy var nightValueSpring = ChaseTimer(
        get: { Theme.nightDisplay },
        set: { [weak self] v in Theme.nightDisplay = v; self?.needsDisplay = true },
        target: { Theme.nightValue },
        rate: 0.22, epsilon: 0.0004)
    private lazy var faceSpring = ChaseTimer(
        get: { Theme.sliderFace },
        set: { [weak self] v in Theme.sliderFace = v; self?.needsDisplay = true },
        target: { [weak self] in self?.faceTarget ?? 0 },
        rate: 0.25, epsilon: 0.002)

    // the night knob's face crossfade — same shape, one blend apart
    private var nightFaceTarget: CGFloat = 0
    private lazy var nightFaceSpring = ChaseTimer(
        get: { Theme.nightFace },
        set: { [weak self] v in Theme.nightFace = v; self?.needsDisplay = true },
        target: { [weak self] in self?.nightFaceTarget ?? 0 },
        rate: 0.25, epsilon: 0.002)

    // the slot-level hover blend: 1 while the cursor sits anywhere on the
    // slider slot of a PARKED glass — tints the value run, nothing else.
    // the target re-checks glassDocked every tick, so a glass that slides
    // away or parks fades the tint on its own — no reliance on mouseExited.
    private lazy var hoverSpring = ChaseTimer(
        get: { Theme.sliderHover },
        set: { v in Theme.sliderHover = v; tab.needsDisplay = true },
        target: { [weak self] in
            guard let self, glassDocked,
                  hoverSlot == Theme.slots.firstIndex(where: { $0.kind == .slider }) else { return 0 }
            return 1
        },
        rate: 0.22, epsilon: 0.004)

    // the night slot's hover blend — the twin of hoverSpring above: same
    // tint grammar, warm ink. the target re-checks glassDocked every tick.
    private lazy var nightHoverSpring = ChaseTimer(
        get: { Theme.nightHover },
        set: { v in Theme.nightHover = v; tab.needsDisplay = true },
        target: { [weak self] in
            guard let self, glassDocked,
                  hoverSlot == Theme.slots.firstIndex(where: { $0.kind == .night }) else { return 0 }
            return 1
        },
        rate: 0.22, epsilon: 0.004)

    // the battery slot's hover blend — the same wash, one slot wide.
    private lazy var batteryHoverSpring = ChaseTimer(
        get: { Theme.batteryHover },
        set: { v in Theme.batteryHover = v; tab.needsDisplay = true; refreshBatteryTooltip() },
        target: { [weak self] in
            guard let self, glassDocked,
                  hoverSlot == Theme.slots.firstIndex(where: { $0.kind == .battery }) else { return 0 }
            return 1
        },
        // the tooltip's OWN blend — and it's the ONLY thing left on this
        // blend (the icon is static on hover), so it's tuned for the
        // tooltip: ~50ms in/out, a soft cut, not a slow theatrical fade
        rate: 0.7, epsilon: 0.01)

    // the band's two springs: alpha answers "is a trio slot hovered on a
    // PARKED glass", position glides toward the hovered slot's index and
    // holds still while the band fades out off the trio.
    // the trio slot's region — the band springs only ever dirty this,
    // never the whole pill, so their 120fps repaints stay cheap
    var trioRegion: NSRect {
        guard let t = Theme.slots.firstIndex(where: { $0.kind == .trio }) else { return bounds }
        return Theme.slot(t, in: bounds).insetBy(dx: -12, dy: -12)
    }

    private lazy var trioBandAlphaSpring = ChaseTimer(
        get: { Theme.trioBandAlpha },
        set: { Theme.trioBandAlpha = $0; tab.setNeedsDisplay(tab.trioRegion) },
        target: { glassDocked && Theme.trioBandTarget >= 0 ? 1 : 0 },
        rate: 0.5, epsilon: 0.004)
    private lazy var trioBandPosSpring = ChaseTimer(
        get: { Theme.trioBandPos },
        set: { Theme.trioBandPos = $0; tab.setNeedsDisplay(tab.trioRegion) },
        target: { Theme.trioBandTarget >= 0 ? CGFloat(Theme.trioBandTarget) : Theme.trioBandPos },
        rate: 0.5, epsilon: 0.002)

    // the KNOB's own hover, position-driven: cursor vs the knob's live rect
    // (recomputed every check, so it tracks the handle as it travels). this —
    // and only this — drives the knob swell + first-hover wobble.
    private var knobWasHovered = false
    // the KNOB's own hover, position-driven: cursor vs the knob's live rect
    // (recomputed every check, so it tracks the handle as it travels). this —
    // and only this — drives the knob swell + first-hover wobble. ONE
    // machinery, TWO sliders: the brightness knob and the night knob are
    // the same component, differing only in which state they read and write.
    // the KNOB's own hover, position-driven: cursor vs the knob's live rect
    // (recomputed every check, so it tracks the handle as it travels). this —
    // and only this — drives the knob swell + first-hover wobble. ONE
    // machinery, TWO sliders: the brightness knob and the night knob are
    // the same component, differing only in which state they read and write.
    // (the machine itself is file-scope now — the overlay's slider runs the
    // exact same component; only the closures differ.)
    private lazy var sliderKnob = KnobHoverMachine(
        hovered: { [weak self] in self?.knobHovered(.slider) ?? false },
        read: { Theme.knobHover },
        write: { v in Theme.knobHover = v; tab.needsDisplay = true },
        popWrite: { Theme.knobPop = $0; tab.needsDisplay = true },
        latch: { [weak self] in self?.bouncedThisSummon ?? true },
        setLatch: { [weak self] in self?.bouncedThisSummon = true },
        haptic: { [weak self] in self?.hapticTick(.alignment) })
    private lazy var nightKnob = KnobHoverMachine(
        hovered: { [weak self] in self?.knobHovered(.night) ?? false },
        read: { Theme.nightKnobHover },
        write: { v in Theme.nightKnobHover = v; tab.needsDisplay = true },
        popWrite: { Theme.nightKnobPop = $0 },
        latch: { [weak self] in self?.bouncedThisSummon ?? true },
        setLatch: { [weak self] in self?.bouncedThisSummon = true },
        haptic: { [weak self] in self?.hapticTick(.alignment) })

    private func knobRect(_ kind: Theme.Kind) -> NSRect {
        // a hidden widget (its slot commented out) has no knob — .zero keeps
        // its hover machinery permanently false instead of latching onto slot 0
        guard let i = Theme.slots.firstIndex(where: { $0.kind == kind }) else { return .zero }
        let r = Theme.slot(i, in: bounds)
        let yBottom = r.maxY - Theme.sliderHandle / 2
        let yTop = r.minY + Theme.sliderHandle / 2
        let v = kind == .slider ? Theme.sliderDisplay : Theme.nightDisplay
        let hc = yBottom + (yTop - yBottom) * max(0, min(1, v))
        return NSRect(x: r.midX - Theme.sliderHandle / 2, y: hc - Theme.sliderHandle / 2,
                      width: Theme.sliderHandle, height: Theme.sliderHandle)
    }

    private func knobHovered(_ kind: Theme.Kind) -> Bool {
        guard glassDocked, let p = cursorPoint else { return false }
        return knobRect(kind).insetBy(dx: -3, dy: -3).contains(p)
    }

    // called wherever the cursor↔knob relationship may have changed: the 30Hz
    // poll (via reassertCursor — covers a stationary cursor while the knob
    // moves under it), cursorUpdate, and drags. BOTH knobs sync here.
    func syncKnobHover() {
        sliderKnob.sync()
        nightKnob.sync()
    }

    // the power button's hover blend: 1 while the cursor sits on its slot of
    // a PARKED glass. one value drives all three responses — the disc swell,
    // the knob→sliderFill tint, and the power⇄moon face crossfade — so they
    // move as one gesture. target re-checks glassDocked every tick: park the
    // glass and the button settles back on its own.
    private lazy var powerSpring = ChaseTimer(
        get: { Theme.powerHover },
        set: { v in Theme.powerHover = v; tab.needsDisplay = true },
        target: { [weak self] in
            guard let self, glassDocked,
                  hoverSlot == Theme.slots.firstIndex(where: { $0.kind == .power }) else { return 0 }
            return 1
        },
        rate: 0.22, epsilon: 0.004)

    // crossfade the knob face (Night-Day ⇄ %) — the face spring runs only while the
    // blend has distance to cover
    private func setFaceTarget(_ target: CGFloat) {
        faceTarget = target
        faceSpring.start()
    }

    func beginValueSpring() {
        valueSpring.start()   // no-op if already within epsilon of the hardware
    }

    func beginNightValueSpring() {
        nightValueSpring.start()   // no-op if already within epsilon of the setting
    }

    // crossfade the night knob's face (moon ⇄ %/OFF)
    private func setNightFaceTarget(_ target: CGFloat) {
        nightFaceTarget = target
        nightFaceSpring.start()
    }

    // one drag mapping, one writer: the value the cursor maps to is written
    // straight through to the hardware that owns the slot — Night Shift
    // strength.
    // ── haptics ── the trackpad "tickle": NSHapticFeedbackManager is what
    // System Settings' sliders use for detents. one .levelChange ratchet
    // tick per 5% crossed DURING A DRAG — nothing on hover, nothing on
    // grab. the system throttles levelChange so a fast scrub reads as
    // notch-to-notch, and unsupported hardware no-ops silently.
    private var hapticStep = Int.min

    private func hapticTick(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    // the battery's toggle pop: the knobs' own underdamped wobble (ω ≈ 20.5,
    // ζ ≈ 0.34 → two visible overshoots, ~0.5s), fired on every battery
    // click — the digits swell and settle while the fill crossfades to its
    // new ink behind them (the LPM crossfade rides the same repaints)
    private var batteryPopTimer: Timer?
    private var batteryPopV: CGFloat = 0

    private func fireBatteryPop() {
        Theme.batteryPop = 1
        batteryPopV = 0
        guard batteryPopTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let K: CGFloat = 420, C: CGFloat = 14, dt: CGFloat = 1.0 / 120.0
            self.batteryPopV += (-K * Theme.batteryPop - C * self.batteryPopV) * dt
            Theme.batteryPop += self.batteryPopV * dt
            if abs(Theme.batteryPop) < 0.002, abs(self.batteryPopV) < 0.02 {
                Theme.batteryPop = 0
                self.batteryPopTimer?.invalidate(); self.batteryPopTimer = nil
            }
            tab.needsDisplay = true
            refreshBatteryTooltip()
        }
        RunLoop.main.add(t, forMode: .common)
        batteryPopTimer = t
    }

    // prime the ratchet at the grab position without firing — the first
    // levelChange waits for real motion, not just the press.
    private func armHapticStep(at p: NSPoint) {
        guard let i = dragSlot else { return }
        let r = Theme.slot(i, in: bounds)
        let v = min(1, max(0, (r.maxY - p.y) / r.height))
        hapticStep = Int((v * 20).rounded(.down))
    }

    private func updateSliderValue(at p: NSPoint) {
        guard let i = dragSlot else { return }
        let r = Theme.slot(i, in: bounds)
        // flipped coords: slot top (minY) = 1.0, bottom = 0.0
        var v = min(1, max(0, (r.maxY - p.y) / r.height))
        // the 50% detent: within a knob's pull of the midpoint, the value
        // snaps to exactly 0.5 — the tiny knob marks the spot
        if abs(v - 0.5) < 0.035 { v = 0.5 }
        switch Theme.slots[i].kind {
        case .slider:
            Theme.sliderValue = v
            Theme.nightOff = (v == 0)
            NightShift.set(Float(v))           // the Night Shift pane's own call path
            valueSpring.stop()                 // the cursor is the only spring that matters here
        case .night:
            Theme.nightValue = v
            Theme.nightOff = (v == 0)
            NightShift.set(Float(v))           // the Night Shift pane's own call path
            nightValueSpring.stop()
        default:
            break
        }
        // detent tick: one .levelChange per 5% crossed — the ratchet. fire
        // only when the step index actually moves, so holding still is silent.
        let step = Int((v * 20).rounded(.down))
        if step != hapticStep {
            hapticStep = step
            hapticTick(.levelChange)
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = slotIndex(at: p), glassDocked else { return }
        switch Theme.slots[i].kind {
        case .slider:
            dragSlot = i
            setFaceTarget(1)
            armHapticStep(at: p)
            updateSliderValue(at: p)
        case .night:
            dragSlot = i
            setNightFaceTarget(1)
            armHapticStep(at: p)
            updateSliderValue(at: p)
        case .power:
            sleepSystem()
        case .battery:
            fireBatteryPop()
            hapticTick(.alignment)
            setLowPowerMode(!ProcessInfo.processInfo.isLowPowerModeEnabled)
        default:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        updateSliderValue(at: convert(event.locationInWindow, from: nil))
        syncKnobHover()   // the cursor IS the knob mid-drag — keep the swell honest
    }

    override func mouseUp(with event: NSEvent) {
        dragSlot = nil
        hapticStep = Int.min                   // fresh ratchet next grab
        setFaceTarget(0)        // back to the Night-Day icon on release — no debounce
        setNightFaceTarget(0)   // …and back to the moon on the night knob
    }

    // the glass: #FAF6F3 — the caelestia tab shape: rounded on the left,
    // fused into the right screen edge with concave fillets top and bottom
    override func draw(_ dirtyRect: NSRect) {
        let path = tabPath(in: bounds, bottomLeftRadius: extBottomLeftRadius())

        // the shared fake shadow (see strokeFakeShadow), then the glass fill
        strokeFakeShadow(path)
        Theme.glass.setFill()
        path.fill()

        // the collective pill: one quiet capsule behind the connectable
        // four — bluetooth · wifi · audio · microphone — in the sliders' EXACT
        // track language: same width (sliderTrack), same rounding, and the
        // same quiet run (sliderFill at 30%) the sliders above wear. the
        // column reads as one continuous capsule language top to bottom.
        if let trio = Theme.slots.firstIndex(where: { $0.kind == .trio }) {
            let slot = Theme.slot(trio, in: bounds)
            // EXACTLY the slider track's width and x-position — the trio pill
            // and the sliders are one continuous 28.25pt-wide column
            let track = NSRect(x: slot.midX - Theme.sliderTrack / 2, y: slot.minY,
                               width: Theme.sliderTrack, height: slot.height)
            Theme.sliderFill.withAlphaComponent(0.3).setFill()
            NSBezierPath(roundedRect: track, xRadius: Theme.sliderTrack / 2,
                         yRadius: Theme.sliderTrack / 2).fill()

            // the hover band: glides between the trio's quarters — the
            // quarters tile the fused slot flush, so there are no dead strips
            // between the icons while it moves.
            if Theme.trioBandAlpha > 0.001 {
                let subH = track.height / 4
                let yc = track.minY + (Theme.trioBandPos + 0.5) * subH
                let band = NSRect(x: track.minX, y: yc - subH / 2,
                                  width: track.width, height: subH)
                if let ctx = NSGraphicsContext.current?.cgContext {
                    ctx.saveGState()
                    NSBezierPath(roundedRect: track, xRadius: Theme.sliderTrack / 2,
                                 yRadius: Theme.sliderTrack / 2).addClip()
                    Theme.knob.withAlphaComponent(0.15 * Theme.trioBandAlpha).setFill()
                    NSBezierPath(roundedRect: band, xRadius: band.width / 2,
                                 yRadius: band.width / 2).fill()
                    ctx.restoreGState()
                }
            }
        }

        // the grid: each entry of Theme.slots draws in its own uniform
        // slot — the container is built from the same list, so widget and
        // window can never disagree
        for i in 0..<Theme.slotCount {
            let r = Theme.slot(i, in: bounds)
            let kind = Theme.slots[i].kind

            switch kind {
            case .trio:
                // the four glyphs, one per flush quarter of the fused slot —
                // knob ink, the same family as the power disc below: dark
                // enough to read inside the 30% quiet run
                let subH = r.height / 4
                drawBluetooth(in: NSRect(x: r.minX, y: r.minY, width: r.width, height: subH),
                              ink: Theme.knob)
                drawWifi(in: NSRect(x: r.minX, y: r.minY + subH, width: r.width, height: subH),
                         ink: Theme.knob)
                drawAudio(in: NSRect(x: r.minX, y: r.minY + 2 * subH, width: r.width, height: subH),
                          ink: Theme.knob)
                drawMicrophone(in: NSRect(x: r.minX, y: r.minY + 3 * subH, width: r.width, height: subH),
                               ink: Theme.knob)
            case .battery: drawBattery(in: r)
            case .slider: drawSlider(in: r)
            case .night: drawNightSlider(in: r)
            case .hour: drawClock(.hour, in: r)
            case .minute: drawClock(.minute, in: r)
            case .power: drawPower(in: r)
            default: break
            }
        }

        // the battery tooltip: a child window above the strip — refreshed
        // here (last), so it layers over the widgets underneath it
        refreshBatteryTooltip()

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
//   · SVG icons draw ink-normalized on their 24×24 grid, centered in
//     each slot (SVGIcon.frame)
//   · text draws centered by INK (glyph bounds), not line height —
//     line-height centering leaves digits riding high, which is exactly
//     the "percentage isn't in the middle" bug

// MARK: - SVG icons
// AppKit loads the five SVG assets directly. The same loader, tint, cache,
// and 24-unit layout apply to every SVG widget.
enum SVGIcon {
    enum Name: String {
        case battery, audio, bluetooth, mic, wifi, power, moon
        case nightDay = "Night-Day"
        case night = "night"            // the night-shift moon (Material bedtime_off, filled)
        case nightOff = "night-off"     // the slashed moon — shown when Night Shift is fully off
        case restart                    // Material refresh — the Restart chip
        case sleep                      // Material bedtime (filled) — the Sleep chip
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

    private static func image(_ name: Name, color: NSColor, lineWeight: CGFloat? = nil) -> NSImage? {
        guard let tint = hex(color) else { return nil }
        let key = name.rawValue + tint + (lineWeight.map { String(format: "%.2f", $0) } ?? "")
        if let cached = cache[key] { return cached }
        var svg = try? String(contentsOf: assetDirectory.appendingPathComponent(name.rawValue + ".svg"),
                              encoding: .utf8)
        // stroke: by default, weight-matched compensation (rescaled glyphs keep
        // one final weight); lineWeight overrides it directly, in grid units —
        // for glyphs that must read heavier/lighter than the house 1.5.
        var stroke: CGFloat?
        if let lw = lineWeight {
            stroke = lw
        } else if let b = ink[name] {
            let f = optical / max(b.width, b.height)
            if abs(f - 1) > 0.001 { stroke = 1.5 / f }
        }
        if let stroke {
            svg = svg?.replacingOccurrences(of: "stroke-width=\"1.5\"",
                                            with: String(format: "stroke-width=\"%.3f\"", stroke))
        }
        guard let svg, let data = svg
            .replacingOccurrences(of: "#e3e3e3", with: tint)
            .data(using: .utf8),
              let image = NSImage(data: data) else { return nil }
        cache[key] = image
        return image
    }

    // heroicons share a stroke weight, not a footprint: each glyph's ink
    // (bounds measured off the rendered paths, stroke included) sits on a
    // different piece of the 24 grid — battery squat, mic tall — so drawing
    // on the raw grid gave every widget its own optical
    // size. each ink is scaled to one OPTICAL max-dimension and pinned by
    // its ink-center to the slot's center instead. the per-icon scale costs
    // a few % of stroke weight between glyphs — the trade for even sizes.
    private static let ink: [Name: CGRect] = [
        .battery:   CGRect(x: 0.75, y: 6.75, width: 22.5, height: 12),
        .audio:     CGRect(x: 3.0,  y: 3.0,  width: 18.0, height: 18.0),  // material: headphones
        .bluetooth: CGRect(x: 5.0,  y: 2.0,  width: 12.7, height: 20.0),  // material: rune
        .mic:       CGRect(x: 5.0,  y: 3.0,  width: 14.0, height: 19.0),  // material: capsule + stand
        .wifi:      CGRect(x: 0.0,  y: 3.0,  width: 24.0, height: 17.0),  // material: two wedges + dot
        .power:     CGRect(x: 3,    y: 3,    width: 18,   height: 18),
        .restart:   CGRect(x: 2.51, y: 2.5,  width: 18.98, height: 18.5),  // material: refresh
        .sleep:     CGRect(x: 2.0,  y: 2.02, width: 18.66, height: 19.98), // material: bedtime (filled)
    ]
    static let optical: CGFloat = 21   // ink target (longest side), 24-grid units

    // where the glyph's 24-unit grid lands in the slot: ink scaled to
    // `optical`, ink-center on the slot center. anything that must align
    // with a glyph (the battery's charge fill) maps its grid coords through
    // this frame — glyph and overlay can never disagree.
    static func frame(_ name: Name, in slot: NSRect, optical target: CGFloat? = nil) -> NSRect {
        let k: CGFloat, c: CGPoint
        if let b = ink[name] {
            k = Theme.iconSize / 24 * ((target ?? optical) / max(b.width, b.height))
            c = CGPoint(x: b.midX, y: b.midY)
        } else {
            k = Theme.iconSize / 24          // unfitted (material) glyphs fill the grid
            c = CGPoint(x: 12, y: 12)
        }
        return NSRect(x: slot.midX - c.x * k, y: slot.midY - c.y * k,
                      width: 24 * k, height: 24 * k)
    }

    // ink-AREA normalization: the glyph's bounding box covers exactly
    // `area` rendered points² regardless of aspect — equal mass, equal
    // presence, one rule. centered on the ink like everything else.
    static func frame(_ name: Name, in slot: NSRect, inkArea area: CGFloat) -> NSRect {
        guard let b = ink[name] else { return frame(name, in: slot) }
        let k = (area / (b.width * b.height)).squareRoot()
        let c = CGPoint(x: b.midX, y: b.midY)
        return NSRect(x: slot.midX - c.x * k, y: slot.midY - c.y * k,
                      width: 24 * k, height: 24 * k)
    }

    static func draw(_ name: Name, color: NSColor, in slot: NSRect,
                     optical target: CGFloat? = nil) {
        draw(name, color: color, inRect: frame(name, in: slot, optical: target))
    }

    static func draw(_ name: Name, color: NSColor, in slot: NSRect, inkArea area: CGFloat) {
        draw(name, color: color, inRect: frame(name, in: slot, inkArea: area))
    }

    // a rect in the glyph's 24 grid, through its fitted frame
    static func gridRect(_ r: CGRect, for name: Name, in slot: NSRect) -> NSRect {
        let f = frame(name, in: slot)
        let s = f.width / 24
        return NSRect(x: f.minX + r.minX * s, y: f.minY + r.minY * s,
                      width: r.width * s, height: r.height * s)
    }

    static func draw(_ name: Name, color: NSColor, inRect rect: NSRect,
                     fraction: CGFloat = 1, stretch: Bool = false, lineWeight: CGFloat? = nil) {
        // stretch: map the full 24 grid onto the rect as-is (non-uniform —
        // for the bolt's taller-than-body frame); default aspect-fits
        image(name, color: color, lineWeight: lineWeight)?.draw(in: rect,
                                        from: stretch ? CGRect(x: 0, y: 0, width: 24, height: 24) : .zero,
                                        operation: .sourceOver, fraction: fraction,
                                        respectFlipped: true, hints: nil)
    }
}

// MARK: - the charge bolt (SF Symbols bolt.fill)
//
// the bolt is the system's own bolt.fill symbol, resolved at runtime — no
// glyph is embedded. it renders in two layers built from the symbol's
// alpha silhouette: a DILATED copy in the glass color under the fill (the
// dilation is the outside border), and the silhouette itself in the
// knob ink on top — the darker head both sliders share. built once per
// tint, cached.
enum ChargeBolt {
    static let border = NSColor(srgbRed: 0xFA/255.0, green: 0xF6/255.0, blue: 0xF3/255.0, alpha: 1)  // the default halo — the pill's glass — the border must vanish into its surface
    private static let scale: CGFloat = 4                   // silhouette build scale (retina-crisp)
    private static let borderPt: CGFloat = 1.25             // visible outside border
    private static var borderImgs: [String: NSImage] = [:]  // halo tinted per surface color
    private static var fillImgs: [String: NSImage] = [:]    // silhouette tinted per body color
    private static var sil: (alpha: [UInt8], w: Int, h: Int)?

    private static func hex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return "" }
        return String(format: "%02X%02X%02X",
                      Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()),
                      Int((rgb.blueComponent * 255).rounded()))
    }

    // the symbol's alpha silhouette as raw bytes (w×h, 1 byte/px), drawn
    // at `scale`× its natural point size — resolved once
    private static func getSilhouette() -> Bool {
        if sil != nil { return true }
        guard let img = NSImage(systemSymbolName: "bolt.fill",
                                accessibilityDescription: "charging") else { return false }
        let w = Int(round(img.size.width * scale))
        let h = Int(round(img.size.height * scale))
        guard w > 0, h > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero,
                 operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return false }
        let stride = rep.bytesPerRow
        var alpha = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w { alpha[y * w + x] = data[y * stride + x * 4 + 3] }
        }
        sil = (alpha, w, h)
        return true
    }

    // exact euclidean distance transform (Felzenszwalb–Huttenlocher), 1D pass
    private static func edt1d(_ f: [Double]) -> [Double] {
        let n = f.count
        var d = [Double](repeating: 0, count: n)
        var v = [Int](repeating: 0, count: n)
        var z = [Double](repeating: 0, count: n + 1)
        var k = 0
        v[0] = 0; z[0] = -.infinity; z[1] = .infinity
        for q in 1..<n {
            var s = ((f[q] + Double(q * q)) - (f[v[k]] + Double(v[k] * v[k])))
                / (2 * Double(q - v[k]))
            while s <= z[k] {
                k -= 1
                s = ((f[q] + Double(q * q)) - (f[v[k]] + Double(v[k] * v[k])))
                    / (2 * Double(q - v[k]))
            }
            k += 1
            v[k] = q; z[k] = s; z[k + 1] = .infinity
        }
        k = 0
        for q in 0..<n {
            while z[k + 1] < Double(q) { k += 1 }
            let dq = Double(q) - Double(v[k])
            d[q] = dq * dq + f[v[k]]
        }
        return d
    }

    // squared distance from every pixel to the silhouette's edge
    // (alpha ≥ 128 counts as inside, distance 0), column pass then row pass
    private static func outsideDist2(_ a: [UInt8], w: Int, h: Int,
                                     pad: Int) -> (d2: [Double], W: Int, H: Int) {
        let W = w + 2 * pad, H = h + 2 * pad
        let INF = Double.greatestFiniteMagnitude / 4
        var f = [Double](repeating: INF, count: W * H)
        for y in 0..<h {
            for x in 0..<w where a[y * w + x] >= 128 {
                f[(y + pad) * W + (x + pad)] = 0
            }
        }
        var g = [Double](repeating: 0, count: W * H)
        for x in 0..<W {
            var col = [Double](repeating: 0, count: H)
            for y in 0..<H { col[y] = f[y * W + x] }
            let r = edt1d(col)
            for y in 0..<H { g[y * W + x] = r[y] }
        }
        var d2 = [Double](repeating: 0, count: W * H)
        for y in 0..<H {
            let r = edt1d(Array(g[y * W..<(y + 1) * W]))
            for x in 0..<W { d2[y * W + x] = r[x] }
        }
        return (d2, W, H)
    }

    // alpha field + color → premultiplied RGBA CGImage
    private static func cgImage(alpha: [UInt8], w: Int, h: Int, _ color: NSColor) -> CGImage? {
        let c = color.usingColorSpace(.deviceRGB)!
        let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let a = alpha[i]
            px[i * 4] = UInt8(r * 255 * Double(a) / 255.0)
            px[i * 4 + 1] = UInt8(g * 255 * Double(a) / 255.0)
            px[i * 4 + 2] = UInt8(b * 255 * Double(a) / 255.0)
            px[i * 4 + 3] = a
        }
        var bytes = px
        guard let provider = CGDataProvider(data: CFDataCreate(nil, &bytes, bytes.count)) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    private static func nsImage(_ cg: CGImage) -> NSImage {
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func borderImage(_ tint: NSColor) -> NSImage? {
        let key = hex(tint)
        if let img = borderImgs[key] { return img }
        if borderImgs.count > 8 { borderImgs.removeAll() }
        guard getSilhouette(), let a = sil else { return nil }
        let R = borderPt * scale
        let pad = Int(R) + 2
        let (d2, W, H) = outsideDist2(a.alpha, w: a.w, h: a.h, pad: pad)
        var ring = [UInt8](repeating: 0, count: W * H)
        for i in 0..<(W * H) {
            let v = max(0, min(1, R + 0.5 - d2[i].squareRoot()))
            ring[i] = UInt8(v * 255)
        }
        guard let cg = cgImage(alpha: ring, w: W, h: H, tint) else { return nil }
        let img = nsImage(cg)
        borderImgs[key] = img
        return img
    }

    private static func fillImage(_ color: NSColor) -> NSImage? {
        let key = hex(color)
        if let img = fillImgs[key] { return img }
        if fillImgs.count > 32 { fillImgs.removeAll() }   // the LPM fade walks ~100 tints once
        guard getSilhouette(), let a = sil,
              let cg = cgImage(alpha: a.alpha, w: a.w, h: a.h, color) else { return nil }
        let img = nsImage(cg)
        fillImgs[key] = img
        return img
    }

    // border ring under, fill over — the fill is the body's own color, so
    // what reads is the thin outside border; `alpha` crossfades the bolt.
    // `border` defaults to the pill's glass; the overlay passes its card
    // color so the halo vanishes into the dark surface instead.
    static func draw(fill color: NSColor, alpha: CGFloat, border borderColor: NSColor? = nil, in rect: NSRect) {
        let halo = borderColor ?? border
        guard alpha > 0.001, let haloImg = borderImage(halo) else { return }
        // the border bitmap carries pad px of margin, mapping to pad/scale
        // pt: expanded by that, its silhouette lands exactly on the rect,
        // ring hanging outside it
        let padPt = (borderPt * scale + 2) / scale
        let full = { (img: NSImage) in NSRect(origin: .zero, size: img.size) }
        haloImg.draw(in: rect.insetBy(dx: -padPt, dy: -padPt), from: full(haloImg),
                    operation: .sourceOver, fraction: alpha,
                    respectFlipped: true, hints: nil)
        if let fill = fillImage(color) {
            fill.draw(in: rect, from: full(fill), operation: .sourceOver,
                      fraction: alpha, respectFlipped: true, hints: nil)
        }
    }
}

// truncate to fit — the panel rows' one-line names can't overflow their
// column, so they shed their tail under an ellipsis like a native menu does
func ellipsize(_ s: String, font: NSFont, width: CGFloat) -> String {
    guard s.size(withAttributes: [.font: font]).width > width else { return s }
    var t = s
    while t.count > 1, (t + "…").size(withAttributes: [.font: font]).width > width {
        t.removeLast()
    }
    return t + "…"
}

// text centered on its ink — CoreText glyph bounds, not the line box
func drawText(_ s: String, font: NSFont, color: NSColor, in r: NSRect, kern: CGFloat = 0,
              align: NSTextAlignment = .center) {
    let line = CTLineCreateWithAttributedString(NSAttributedString(
        string: s, attributes: [.font: font, .foregroundColor: color, .kern: kern]))
    let inkBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    // the anchor x: center (default) pins the ink's middle to the slot's
    // middle; left/right pin the ink's edge to the slot's edge — so rows
    // can fill the card from its pad instead of floating centered
    let ax: CGFloat
    switch align {
    case .left: ax = r.minX + inkBounds.width / 2
    case .right: ax = r.maxX - inkBounds.width / 2
    default: ax = r.midX
    }
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    ctx.translateBy(x: ax, y: r.midY)   // to the ink anchor…
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

// MARK: - night shift
//
// one framework up, same trick: CBBlueLightClient is the class the Night
// Shift pane itself uses. no headers, so every call is a probed selector
// and every struct buffer is OVERSIZED (a too-small one lets the framework
// write past it and corrupt the heap — that cost us a crash loop once).
//
// two hard-won facts about the system:
//   1. the applied warmth is its own layer — switching the schedule off
//      does NOT re-evaluate the color on screen. OFF must also pin the
//      applied CCT to neutral (6000K) by hand.
//   2. the client caches the schedule and only refreshes it via
//      notifications we never enable — a long-lived instance reads STALE.
//      so every call builds a fresh client. stateless, always current.
enum NightShift {
    private static func client() -> NSObject? {
        (NSClassFromString("CBBlueLightClient") as? NSObject.Type)?.init()
    }

    static var available: Bool {
        guard let c = client() else { return false }
        return c.responds(to: NSSelectorFromString("setStrength:commit:"))
            && c.responds(to: NSSelectorFromString("getStrength:"))
    }

    // live applied strength, 0–1 (0 when not warming or off)
    static func get() -> Float {
        typealias Fn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Float>) -> Bool
        let sel = NSSelectorFromString("getStrength:")
        guard let c = client(), c.responds(to: sel) else { return 0 }
        var v: Float = 0
        _ = unsafeBitCast(c.method(for: sel), to: Fn.self)(c, sel, &v)
        return v
    }

    // the schedule mode the Night Shift pane offers: 0 = Off, 1 = Custom,
    // 2 = Sunset to Sunrise. schedule field sits at byte 4 of the status
    // struct; the struct itself is bigger than we name — give the write
    // 256 bytes of room so it can never walk past the buffer.
    static func mode() -> UInt32 {
        typealias Fn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
        let sel = NSSelectorFromString("getBlueLightStatus:")
        guard let c = client(), c.responds(to: sel) else { return 0 }
        var buf = [UInt32](repeating: 0, count: 64)
        _ = unsafeBitCast(c.method(for: sel), to: Fn.self)(c, sel, &buf)
        return buf[1]
    }

    static func isOff() -> Bool { mode() == 0 }

    static func setMode(_ m: UInt32) {
        typealias Fn = @convention(c) (AnyObject, Selector, Int) -> Void
        let sel = NSSelectorFromString("setMode:")
        guard let c = client(), c.responds(to: sel) else { return }
        unsafeBitCast(c.method(for: sel), to: Fn.self)(c, sel, Int(m))
    }

    // pin the applied layer to daylight — the write OFF needs besides the
    // schedule switch (see note 1 above)
    static func pinNeutral() {
        typealias Fn = @convention(c) (AnyObject, Selector, Float, Bool) -> Void
        let sel = NSSelectorFromString("setCCT:commit:")
        guard let c = client(), c.responds(to: sel) else { return }
        unsafeBitCast(c.method(for: sel), to: Fn.self)(c, sel, 6000, true)
    }

    // the schedule the slider remembers while OFF, so a drag back up
    // re-arms exactly what the user had (default: sunset → sunrise)
    static var lastSchedule: UInt32 = 2

    // the one write the slider uses, both directions:
    //   v == 0  → schedule Off + applied color pinned to daylight
    //   v  > 0  → re-arm the remembered schedule if it's off, then strength
    static func set(_ value: Float) {
        let v = max(0, min(1, value))
        if v <= 0 {
            let m = mode()
            if m != 0 { lastSchedule = m; setMode(0) }
            pinNeutral()
            return
        }
        if mode() == 0 { setMode(lastSchedule) }

        typealias Fn = @convention(c) (AnyObject, Selector, Float, Bool) -> Void
        let sel = NSSelectorFromString("setStrength:commit:")
        guard let c = client(), c.responds(to: sel) else { return }
        unsafeBitCast(c.method(for: sel), to: Fn.self)(c, sel, v, true)
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

// push, not poll: plug/unplug, low power mode and charge-level changes
// invalidate the battery cache the moment they land — the 10s widget tick
// never has to be the thing that notices.
func invalidateBatteryState() {
    batteryCache = nil
    DispatchQueue.main.async {
        tab.needsDisplay = true
        if overlayShown { overlayView.needsDisplay = true }
    }
}

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

// the battery's ESTIMATES + power source — from AppleSmartBattery, the raw
// SMC data (IOPS's public dict carries no time-to-full). ioreg is a
// subprocess, so this is cached 5s and must NEVER ride the tooltip's
// repaint rate. minutes; 65535 is the SMC's "unknown" sentinel.
struct BatteryDetail {
    var ac: Bool          // ExternalConnected — AC vs battery power
    var charging: Bool    // IsCharging — current actually flowing
    var toFull: Int       // AvgTimeToFull, minutes
    var toEmpty: Int      // TimeRemaining, minutes
}

var batteryDetailCache: (result: BatteryDetail?, stamp: CFTimeInterval)?

func batteryDetail() -> BatteryDetail? {
    let now = CACurrentMediaTime()
    if let c = batteryDetailCache, now - c.stamp < 5 { return c.result }
    let result = readBatteryDetail()
    batteryDetailCache = (result, now)
    return result
}

func readBatteryDetail() -> BatteryDetail? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
    p.arguments = ["-r", "-c", "AppleSmartBattery", "-a"]   // archive as a plist
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0,
          let arr = try? PropertyListSerialization.propertyList(
              from: data, options: [], format: nil) as? [[String: Any]],
          let d = arr.first(where: { $0["BatteryData"] != nil }) ?? arr.first else { return nil }
    let unknown = { (v: Any?) in
        if let i = v as? Int { return i <= 0 || i >= 65535 }   // 0/65535 = no estimate
        return true
    }
    return BatteryDetail(
        ac: (d["ExternalConnected"] as? Bool) ?? false,
        charging: (d["IsCharging"] as? Bool) ?? false,
        toFull: unknown(d["AvgTimeToFull"]) ? 0 : (d["AvgTimeToFull"] as? Int ?? 0),
        toEmpty: unknown(d["TimeRemaining"]) ? 0 : (d["TimeRemaining"] as? Int ?? 0))
}

// the battery — heroicons' outline battery (24 grid: body x 1.5..21,
// y 7.5..18, r 2.25, nub beyond) with the charge fill drawn INSIDE the
// stroke. the outline reads at every level; the fill runs from the left
// edge under it, so the empty side is pure stroke, the full side is fill
// edge to edge.
enum Battery {
    // the fill clips to the outline's OWN rect (path at x 1.5..21,
    // y 7.5..18, r 2.25, in the svg's 24 grid) — tucking UNDER the stroke,
    // which draws on top. an inset clip here leaves a hairline antialiasing
    // seam where the fill edge meets the stroke edge; under the stroke
    // there is no seam.
    static let bodyRect = CGRect(x: 1.5, y: 7.5, width: 19.5, height: 10.5)
    static let bodyRadius: CGFloat = 2.25

    static func draw(pct: Int, boltAlpha: CGFloat,
                     fillFrom: NSColor, fillTo: NSColor, fillBlend: CGFloat,
                     in slot: NSRect) {
        let f = CGFloat(max(0, min(100, pct))) / 100
        // the icon itself is STATIC on hover — no fade, no wash. hover
        // belongs to the tooltip (drawn at the tab level, see
        // drawBatteryTooltip). the only crossfades here are the LPM fill
        // color and the plug/unplug bolt.
        let fillColor = lerp(fillFrom, fillTo, fillBlend)

        // the glyph's fitted frame decides placement — fill and shell map
        // through the same transform, so they can never disagree
        let frame = SVGIcon.frame(.battery, in: slot)
        let s = frame.width / 24

        // the charge first: the body's interior as the clip, filled from
        // the left edge → f, then the shell stroke drawn ON TOP — crisp at
        // every level, never painted over by the fill
        if f > 0 {
            let context = NSGraphicsContext.current!.cgContext
            context.saveGState()
            context.translateBy(x: frame.minX, y: frame.minY)
            context.scaleBy(x: s, y: s)
            NSBezierPath(roundedRect: bodyRect,
                         xRadius: bodyRadius, yRadius: bodyRadius).addClip()
            if fillBlend < 1 {
                fillFrom.withAlphaComponent(1 - fillBlend).setFill()
                NSRect(x: bodyRect.minX, y: bodyRect.minY,
                       width: bodyRect.width * f, height: bodyRect.height).fill()
            }
            fillTo.withAlphaComponent(fillBlend).setFill()
            NSRect(x: bodyRect.minX, y: bodyRect.minY,
                   width: bodyRect.width * f, height: bodyRect.height).fill()
            context.restoreGState()
        }
        SVGIcon.draw(.battery, color: fillColor, inRect: frame)

        // the charge bolt: the system's own bolt.fill symbol (ChargeBolt),
        // breaking the body's top and bottom edges — outside border under,
        // fill on top. crossfaded on plug/unplug while the glass is up.
        // the bolt reads in the KNOB ink — the head both sliders share —
        // one darker step than either fill, normal and LPM alike.
        let boltInk = boltAlpha
        if boltInk > 0.001 {
            let w = 13.3 * s, h = 19 * s
            let boltRect = NSRect(x: frame.minX + bodyRect.midX * s - w / 2,
                                  y: frame.minY + bodyRect.midY * s - h / 2,
                                  width: w, height: h)
            ChargeBolt.draw(fill: Theme.knob, alpha: boltInk, in: boltRect)
        }
    }
}

func drawBattery(in slot: NSRect) {
    let real = batteryLevel()
    let lpm = ProcessInfo.processInfo.isLowPowerModeEnabled
    let charging = real?.charging ?? false
    guard let pct = real?.pct else { return }   // no power source: nothing to draw

    // first draw: adopt the real state as-is — no fade-in at launch
    if !batteryStateInit {
        batteryStateInit = true
        batteryShown = (charging: charging, lpm: lpm)
        boltAlpha = charging ? 1 : 0
        fillFrom = batteryFillColor(lpm); fillTo = fillFrom; fillBlend = 1
    } else {
        // plug/unplug: crossfade the bolt
        if charging != batteryShown.charging {
            batteryShown.charging = charging
            boltSpring.start()
        }
        // low power mode: crossfade the fill color (re-target mid-fade from
        // the currently drawn blend, so fast toggles never jump)
        if lpm != batteryShown.lpm {
            fillFrom = lerp(fillFrom, fillTo, fillBlend)
            fillTo = batteryFillColor(lpm)
            fillBlend = 0
            batteryShown.lpm = lpm
            fillSpring.start()
        }
    }
    boltSpring.start()

    Battery.draw(pct: pct, boltAlpha: boltAlpha,
                 fillFrom: fillFrom, fillTo: fillTo, fillBlend: fillBlend, in: slot)
}

// heroicons, one 24 grid — audio (out), bluetooth, mic (in), wifi (arcs).
// the trio rides its collective quiet capsule (see draw), so each glyph draws at
// track scale — the slot inset to the track's own 24pt footprint — and
// in the knob family's ink, so it reads inside the 30% quiet run.
private func drawTrio(_ name: SVGIcon.Name, in slot: NSRect, ink: NSColor) {
    // the knob faces' own box (sliderHandle − 6), at ONE scale for all four —
    // same library, same grid, the glyphs arrive pre-balanced
    let s = (Theme.sliderHandle - 6) * (Theme.trioScale[name.rawValue] ?? 1)
    SVGIcon.draw(name, color: ink,
                 inRect: NSRect(x: slot.midX - s / 2, y: slot.midY - s / 2,
                                width: s, height: s),
                 lineWeight: 1.4)
}

func drawAudio(in slot: NSRect, ink: NSColor) {
    drawTrio(.audio, in: slot, ink: ink)
}

func drawBluetooth(in slot: NSRect, ink: NSColor) {
    drawTrio(.bluetooth, in: slot, ink: ink)
}

// heroicon power — the destructive action gets a BODY, not another outline
// label: a dark disc from the slider's knob family with the glyph knocked
// out in white. under the cursor it answers exactly like the knob above it:
// the disc swells ~8% and its color crossfades knob → sliderFill, while the
// face plays the knob's own implode/explode crossfade — the power glyph
// collapses into the disc's center and the MOON grows out of it, previewing
// what the click does (sleep). everything rides the one powerHover blend.
func drawPower(in slot: NSRect) {
    let h = max(0, min(1, Theme.powerHover))

    // disc: swells under the cursor; color crossfades knob → sliderFill
    let d = (Theme.slotWidth - 4) * (1 + 0.08 * h)
    let disc = NSRect(x: slot.midX - d / 2, y: slot.midY - d / 2,
                      width: d, height: d)
    lerp(Theme.knob, Theme.sliderFill, h).setFill()
    NSBezierPath(ovalIn: disc).fill()

    // the face: implode/explode — outgoing glyph collapses into the center
    // while the incoming one grows out of it; scale carries the motion,
    // alpha only cleans up the sub-pixel ends
    let base = d * 0.68
    let edgeAlpha: (CGFloat) -> CGFloat = { min(1, $0 * 4) }
    if h < 1 {
        let f = 1 - h
        let g = base * f
        SVGIcon.draw(.power, color: .white,
                     inRect: NSRect(x: disc.midX - g / 2, y: disc.midY - g / 2,
                                    width: g, height: g),
                     fraction: edgeAlpha(f))
    }
    if h > 0 {
        let g = base * h
        SVGIcon.draw(.moon, color: .white,
                     inRect: NSRect(x: disc.midX - g / 2, y: disc.midY - g / 2,
                                    width: g, height: g),
                     fraction: edgeAlpha(h))
    }
}

// the power button: system sleep — the same path `pmset sleepnow` walks,
// user-level (no permissions), the machine's own sleep rules apply
// run a command, true iff it launched and exited 0
func runCmd(_ launchPath: String, _ args: [String]) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    p.standardOutput = Pipe(); p.standardError = Pipe()
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

// Low Power Mode toggle — the battery click. pmset is the only lever, and
// it demands root, so the rungs climb from silent to one-time-loud:
//   1. passwordless sudo — instant, forever (the scoped sudoers rule)
//   2. if the rule is missing, INSTALL IT — the one-time admin prompt here
//      is the LAST password this toggle ever asks for (self-healing: no
//      separate setup script, no install.sh run needed). validated with
//      visudo before it lands, scoped to the two pmset commands only.
//   3. fallback: one-off admin prompt for the pmset call itself
func setLowPowerMode(_ on: Bool) {
    let n = on ? "1" : "0"
    if runCmd("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "lowpowermode", n]) { return }
    let ruleFile = "/etc/sudoers.d/smalt-lpm"
    if !FileManager.default.fileExists(atPath: ruleFile) {
        // the rule: exactly two pmset commands, nothing else passwordless
        let rule = "\(NSUserName()) ALL=(root) NOPASSWD: /usr/bin/pmset -a lowpowermode 0, /usr/bin/pmset -a lowpowermode 1"
        let setup = "echo '\(rule)' > \(ruleFile).tmp && chmod 440 \(ruleFile).tmp && "
            + "/usr/sbin/visudo -cf \(ruleFile).tmp && mv \(ruleFile).tmp \(ruleFile)"
        _ = runCmd("/usr/bin/osascript",
               ["-e", "do shell script \"\(setup)\" with administrator privileges"])
        // rule installed? the toggle itself is now silent — go to rung 1
        if runCmd("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "lowpowermode", n]) { return }
    }
    _ = runCmd("/usr/bin/osascript",
           ["-e", "do shell script \"/usr/bin/pmset -a lowpowermode \(n)\" with administrator privileges"])
}

func sleepSystem() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["sleepnow"]
    try? p.run()
}

func drawMicrophone(in slot: NSRect, ink: NSColor) {
    drawTrio(.mic, in: slot, ink: ink)
}

func drawWifi(in slot: NSRect, ink: NSColor) {
    drawTrio(.wifi, in: slot, ink: ink)
}

// time: hour over minute — one CELL slot each, tabular SF Pro centered
// the clock: hour over minute — one CELL slot each, SF Mono digits centered,
// in the trio ink, flat — the clock doesn't react to hover.
func drawClock(_ component: Calendar.Component, in slot: NSRect) {
    let value = String(format: "%02d", Calendar.current.component(component, from: Date()))
    drawText(value, font: NSFont.monospacedSystemFont(ofSize: Theme.typeSize, weight: .regular),
             color: Theme.trioInk, in: slot)
}

// material design 3 slider, vertical, in smalt's skin — M3's own metrics
// (4dp track, round handle) drawn with CG, but inked
// in the palette instead of M3's. one CELL slot below the time. draws the
// live Night Shift strength (CBBlueLightClient); drag writes straight to it.
// same styling the keyboard-brightness slider always wore — only the value
// it reads and writes changed.
func drawSlider(in slot: NSRect) {
    let v = max(0, min(1, Theme.sliderDisplay))
    let slotHover = max(0, min(1, Theme.sliderHover))   // whole slot: the fill tint
    let knobHover = max(0, min(1, Theme.knobHover))     // knob only: the swell
    let cx = slot.midX
    // the knob breathes: a touch bigger while the KNOB itself is hovered,
    // plus the first-hover wobble swinging both ways around that
    let knobSize = max(18, Theme.sliderHandle * (1 + 0.08 * knobHover + 0.12 * Theme.knobPop))

    // handle center travel: v=0 parks at the bottom, v=1 at the top —
    // up means more, matching updateSliderValue's drag mapping
    let yBottom = slot.maxY - knobSize / 2
    let yTop = slot.minY + knobSize / 2
    let hc = yBottom + (yTop - yBottom) * v

    // track: one thick rounded bar the full slot height. the quiet run is
    // the value color held to 30%, FIXED — the value run must stay clearly
    // darker than the empty run in every state. at 0% the value run hides
    // entirely under the knob, so hover answers on the QUIET run instead:
    // the empty track is what lights.
    let zero = v < 0.005
    let trackRect = NSRect(x: cx - Theme.sliderTrack / 2, y: slot.minY,
                           width: Theme.sliderTrack, height: slot.height)
    let stadium = NSBezierPath(roundedRect: trackRect, xRadius: Theme.sliderTrack / 2,
                               yRadius: Theme.sliderTrack / 2)
    let quiet = zero
        ? lerp(Theme.sliderFill, Theme.sliderHoverFill, slotHover)
            .withAlphaComponent(0.3 + 0.25 * slotHover)
        : Theme.sliderFill.withAlphaComponent(0.3)
    quiet.setFill()
    stadium.fill()
    // active run: FLAT-top fill from the knob's center line down. a rounded
    // top here bulges up at the center while the knob's circle bulges down —
    // two opposing arcs with air at the sides (the gap). flat meets the knob
    // exactly; 1px of overlap kills the antialiasing seam. clipped to the
    // track so the stadium silhouette survives.
    if let ctx = NSGraphicsContext.current?.cgContext {
        ctx.saveGState()
        stadium.addClip()
        // under the cursor the value run DEEPENS toward the knob (#5E463F) —
        // darker, the opposite direction from the empty run, so hover can
        // never flatten the two together
        lerp(Theme.sliderFill, Theme.sliderHoverFill, slotHover).setFill()
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

// The percentage face shrinks just enough for "100" (or "OFF") to fit inside the knob.
enum KnobFace {
    static func fit(_ s: String) -> CGFloat {
        let b: CGFloat = 12
        let wide = (s as NSString).size(withAttributes: [.font: NSFont.tabular(b, .semibold)]).width
        return wide > Theme.sliderHandle - 6 ? b * (Theme.sliderHandle - 6) / wide : b
    }
    static let base = fit("100")
    static let off = fit("OFF")
}

// the night-shift slider — drawSlider's twin with warm ink and a moon
// face: the value run is lamp amber (the ink of the thing it controls),
// the knob stays in the knob family, and the face crossfades moon ⇄ %.
// the knob swells and wobbles like the brightness knob — one
// KnobHoverMachine per slider, the same theater in the same place.
func drawNightSlider(in slot: NSRect) {
    let v = max(0, min(1, Theme.nightDisplay))
    let slotHover = max(0, min(1, Theme.nightHover))   // whole slot: the fill tint
    let knobHover = max(0, min(1, Theme.nightKnobHover))  // knob only: the swell
    let cx = slot.midX
    // the knob breathes: a touch bigger while the KNOB itself is hovered,
    // plus the first-hover wobble swinging both ways around that —
    // drawSlider's own arithmetic, same constants
    let knobSize = max(18, Theme.sliderHandle * (1 + 0.08 * knobHover + 0.12 * Theme.nightKnobPop))

    // handle center travel: v=0 (shallow/off) parks at the bottom, v=1
    // (intensive) at the top — up means more, matching the drag mapping
    let yBottom = slot.maxY - knobSize / 2
    let yTop = slot.minY + knobSize / 2
    let hc = yBottom + (yTop - yBottom) * v

    // track: same stadium, quiet run the night color held to 30% — and
    // the same 0% rule: no visible value run means hover lights the quiet
    // run instead.
    let zero = v < 0.005
    let trackRect = NSRect(x: cx - Theme.sliderTrack / 2, y: slot.minY,
                           width: Theme.sliderTrack, height: slot.height)
    let stadium = NSBezierPath(roundedRect: trackRect, xRadius: Theme.sliderTrack / 2,
                               yRadius: Theme.sliderTrack / 2)
    let quiet = zero
        ? lerp(Theme.nightFill, Theme.nightHoverFill, slotHover)
            .withAlphaComponent(0.3 + 0.25 * slotHover)
        : Theme.nightFill.withAlphaComponent(0.3)
    quiet.setFill()
    stadium.fill()
    // active run: FLAT-top fill from the knob's center line down, clipped
    // to the track — same geometry, warm ink; hover deepens it one step
    if let ctx = NSGraphicsContext.current?.cgContext {
        ctx.saveGState()
        stadium.addClip()
        lerp(Theme.nightFill, Theme.nightHoverFill, slotHover).setFill()
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

    // the face: moon ⇄ %/OFF, same implode/explode as the brightness knob.
    // OFF is its own state — the schedule is off, not "0%"
    let face = max(0, min(1, Theme.nightFace))
    let edgeAlpha: (CGFloat) -> CGFloat = { min(1, $0 * 4) }
    let pct = Int((Theme.nightValue * 100).rounded())

    if face > 0 {
        if Theme.nightOff {
            drawText("OFF", font: .tabular(KnobFace.off * face, .semibold),
                     color: Theme.glass.withAlphaComponent(edgeAlpha(face)), in: handle)
        } else {
            drawText("\(pct)", font: .tabular(KnobFace.base * face, .semibold),
                     color: Theme.glass.withAlphaComponent(edgeAlpha(face)), in: handle)
        }
    }

    if face < 1 {
        let f = 1 - face
        let size = (knobSize - 6) * f
        // the face glyph follows the schedule: the night moon while it runs,
        // the slashed moon when the schedule is fully off
        SVGIcon.draw(Theme.nightOff ? .nightOff : .night, color: Theme.glass,
                     inRect: NSRect(x: handle.midX - size / 2,
                                    y: handle.midY - size / 2,
                                    width: size, height: size),
                     fraction: edgeAlpha(f))
    }
}

// MARK: - state

// stderr debug tracing — off unless built with -D SMALT_DEBUG (stderr → /tmp/smalt.err)
func dbg(_ s: String) {
#if SMALT_DEBUG
    FileHandle.standardError.write(Data((s + "\n").utf8))
#endif
}

var stripVisible = false       // hidden until the cursor hovers the right edge

// the slider's state IS the hardware: Night Shift's live strength — the
// styling is the original slider's, the value it drives is Night Shift's
if NightShift.available {
    Theme.nightOff = NightShift.isOff()
    let ns = Theme.nightOff ? CGFloat(0) : CGFloat(NightShift.get())
    Theme.sliderValue = ns
    Theme.sliderDisplay = ns
    let m = NightShift.mode()
    if m != 0 { NightShift.lastSchedule = m }   // remember what's armed, for the re-arm on drag-up
} else {
    dbg("night shift: CBBlueLightClient unavailable — slider is visual-only")
}
var evalItem: DispatchWorkItem?
var pendingRelease = false     // key-drop deferred until the exit spring parks the glass

func mainScreen() -> NSScreen? {
    // the CG main display — cursor global coordinates are relative to THIS
    // screen's arrangement, so the pill must anchor to the same one.
    NSScreen.screens.first { displayID($0) == CGMainDisplayID() } ?? NSScreen.main
}

// the window's frame: the glass's frame plus vertical shadow slack (the
// glass itself keeps pillFrame — the cursor bands are derived from it)
func stripWindowFrame() -> NSRect {
    var f = pillFrame()
    f.origin.y -= SHADOW_SLACK
    f.size.height += 2 * SHADOW_SLACK
    return f
}

// where the WINDOW lives: docked, permanently, from launch. the cursor
// always lands on smalt at the screen edge — chrome's `<>` border never
// gets it. the window extends TAB_TRAVEL + TAB_MARGIN past the screen
// edge; that off-screen slack is where the hidden glass parks.
func pillFrame() -> NSRect {
    guard let screen = mainScreen() else { return .zero }
    let f = screen.frame
    let w = PILL_WIDTH + 2 * TAB_MARGIN + TAB_TRAVEL
    return NSRect(x: f.maxX - PILL_INSET - TAB_MARGIN - PILL_WIDTH, y: f.minY + (f.height - PILL_HEIGHT) / 2,
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

    // what the spring moves, and where it reads its current position —
    // injected, so one driver class serves every animated surface (the
    // glass tab, the extension's subview). the value still lives at the
    // call site; the driver only integrates.
    private let apply: (CGFloat) -> Void
    private let read: () -> CGFloat

    init(apply: @escaping (CGFloat) -> Void, read: @escaping () -> CGFloat) {
        self.apply = apply
        self.read = read
        super.init()
    }

    var onSettle: (() -> Void)?

    func chase(_ targetX: CGFloat, initialVelocity: CGFloat = 0) {
        target = targetX
        guard !running else { return }             // already chasing — just retargeted
        x = read()
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
        apply(x.rounded())                         // whole pixels: no subpixel shimmer on the glass
        if abs(x - target) < 0.25, abs(v) < 2 {
            apply(target)
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

let spring = SpringDriver(apply: { setGlassX($0) }, read: { tab.frame.origin.x })

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
    if desired { extSpring.onSettle = nil }   // a re-summon cancels any arm-first handoff
    if desired { strip.orderFrontRegardless() }   // back on stage before the glass moves
    if !animate {
        if !desired { closeExtension(instant: true) }   // the arm never outlives the bar
        setGlassX(glassX(docked: desired))
        if !desired { flushPendingRelease() }   // parked instantly — release now
        return
    }
    if !desired, extShown || extSpring.running {
        // the arm retracts INTO the bar first; the bar leaves only once the
        // arm is glass again — an open arm must never be caught mid-air while
        // the bar slides away beneath it (that was the double-collapse)
        closeExtension()
        extSpring.onSettle = {
            guard !extShown else { return }       // re-opened mid-retract
            setStripExtensionSlack(0)             // hand the window's width back
            guard !stripVisible else { return }   // re-summoned mid-retract
            spring.chase(glassX(docked: false), initialVelocity: 0)
            spring.onSettle = { flushPendingRelease() }
        }
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
    // the extension's domain: while it's open (or about to be), the arm and
    // the pill column within its band are smalt's — the cursor crossing between
    // rune and arm must read as "still here", never as "left the pill"
    if extShown || extShowTimer != nil {
        let g = extBandCG(extAnchor)
        if y >= g.top - HIDE_BAND, y <= g.bottom + HIDE_BAND, xr <= g.left + HIDE_MARGIN { return true }
    }
    if xr > PILL_INSET + PILL_WIDTH + HIDE_MARGIN || y > bottom + HIDE_BAND || y < top - HIDE_BAND { return false }
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
    // HOLD key while visibility is wanted, including the first poll after a
    // summon. At that point the tab is still at its hidden x, so position
    // alone cannot distinguish "about to open" from "finished closing".
    // The old position-only check therefore called flushPendingRelease(),
    // ordered the window out underneath the entrance spring, and left
    // stripVisible=true with an off-stage window. Subsequent polls then
    // alternated makeKey/orderOut and produced the visible oscillation.
    //
    // Once visibility is false, keep the panel key until the exit spring is
    // actually parked; dropping key earlier also orders the window out and
    // cuts the animation off. The settle callback performs the one release.
    if stripVisible || tab.frame.origin.x < glassX(docked: false) - 1 {
        pendingRelease = true
        return
    }
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
        hideOverlay()                         // the overlay never sits on the login screen
        if PILL_ENABLED {
            spring.stop()
            tab.dragSlot = nil                // a lock mid-drag kills the drag —
                                              // otherwise dragSlot pins the glass open forever
            closeExtension(instant: true)     // gone from the lock screen entirely
            applyVisibility(false, animate: false)   // park instantly — no spring on the way out
            releaseAttention()                // drop any key/focus claim
            strip.orderOut(nil)               // gone from the lock screen entirely
        }
    } else {
        if PILL_ENABLED {
            strip.orderFrontRegardless()      // back on every space
            scheduleUpdate()                  // re-derive hover state from the live cursor
        }
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

let tab = StripView(frame: NSRect(origin: NSPoint(x: 0, y: SHADOW_SLACK), size: NSSize(width: PILL_WIDTH, height: PILL_HEIGHT)))

// where the glass sits inside the window: docked (flush at the screen edge
// with TAB_MARGIN of overshoot slack to its left, plus the extension's slack
// while an arm is out) vs hidden (past the edge). extSlack slides the whole
// coordinate system so the tab holds its screen position while the window is
// widened for the arm (see setStripExtensionSlack).
func glassX(docked: Bool) -> CGFloat { TAB_MARGIN + extSlack + (docked ? 0 : TAB_TRAVEL) }

// move the glass: origin only. the tab's size never changes, and setting it
// anyway invalidated tracking areas (a full rebuild) on every spring tick.
func setGlassX(_ x: CGFloat) {
    let old = tab.frame
    tab.setFrameOrigin(NSPoint(x: x, y: old.origin.y))
    // the shadow spills 7pt past the tab's bounds — the spill bands ride along,
    // so old AND new positions get their bands marked, not just the frames
    tab.needsDisplay = true
    tab.superview?.setNeedsDisplay(
        old.insetBy(dx: -8, dy: -8).union(tab.frame.insetBy(dx: -8, dy: -8)))
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
    let frame = stripWindowFrame()
    let win = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    win.backgroundColor = .clear
    win.isOpaque = false
    win.hasShadow = false   // the real shadow re-blurs the whole window on EVERY content
                            // change — at 120fps that was the unusable lag. the strip
                            // draws its own shadow as content instead (see StripView.draw)
    win.ignoresMouseEvents = false
    win.level = NSWindow.Level(rawValue: 21)
    win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
    container.addSubview(tab)
    win.contentView = container
    return win
}()


// MARK: - the battery tooltip (a portal, not a painting)
//
// the number rides in its OWN borderless window, layered above the strip —
// the glass can't clip what isn't inside it. it's a CHILD of the strip
// window (slides along when the glass moves, ordered out when the strip
// parks), fades on the batteryHover blend (~50ms — soft cut, not theater),
// and ignores every mouse event — pure display, nothing to intercept.

final class TooltipCapsuleView: NSView {
    var text = ""
    var font = NSFont.tabular(13, .semibold)
    // flipped: drawText un-flips for CoreText assuming y-down (the tab's
    // convention). without this, the capsule's text renders upside down.
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Theme.knob.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2,
                     yRadius: bounds.height / 2).fill()
        drawText(text, font: font, color: Theme.glass, in: bounds)
    }
}

let batteryTooltipView = TooltipCapsuleView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
let batteryTooltip: OverlayPanel = {
    let win = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
    win.backgroundColor = .clear
    win.isOpaque = false
    win.hasShadow = false
    win.ignoresMouseEvents = true
    win.level = NSWindow.Level(rawValue: 22)   // one step above the strip (21)
    win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    win.contentView = batteryTooltipView
    win.alphaValue = 0
    strip.addChildWindow(win, ordered: .above)
    return win
}()

// geometry + content + alpha, all in one call — every trigger (hover
// spring, mouse monitor, poll tick, toggle wobble) funnels through here.
// STRICTLY IDEMPOTENT: this runs at 30Hz from the poll, so it may only
// touch the window server when something ACTUALLY changed — a stationary
// cursor over a settled tooltip must cost nothing at all.
// the TEXT is the percent — and, ONLY while actually charging below full,
// the SMC's own minutes-to-full: "93%" → "87% · 12m to full". the SMC
// reports fiction when the pack is full on AC (IsCharging=Yes with a stale
// estimate), so the gate is strict: charging AND pct < 100 AND a committed
// number (0/65535 = the hardware shrugging = nothing shown).
private var ttState = (text: "", x: CGFloat(-1), y: CGFloat(-1),
                       w: CGFloat(-1), ht: CGFloat(-1), alpha: CGFloat(-1))
// text measurement is a CoreText layout call and visibleFrame is a window-
// server query — neither may run per mouse EVENT (the tooltip tracks at
// event rate). both are cached; the text cache keys on the string, the
// screen geometry on a 10s stamp + screen identity.
private var ttGeom = (text: "", w: CGFloat(0), ht: CGFloat(0))
private var ttVis: (screen: NSScreen, frame: NSRect, stamp: CFTimeInterval)?

func refreshBatteryTooltip() {
    let h = max(0, min(1, Theme.batteryHover))
    guard h > 0.001, glassDocked, let win = tab.window,
          let cp = tab.cursorPoint, let real = batteryLevel() else {
        // at rest: exactly one teardown, then silence — no per-tick work
        if ttState.alpha != 0 {
            ttState.alpha = 0
            ttState.x = -1; ttState.y = -1; ttState.w = -1; ttState.ht = -1
            batteryTooltip.alphaValue = 0
            batteryTooltip.orderOut(nil)
        }
        return
    }
    var parts: [String] = ["\(real.pct)%"]
    if let d = batteryDetail(), d.charging, real.pct < 100, d.toFull > 0 {
        let hrs = d.toFull / 60, rem = d.toFull % 60
        parts.append(hrs > 0 ? "\(hrs)h \(rem)m to full" : "\(rem)m to full")
    }
    let text = parts.joined(separator: " · ")

    // the toggle wobble swells the capsule about its base — recompute the
    // capsule size ONLY when the text (or the pop) actually changed
    let font = batteryTooltipView.font
    let w0: CGFloat, ht0: CGFloat
    if text == ttGeom.text {
        (w0, ht0) = (ttGeom.w, ttGeom.ht)
    } else {
        let ts = (text as NSString).size(withAttributes: [.font: font])
        (w0, ht0) = (ts.width + 14, ts.height + 8)
        ttGeom = (text, w0, ht0)
    }
    let g = 1 + 0.14 * max(0, min(1, Theme.batteryPop))
    let w = w0 * g, ht = ht0 * g
    // rides 12pt below the cursor tip, centered on it — clamped to the
    // screen's visible frame, free to leave the glass behind
    let scr = win.convertToScreen(NSRect(origin: tab.convert(cp, to: nil), size: .zero)).origin
    let vis: NSRect
    if let c = ttVis, c.screen === win.screen, CACurrentMediaTime() - c.stamp < 10 {
        vis = c.frame
    } else {
        vis = win.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        ttVis = (win.screen!, vis, CACurrentMediaTime())
    }
    let x = min(vis.maxX - w - 6, max(vis.minX + 6, scr.x - w / 2))
    let y = scr.y - 12 - ht

    let textChanged = text != ttState.text
    let moved = abs(x - ttState.x) > 0.25 || abs(y - ttState.y) > 0.25
        || abs(w - ttState.w) > 0.25 || abs(ht - ttState.ht) > 0.25
    let alphaChanged = abs(h - ttState.alpha) > 0.004
    guard textChanged || moved || alphaChanged else { return }   // settled: NO-OP

    if moved {
        batteryTooltip.setFrame(NSRect(x: x, y: y, width: w, height: ht), display: false)
    }
    if textChanged {
        batteryTooltipView.text = text
        batteryTooltipView.needsDisplay = true
    }
    if alphaChanged {
        if !batteryTooltip.isVisible { batteryTooltip.orderFrontRegardless() }
        batteryTooltip.alphaValue = h
    }
    ttState = (text, x, y, w, ht, h)
}

// MARK: - the extensions (bluetooth · audio · mic · power)
//
// hover one of the arm anchors — the bluetooth, audio or mic rune, or the
// power button — and the strip's glass extends leftward out of the pill's own
// edge. the arm is its own SMALL view (ArmView, above the tab in z), because
// repainting the whole pill every animation frame read as ~20Hz — now only
// the arm redraws, and the tab never repaints for the arm's sake. the fusion
// is geometry: the arm's glass reaches 8pt over the pill's edge (burying the
// pill's stroke spill under opaque glass) and its shadow path has no right
// edge — no stroke ever lands on either glass, so the two surfaces read as
// one silhouette. the strip window widens leftward by one invisible step to
// make room.
//
// ONE arm serves all four anchors: switching anchors MORPHS — the open arm
// glides vertically to the newly hovered rune instead of closing and
// reopening. the arm's vertical position is clamped to the pill's straight
// band, so no anchor can ever make it extrude past the bar's top or bottom.
//
// the animation is the reveal's own spring on display links of their own:
// one integrates the ARM'S WIDTH in pixels (0 → EXT_WIDTH), retargetable
// mid-flight — the glass slides out of the pill's edge, its sliding tip
// staying round at any width; one glides the vertical anchor. the alpha fade
// is DERIVED from the width (the first 24pt of travel), so grow and fade
// cannot drift apart — one integrator, two outputs.
//
// LEGACY: the whole extension arm — the bluetooth device tray, the anchors,
// the reveal — is RETIRED. the code stays (it works; it's the platform that
// fought back), parked behind this flag. false = the arm never opens, the
// runes are just icons, the pill runs clean. flip to true to resurrect it.
let LEGACY_EXTENSION = false

let EXT_WIDTH: CGFloat = 216
let EXT_HEIGHT: CGFloat = 170
let EXT_RADIUS: CGFloat = 16
let EXT_SLACK: CGFloat = 12     // window slack past full width — spring overshoot (~5% ≈ 11pt) lands here
let EXT_SHOW_DWELL: TimeInterval = 0.12   // hover intent: brush-past never opens it
let EXT_HIDE_DWELL: TimeInterval = 0.18   // leave intent: darting between runes never closes it

enum ExtAnchor { case bluetooth, wifi, audio, mic, power }

// ── the bluetooth panel's data ──
//
// the arm over the bluetooth rune is the device tray: every paired device,
// connected first, a dot answering connected. the source is IOBluetooth's
// own paired-device table — the SAME handles the connect/disconnect calls
// go through, so what the rows show and what a click does cannot disagree
// (system_profiler, the old source, lagged and cached: it showed stale
// connected lists while the links had already moved). sampled on a side
// queue — `isConnected` is one cheap XPC round-trip — and cached: the panel
// opens on the last answer and re-samples every 5s while it's open, 2s
// while a toggle is pending. the rows answer a CLICK too (see
// toggleBtDevice); the permission is pre-warmed at daemon launch.
struct BtDevice { let name: String; let kind: String; let address: String; let connected: Bool }
var btDevices: [BtDevice] = []
var btLoading = false
var btControllerOn = true
// the paired-device handles from the last sample, keyed by the row's
// normalized address → every transport handle of that device (dual-mode
// devices pair once per transport — classic AND LE — and appear twice;
// one row per device, all its handles ride together).
var btLinks: [String: [IOBluetoothDevice]] = [:]

// macOS bakes a " (con)" suffix into pairing-record names — strip it for
// display and for grouping the transports of one physical device.
func btBaseName(_ s: String) -> String {
    s.hasSuffix(" (con)") ? String(s.dropLast(6)) : s
}
// in-flight toggles: address → (target state, expiry). a clicked row
// renders a spinner instead of its dot until a sample confirms the state —
// or the expiry gives up and the truth wins (with a "no answer" note).
var btPending: [String: (target: Bool, until: Date)] = [:]
// answered-no: address → (asked-for state, when, why). rows whose toggle
// expired without a confirmed answer carry a brief note for a few seconds.
var btFailed: [String: (target: Bool, at: Date, msg: String)] = [:]
var btSpin: CGFloat = 0            // the pending spinner's angle, 0..1 turns
var btSpinTimer: Timer?
var btProbeTimer: Timer?
var btFlash: (row: Int, at: Date)?  // the clicked row's press flash
// the toast: one line under the rows, announcing every connect/disconnect
// the tray can see — user toggles AND ambient events (a device that snaps
// straight back after a disconnect reads honestly: "disconnected", then
// "connected" a beat later). the panel glides taller to carry it.
var btToast: (msg: String, at: Date)?
var btToastTimer: Timer?
let btQueue = DispatchQueue(label: "smalt.bluetooth", qos: .utility)
var btRefreshTimer: Timer?

// the panel's metrics — arm-local flipped coords, offset from the GLASS
// top edge (local y = 8). draw and hit-test both read these, so they
// cannot drift apart.
enum BtPanel {
    static let headPad: CGFloat = 16
    static let headH: CGFloat = 12
    static let divGap: CGFloat = 10
    static let rowsGap: CGFloat = 8
    static let rowH: CGFloat = 30
    static let bottomPad: CGFloat = 12
    static let toastH: CGFloat = 20   // the toast's band, grown below the rows
    static let maxRows = 8
    static let tipPad: CGFloat = 18     // content inset from the glass tip
    static let rightPad: CGFloat = 14   // …and from the seam side
    static var rowsTop: CGFloat { headPad + headH + divGap + rowsGap }
    static func height(rows: Int) -> CGFloat {
        rowsTop + CGFloat(min(max(rows, 1), maxRows)) * rowH + bottomPad
    }
}

// the arm's height: fixed for the other anchors, derived from the
// bluetooth panel's row count for bluetooth — clamped to the pill's
// straight band so no row count can push glass past the rounded corners
var extH: CGFloat = EXT_HEIGHT
func extHeight(for anchor: ExtAnchor) -> CGFloat {
    guard anchor == .bluetooth else { return EXT_HEIGHT }
    let band = PILL_HEIGHT - 2 * PILL_RADIUS
    let base = min(BtPanel.height(rows: btDevices.count), band)
    return min(base + (btToast != nil ? BtPanel.toastH : 0), band)
}

// one sample: read IOBluetooth's paired-device table off-main — live truth,
// the same handles the toggles drive. publish on main: pending/failed
// reconciliation, transition toasts, and the height respring if the row
// count (or a toast's band) moved the panel.
func sampleBluetoothDevices() {
    guard !btLoading else { return }
    btLoading = true
    btQueue.async {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        var on = true
        if let hc = IOBluetoothHostController.default() {
            on = hc.powerState == kBluetoothHCIPowerStateON
        }
        var out: [BtDevice] = []
        var links: [String: [IOBluetoothDevice]] = [:]
        // group by base name: dual-mode devices pair once per transport and
        // would otherwise show as two rows; connected = any transport up
        var groups: [String: (handles: [IOBluetoothDevice], connected: Bool)] = [:]
        for dev in paired {
            let base = btBaseName(dev.name ?? "")
            guard !base.isEmpty, base != "." else { continue }   // anonymous LE entries
            var g = groups[base] ?? ([], false)
            g.handles.append(dev)
            if dev.isConnected() { g.connected = true }
            groups[base] = g
        }
        for (base, g) in groups {
            // the row's handle: the connected transport when there is one —
            // a disconnect must close the transport that is actually up
            let primary = g.handles.first { $0.isConnected() } ?? g.handles[0]
            links[btNormalizeAddress(primary.addressString ?? "")] = g.handles
            out.append(BtDevice(name: base,
                                kind: "",
                                address: primary.addressString ?? "",
                                connected: g.connected))
        }
        out.sort { a, b in
            if a.connected != b.connected { return a.connected }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        DispatchQueue.main.async {
            btLoading = false
            let old = btDevices
            btControllerOn = on
            btDevices = out
            btLinks = links
            // a confirmed state retires its in-flight entry; a late answer
            // clears the "no answer" note it earned
            let now = Date()
            btPending = btPending.filter { addr, p in
                guard p.until > now,
                      let d = out.first(where: { $0.address == addr }) else { return true }
                return d.connected != p.target
            }
            btFailed = btFailed.filter { addr, f in
                guard let d = out.first(where: { $0.address == addr }) else { return true }
                return d.connected != f.target && now.timeIntervalSince(f.at) < 4
            }
            // transitions → toasts: every visible connect/disconnect answers
            // the toast line, so nothing the tray does — or the world does
            // to the tray — is silent
            if extShown, extAnchor == .bluetooth, btControllerOn {
                for d in out {
                    if let o = old.first(where: { $0.address == d.address }),
                       o.connected != d.connected {
                        btShowToast("\(d.name) \(d.connected ? "connected" : "disconnected")")
                    }
                }
            }
            if extShown, extAnchor == .bluetooth {
                let h = extHeight(for: .bluetooth)
                if abs(h - extH) > 0.5 {
                    extHSpring.chase(h)
                    extYSpring.chase(extTopOffset(for: .bluetooth, height: h))
                }
                armView.needsDisplay = true
            }
        }
    }
}

// sample on open, then every 5s while the bluetooth panel is open
func startBluetoothRefresh() {
    btRefreshTimer?.invalidate()
    sampleBluetoothDevices()
    let t = Timer(timeInterval: 5, repeats: true) { _ in
        guard extShown, extAnchor == .bluetooth else {
            btRefreshTimer?.invalidate(); btRefreshTimer = nil; return
        }
        sampleBluetoothDevices()
    }
    RunLoop.main.add(t, forMode: .common)
    btRefreshTimer = t
}

// ── connect / disconnect ──
//
// the tray's rows answer a click: IOBluetooth's paired-device handles,
// matched by address (system_profiler writes "AA:BB:…", IOBluetooth writes
// "aa-bb-…" — both sides are reduced to their hex digits before comparing).
// openConnection / closeConnection are the TCC-gated calls: the FIRST toggle
// is when macOS asks for the Bluetooth permission. both are SYNCHRONOUS —
// a HID device's page can hold the caller for many seconds — so they run on
// their own queue, never the main thread (a main-thread page froze the whole
// strip solid). the row goes pending immediately: a spinner on the dot, and
// quick resamples publish the answer as soon as it exists.
func btNormalizeAddress(_ s: String) -> String {
    String(s.lowercased().filter { $0.isHexDigit }.suffix(12))
}

// the link queue — IOBluetooth's synchronous connect/disconnect, off-main
let btLinkQueue = DispatchQueue(label: "smalt.bluetooth.link", qos: .userInitiated)

func toggleBtDevice(_ d: BtDevice) {
    let target = !d.connected
    guard btPending[d.address]?.target != target else { return }   // already in flight
    // the handles come from the tray's own last sample — the row you see is
    // exactly the device the click drives, all its transports together
    guard let handles = btLinks[btNormalizeAddress(d.address)], !handles.isEmpty else {
        // no paired handle: the permission was never granted (pairedDevices
        // comes back empty — TCC keeps the whole pairing table away) or the
        // row went stale. say so NOW, not after a 30s spinner.
        btPending[d.address] = nil
        btFailed[d.address] = (target: target, at: Date(),
            msg: btLinks.isEmpty ? "no bluetooth access" : "unpaired")
        btSpinKick()
        armView.needsDisplay = true
        return
    }
    btPending[d.address] = (target, Date().addingTimeInterval(30))
    btFailed[d.address] = nil
    btSpinKick()
    armView.needsDisplay = true
    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    let wasConnected = d.connected
    btLinkQueue.async {
        if wasConnected {
            // close every transport that is actually up
            for h in handles where h.isConnected() { h.closeConnection() }
        } else if let h = handles.first(where: { !$0.isConnected() }) {
            h.openConnection()
        } else {
            handles[0].openConnection()
        }
    }
    btProbeKick()
}

// the pending spinner: a 15fps timer that advances the arc while any toggle
// is in flight — and settles expiry there too, so a toggle that never gets
// an answer retires into the truth (plus a "no answer" note) even if the
// sampler is busy on a blocking page.
func btSpinKick() {
    guard btSpinTimer == nil else { return }
    let t = Timer(timeInterval: 1.0 / 15.0, repeats: true) { t in
        let now = Date()
        for (addr, p) in btPending where p.until <= now {
            btPending[addr] = nil
            if let d = btDevices.first(where: { $0.address == addr }), d.connected != p.target {
                btFailed[addr] = (target: p.target, at: now, msg: "no answer")
            }
        }
        btFailed = btFailed.filter { now.timeIntervalSince($0.value.at) < 4 }
        guard !btPending.isEmpty else {
            t.invalidate(); btSpinTimer = nil
            armView.needsDisplay = true
            return
        }
        btSpin = (btSpin + 0.11).truncatingRemainder(dividingBy: 1)
        armView.needsDisplay = true
    }
    RunLoop.main.add(t, forMode: .common)
    btSpinTimer = t
}

// the probe cadence: every 2s while a toggle is in flight — a confirm
// publishes the answer the moment it exists (the tray's 5s cadence is too
// slow to feel). self-stops the moment nothing is pending or the panel closes.
func btProbeKick() {
    guard btProbeTimer == nil else { return }
    let t = Timer(timeInterval: 2, repeats: true) { t in
        if btPending.isEmpty || !extShown || extAnchor != .bluetooth {
            t.invalidate(); btProbeTimer = nil; return
        }
        sampleBluetoothDevices()
    }
    RunLoop.main.add(t, forMode: .common)
    btProbeTimer = t
}

// the toast: show it, ride its alpha at 15fps, retire it after 3s — and
// hand the panel's height band back as it goes (the height spring glides,
// so the glass grows for the toast and shrinks after it, never pops)
func btShowToast(_ msg: String) {
    btToast = (msg: msg, at: Date())
    btToastKick()
    if extShown, extAnchor == .bluetooth {
        let h = extHeight(for: .bluetooth)
        if abs(h - extH) > 0.5 {
            extHSpring.chase(h)
            extYSpring.chase(extTopOffset(for: .bluetooth, height: h))
        }
    }
    armView.needsDisplay = true
}

func btToastKick() {
    guard btToastTimer == nil else { return }
    let t = Timer(timeInterval: 1.0 / 15.0, repeats: true) { t in
        guard let toast = btToast else { t.invalidate(); btToastTimer = nil; return }
        guard Date().timeIntervalSince(toast.at) >= 3.0 else {
            armView.needsDisplay = true; return
        }
        btToast = nil
        t.invalidate(); btToastTimer = nil
        if extShown, extAnchor == .bluetooth {
            let h = extHeight(for: .bluetooth)
            if abs(h - extH) > 0.5 {
                extHSpring.chase(h)
                extYSpring.chase(extTopOffset(for: .bluetooth, height: h))
            }
        }
        armView.needsDisplay = true
    }
    RunLoop.main.add(t, forMode: .common)
    btToastTimer = t
}

// the anchor's rune/slot band, in pill-local flipped coords (y down from the
// pill's top): the trio's quarters for bluetooth/wifi/audio/mic, the whole slot for
// power
func anchorOffset(_ anchor: ExtAnchor) -> (y: CGFloat, h: CGFloat) {
    let kind: Theme.Kind = anchor == .power ? .power : .trio
    guard let i = Theme.slots.firstIndex(where: { $0.kind == kind }) else { return (Theme.pad, Theme.cell) }
    let r = Theme.slot(i, in: NSRect(x: 0, y: 0, width: Theme.pillWidth, height: Theme.pillHeight))
    if anchor == .power { return (r.minY, r.height) }
    let quarter = r.height / 4
    switch anchor {
    case .bluetooth: return (r.minY, quarter)
    case .wifi:      return (r.minY + quarter, quarter)
    case .audio:     return (r.minY + 2 * quarter, quarter)
    case .mic:       return (r.minY + 3 * quarter, quarter)
    case .power:     break
    }
    return (r.minY, r.height)
}

// the arm's top edge for an anchor. mic and power are anchored to the bar's
// BOTTOM edge — their glass runs clear down to it. bluetooth and audio center
// on their rune, clamped to the pill's straight band so nothing ever extrudes
// past the bar's top — and the bottom edge NEVER passes the bar's bottom:
// overflow anchors the glass flush to the bar's bottom edge (the pill's
// bottom-left corner melts square to seal the silhouette, see extBottomLift).
// an explicit `height` reads the TARGET height — the y-spring's target must
// be where the bottom lands when the height spring settles, not mid-flight.
func extTopOffset(for anchor: ExtAnchor, height h: CGFloat? = nil) -> CGFloat {
    let H = h ?? extH
    if anchor == .mic || anchor == .power { return PILL_HEIGHT - H }
    let a = anchorOffset(anchor)
    let center = a.y + a.h / 2
    return min(max(center - H / 2, PILL_RADIUS), PILL_HEIGHT - H)
}

// the bottom-anchored melt. while ANY arm holds the bar's bottom edge (mic
// and power always; bluetooth/wifi/audio whenever the panel is tall enough
// to be bottom-clamped), the pill's bottom-left corner melts SQUARE as the
// glass arrives and re-rounds as it withdraws — the corner radius always
// equals the arm's drawn bottom gap, so the corner arc's top meets the arm's
// bottom edge EXACTLY and the silhouette is sealed at every point of every
// transition (grow, morph, retract — no notch, no snap).
func extBottomLift() -> CGFloat {
    guard extProgress > 0.5, extY >= PILL_HEIGHT - extH - 0.5 else { return 0 }
    return PILL_RADIUS * (1 - extFade)
}
func extBottomLeftRadius() -> CGFloat {
    guard extProgress > 0.5 else { return PILL_RADIUS }
    return min(PILL_RADIUS, PILL_HEIGHT - (extY + extH - extBottomLift()))
}

// the anchor rune's band, in CG top-left y space — the arm anchors to the
// RUNE itself, the way a native menu anchors to its status item
func anchorBandCG(_ anchor: ExtAnchor) -> (top: CGFloat, bottom: CGFloat) {
    let (pillTop, _) = pillBandCG()
    let a = anchorOffset(anchor)
    return (pillTop + a.y, pillTop + a.y + a.h)
}

// the arm's rect for an anchor, in the cursor's own space: xr (leftward from
// the right screen edge) + CG top-left y. it hangs FLUSH off the pill's left
// edge (right = the pill's own edge — no gap).
func extBandCG(_ anchor: ExtAnchor) -> (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat) {
    let top = pillBandCG().top + extTopOffset(for: anchor)
    let right = PILL_WIDTH
    return (right + EXT_WIDTH, right, top, top + extH)
}

// the arm's state: width in points (what extSpring integrates), top edge in
// tab-local flipped coords (what extYSpring glides), which anchor is open
var extProgress: CGFloat = 0
var extY: CGFloat = extTopOffset(for: .bluetooth)
var extFade: CGFloat = 0        // the arm's drawn alpha — derived from width
var extAnchor: ExtAnchor = .bluetooth
var extWanted: ExtAnchor = .bluetooth    // the hovered anchor while the show dwell runs
var extShown = false
var extShowTimer: Timer?
var extHideTimer: Timer?

// extra left slack currently added to the strip window for the arm. the
// window is normally exactly the pill + its reveal slack; opening the arm
// widens it ONE invisible step (the added region is transparent — the glass
// hasn't grown yet), and it narrows back the moment the arm is glass again.
// the tab holds its screen position throughout: only window-relative
// coordinates shift, so the reveal spring's coordinate system simply slides
// with extSlack (see glassX).
var extSlack: CGFloat = 0

func setStripExtensionSlack(_ slack: CGFloat) {
    guard slack != extSlack else { return }
    extSlack = slack
    var f = stripWindowFrame()
    f.origin.x -= slack
    f.size.width += slack
    strip.setFrame(f, display: false)
    // the container MUST cover the arm — a subview cannot paint outside its
    // superview, and the default autoresizing mask doesn't track setFrame
    strip.contentView?.setFrameSize(f.size)
    // this slides the tab's whole coordinate system — an in-flight reveal
    // spring would keep chasing its stale target and fight the snap, flying
    // the glass across the screen. stop it and re-anchor it docked.
    spring.stop()
    spring.onSettle = nil
    setGlassX(glassX(docked: true))   // the tab holds its screen position in the new frame
    strip.contentView?.needsDisplay = true   // the exposed region is undefined until drawn
}

// the arm's own surface — small, and the ONLY thing that redraws during the
// arm's animation (a single view painting the whole pill every frame read as
// ~20Hz; this redraws ~10% of the pixels). it sits ABOVE the tab in z, and
// the fusion is pure geometry: its glass extends 8pt over the pill's edge,
// burying the pill's own stroke spill at the seam under opaque glass, and its
// shadow path has NO right edge — no stroke is ever drawn on either glass.
final class ArmView: NSView {
    override var isFlipped: Bool { true }

    // the tray's rows take the click: connect / disconnect (toggleBtDevice).
    // the same band the hover test reads — the panel's row column, plus the
    // row band's own slack left and right.
    override func mouseDown(with event: NSEvent) {
        guard extShown, extAnchor == .bluetooth else { return }
        let p = convert(event.locationInWindow, from: nil)
        let cx = 8 + BtPanel.tipPad
        let cw = EXT_WIDTH - BtPanel.tipPad - BtPanel.rightPad
        guard p.x >= cx - 7, p.x <= cx + cw + 7 else { return }
        let rowsTop = 8 + BtPanel.rowsTop
        let rows = Array(btDevices.prefix(BtPanel.maxRows))
        guard !rows.isEmpty,
              p.y >= rowsTop, p.y < rowsTop + CGFloat(rows.count) * BtPanel.rowH else { return }
        let row = Int((p.y - rowsTop) / BtPanel.rowH)
        btFlash = (row: row, at: Date())
        toggleBtDevice(rows[row])
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = extProgress, fade = extFade
        guard w > 0.5, fade > 0.001 else { return }
        let R = min(EXT_RADIUS, w / 2)       // the sliding tip stays round at any width
        let k: CGFloat = 0.5523
        let sx = w + 8                       // the seam (the tab's left edge), local
        let top: CGFloat = 8
        let bot: CGFloat = 8 + extH - extBottomLift()   // rides the bottom-anchored melt
        // shadow: an OPEN path — top edge, rounded tip, bottom edge — run all
        // the way INTO the seam so the shadow reaches the junction corners,
        // then clipped to the arm's own width: the seam-side cut lands exactly
        // on the tab's left edge, where the tab's own stroke carries the
        // shadow through. the pill's glass never sees a drop of this.
        let sh = NSBezierPath()
        sh.move(to: NSPoint(x: sx, y: top))
        sh.line(to: NSPoint(x: 8 + R, y: top))
        sh.curve(to: NSPoint(x: 8, y: top + R),
                 controlPoint1: NSPoint(x: 8 + R - k * R, y: top),
                 controlPoint2: NSPoint(x: 8, y: top + R - k * R))
        sh.line(to: NSPoint(x: 8, y: bot - R))
        sh.curve(to: NSPoint(x: 8 + R, y: bot),
                 controlPoint1: NSPoint(x: 8, y: bot - R + k * R),
                 controlPoint2: NSPoint(x: 8 + R - k * R, y: bot))
        sh.line(to: NSPoint(x: sx, y: bot))
        // clipped to the arm's own width: the cut lands exactly on the tab's
        // left edge, where the tab's own stroke carries the shadow through —
        // the pill's glass never sees a drop of this
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 0, width: sx, height: bounds.height))
            strokeFakeShadow(sh, alpha: fade)
            ctx.restoreGState()
        }
        // glass: rounded left, square right — reaching 8pt over the pill's
        // edge so the pill's stroke spill at the seam is buried, never seen
        let g = NSBezierPath()
        g.move(to: NSPoint(x: sx, y: top))
        g.line(to: NSPoint(x: 8 + R, y: top))
        g.curve(to: NSPoint(x: 8, y: top + R),
                controlPoint1: NSPoint(x: 8 + R - k * R, y: top),
                controlPoint2: NSPoint(x: 8, y: top + R - k * R))
        g.line(to: NSPoint(x: 8, y: bot - R))
        g.curve(to: NSPoint(x: 8 + R, y: bot),
                controlPoint1: NSPoint(x: 8, y: bot - R + k * R),
                controlPoint2: NSPoint(x: 8 + R - k * R, y: bot))
        g.line(to: NSPoint(x: sx, y: bot))
        g.close()
        Theme.glass.withAlphaComponent(fade).setFill()
        g.fill()

        // the bluetooth panel: header, divider, one row per paired device —
        // the tray content rides in on the last stretch of the growth, ONE
        // alpha for everything (no per-element fades to drift apart). the
        // layout is pinned to the FULL width regardless of the current w,
        // so nothing slides while it fades in.
        if extAnchor == .bluetooth {
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                g.addClip()   // the glass is the mask: a shrinking panel must never
                              // paint rows past its own withdrawing bottom edge
                drawBtPanel(fade: max(0, min(1, (w - 100) / 40)) * fade)
                ctx.restoreGState()
            }
        }
    }
}

// the bluetooth panel's content — drawn on the arm's glass when the anchor
// is bluetooth: a small-caps header, a divider, then one row per paired
// device (connected first), a dot answering connected, the row-hover band
// gliding under the cursor, and a click toggling the connection (rows in
// flight render their target dot at half ink until the sample confirms).
func drawBtPanel(fade: CGFloat) {
    guard fade > 0.001 else { return }
    let cx = 8 + BtPanel.tipPad
    let cw = EXT_WIDTH - BtPanel.tipPad - BtPanel.rightPad
    let headFont = NSFont.systemFont(ofSize: 10, weight: .semibold)

    // header: small caps label in the ink; the controller's state right
    let headY = 8 + BtPanel.headPad
    ("BLUETOOTH" as NSString).draw(
        at: NSPoint(x: cx, y: headY),
        withAttributes: [.font: headFont, .kern: 1.6,
                         .foregroundColor: Theme.ink.withAlphaComponent(0.95 * fade)])
    if !btControllerOn {
        let sa: [NSAttributedString.Key: Any] = [
            .font: headFont, .kern: 1.2,
            .foregroundColor: Theme.ink.withAlphaComponent(0.85 * fade)]
        let st = ("OFF" as NSString)
        st.draw(at: NSPoint(x: cx + cw - st.size(withAttributes: sa).width, y: headY),
                withAttributes: sa)
    }

    // divider: the header's rule, one quiet ink hairline
    let divY = 8 + BtPanel.rowsTop - BtPanel.rowsGap
    Theme.ink.withAlphaComponent(0.35 * fade).setFill()
    NSRect(x: cx, y: divY, width: cw, height: 1).fill()

    let rowsTop = 8 + BtPanel.rowsTop
    let rows = Array(btDevices.prefix(BtPanel.maxRows))

    // the row-hover band — the trio band's grammar, one panel over. the row
    // just clicked presses harder for a beat: the flash is the click's receipt.
    var flashBoost: CGFloat = 0
    if let f = btFlash, Date().timeIntervalSince(f.at) < 0.35, f.row == extRowTarget {
        flashBoost = 0.12 * max(0, 1 - Date().timeIntervalSince(f.at) / 0.35)
    }
    if extRowAlpha > 0.001 {
        let yc = rowsTop + (extRowPos + 0.5) * BtPanel.rowH
        let band = NSRect(x: cx - 7, y: yc - BtPanel.rowH / 2 + 2,
                          width: cw + 14, height: BtPanel.rowH - 4)
        Theme.knob.withAlphaComponent((0.09 + flashBoost) * extRowAlpha * fade).setFill()
        NSBezierPath(roundedRect: band, xRadius: 9, yRadius: 9).fill()
    }

    // empty states: controller off / sampling / nothing paired
    if rows.isEmpty {
        let msg = !btControllerOn ? "bluetooth is off"
            : btLoading ? "searching…" : "no devices found"
        (msg as NSString).draw(
            at: NSPoint(x: cx, y: rowsTop + (BtPanel.rowH - 15) / 2),
            withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .regular),
                             .foregroundColor: Theme.ink.withAlphaComponent(0.8 * fade)])
        return
    }

    // one row per device: the name left — heavier ink when connected —
    // and a dot right: filled in the value-run taupe when connected, a
    // quiet hollow ring when not. a row in flight (clicked, unconfirmed)
    // spins a small arc on the dot; a row whose answer never came keeps
    // its true dot and wears a "no answer" note for a few seconds.
    for (i, d) in rows.enumerated() {
        let rowY = rowsTop + CGFloat(i) * BtPanel.rowH
        let pend = btPending[d.address]
        let failMsg: String? = btFailed[d.address].flatMap {
            Date().timeIntervalSince($0.at) < 3 ? $0.msg : nil
        }
        let shownConnected = pend?.target ?? d.connected
        let dim: CGFloat = pend != nil ? 0.55 : failMsg != nil ? 0.5 : 1
        let font = NSFont.systemFont(ofSize: 12.5, weight: shownConnected ? .medium : .regular)
        let nameW = cw - (failMsg != nil ? 96 : 18)
        let name = ellipsize(d.name, font: font, width: nameW)
        (name as NSString).draw(
            at: NSPoint(x: cx, y: rowY + (BtPanel.rowH - 15) / 2),
            withAttributes: [.font: font,
                             .foregroundColor: (shownConnected ? Theme.inkDeep : Theme.ink)
                                 .withAlphaComponent((shownConnected ? 1.0 : 0.9) * fade * dim)])
        let dot = NSRect(x: cx + cw - 10, y: rowY + BtPanel.rowH / 2 - 3, width: 6, height: 6)
        if pend != nil {
            // the spinner: a small round-cap arc riding the dot's place
            let a = btSpin * 360
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: dot.midX, y: dot.midY), radius: 4.6,
                          startAngle: a, endAngle: a + 130, clockwise: true)
            Theme.ink.withAlphaComponent(0.85 * fade).setStroke()
            arc.lineWidth = 1.6
            arc.lineCapStyle = .round
            arc.stroke()
        } else {
            if let failMsg {
                let mf = NSFont.systemFont(ofSize: 10, weight: .medium)
                let ma: [NSAttributedString.Key: Any] = [
                    .font: mf, .kern: 0.4,
                    .foregroundColor: Theme.ink.withAlphaComponent(0.55 * fade)]
                let w = (failMsg as NSString).size(withAttributes: ma).width
                (failMsg as NSString).draw(
                    at: NSPoint(x: cx + cw - 24 - w, y: rowY + (BtPanel.rowH - 12) / 2),
                    withAttributes: ma)
            }
            if shownConnected {
                Theme.sliderFill.withAlphaComponent(fade * dim).setFill()
                NSBezierPath(ovalIn: dot).fill()
            } else {
                let ring = NSBezierPath(ovalIn: dot)
                Theme.ink.withAlphaComponent(0.45 * fade * dim).setStroke()
                ring.lineWidth = 1.2
                ring.stroke()
            }
        }
    }

    // the toast — one centered line in the band the panel grew for it: fade
    // in over 150ms, hold, fade out over 400ms, then the glass glides back.
    // every connect/disconnect the tray can see answers here, so a device
    // that snaps straight back reads honestly: "disconnected" then
    // "connected" a beat later.
    if let t = btToast {
        let e = Date().timeIntervalSince(t.at)
        if e < 3.0 {
            let a = max(0, min(1, min(e / 0.15, (3.0 - e) / 0.4))) * fade
            if a > 0.001 {
                let tf = NSFont.systemFont(ofSize: 10, weight: .semibold)
                let msg = ellipsize(t.msg, font: tf, width: cw)
                let ma: [NSAttributedString.Key: Any] = [
                    .font: tf, .kern: 0.8,
                    .foregroundColor: Theme.ink.withAlphaComponent(0.8 * a)]
                let w = (msg as NSString).size(withAttributes: ma).width
                let ty = 8 + extH - extBottomLift() - BtPanel.bottomPad - BtPanel.toastH
                    + (BtPanel.toastH - 12) / 2
                (msg as NSString).draw(
                    at: NSPoint(x: cx + (cw - w) / 2, y: ty),
                    withAttributes: ma)
            }
        }
    }
}

// one integrator, two outputs: the grow and the fade derive from the same
// width — the fade spends the first 24pt of travel, so they cannot drift
// apart. per tick this is GEOMETRY ONLY (one small view's frame); the arm
// view redraws itself, the tab never repaints for the arm's sake.
func relayoutExt(width w: CGFloat? = nil, top ty: CGFloat? = nil, height h: CGFloat? = nil) {
    extProgress = max(0, min(w ?? extProgress, EXT_WIDTH + EXT_SLACK)).rounded()
    if let h { extH = max(60, min(h, PILL_HEIGHT)) }
    if let ty { extY = ty }
    extFade = max(0, min(1, extProgress / 24))
    // the arm is glass and closed: the window hands its width back on its own
    // — even if an interrupted handoff never got to do it
    if extProgress == 0, !extShown, extSlack != 0 { setStripExtensionSlack(0) }
    let t = tab.frame
    armView.setFrameSize(NSSize(width: extProgress + 24, height: extH + 16))
    armView.setFrameOrigin(NSPoint(x: t.minX - extProgress - 8,
                                   y: t.minY + (t.height - extY - extH) - 8))
    armView.isHidden = extProgress < 0.5
}

let armView = ArmView(frame: NSRect(x: 0, y: 0, width: 24, height: extH + 16))
// above the tab in z — added after it — so its glass buries the seam spill
strip.contentView?.addSubview(armView)

let extSpring = SpringDriver(apply: { relayoutExt(width: $0) }, read: { extProgress })
let extYSpring = SpringDriver(apply: { relayoutExt(top: $0) }, read: { extY })
// the arm's height rides its own spring: the bluetooth panel's row count
// changes behind our back (a device pairs, one drops), and a step there read
// as a pop — now the glass grows and shrinks under the same physics as the
// reveal. extTopOffset(for:height:) reads the TARGET height, so the y-spring
// always aims where the bottom lands when the height settles.
let extHSpring = SpringDriver(apply: { relayoutExt(height: $0) }, read: { extH })

// the bluetooth panel's row-hover band — the trio band's grammar, one panel
// over: alpha answers "a row is hovered on an open bluetooth panel", position
// glides toward the hovered row's index and holds still while it fades out.
// display-only band no more — the band is the hover answer; the click toggles
var extRowAlpha: CGFloat = 0
var extRowPos: CGFloat = 0
var extRowTarget: Int = -1     // hovered panel row, -1 = none
let extRowAlphaSpring = ChaseTimer(
    get: { extRowAlpha },
    set: { v in extRowAlpha = v; armView.needsDisplay = true },
    target: { extShown && extAnchor == .bluetooth && extRowTarget >= 0 ? 1 : 0 },
    rate: 0.5, epsilon: 0.004)
let extRowPosSpring = ChaseTimer(
    get: { extRowPos },
    set: { v in extRowPos = v; armView.needsDisplay = true },
    target: { extRowTarget >= 0 ? CGFloat(extRowTarget) : extRowPos },
    rate: 0.5, epsilon: 0.002)

func openExtension() {
    extHideTimer?.invalidate(); extHideTimer = nil
    extShowTimer?.invalidate(); extShowTimer = nil
    guard !extShown else { return }
    extShown = true
    extAnchor = extWanted
    extHSpring.stop()
    relayoutExt(height: extHeight(for: extAnchor))   // from closed: snap to the panel's height
    if extAnchor == .bluetooth { startBluetoothRefresh() }
    else { btRefreshTimer?.invalidate(); btRefreshTimer = nil }
    extSpring.stop()
    extSpring.onSettle = nil
    setStripExtensionSlack(EXT_WIDTH + EXT_SLACK)   // room first — invisible, all transparent
    let top = extTopOffset(for: extAnchor)
    if extProgress < 0.5 {
        extYSpring.stop()
        relayoutExt(top: top)          // from closed: snap to the rune
    } else if abs(extY - top) > 0.5 {
        extYSpring.chase(top)          // reopening mid-retract: glide back to the rune
    }
    extSpring.chase(EXT_WIDTH)
}

// the open arm glides to another rune — the menu bar's arm migrates, it does
// not close and reopen
func morphExtension(to anchor: ExtAnchor) {
    extAnchor = anchor
    let h = extHeight(for: anchor)                 // morphing anchors can change the height
    if abs(h - extH) > 0.5 {
        extHSpring.chase(h)
        extYSpring.chase(extTopOffset(for: anchor, height: h))
    } else {
        extYSpring.chase(extTopOffset(for: anchor))
    }
    if anchor == .bluetooth { startBluetoothRefresh() }
    else { btRefreshTimer?.invalidate(); btRefreshTimer = nil }
    extRowTarget = -1                              // leaving the bluetooth panel fades the band out
    extRowAlphaSpring.start()
}

func closeExtension(instant: Bool = false) {
    extShowTimer?.invalidate(); extShowTimer = nil
    extHideTimer?.invalidate(); extHideTimer = nil
    guard extShown else { return }
    extShown = false
    btRefreshTimer?.invalidate(); btRefreshTimer = nil
    extRowTarget = -1                              // the band fades out with the panel
    extRowAlphaSpring.start()
    extSpring.stop()
    extSpring.onSettle = nil
    if instant {
        extYSpring.stop()
        relayoutExt(width: 0)
        setStripExtensionSlack(0)      // hand the window's width back at once
        return
    }
    extSpring.chase(0)
    extSpring.onSettle = { setStripExtensionSlack(0) }   // width back only once the arm is glass
}

// the whole extension decision, position-driven off the 30Hz poll — the same
// grammar as the reveal. hover intent is dwelled: 120ms on a rune opens,
// 180ms off both runes and panel closes, so brushing past a rune never
// flashes it, and darting back onto the panel cancels the close mid-dwell
// with no flicker. crossing from one rune to another never closes anything —
// the open arm just morphs across.
func updateExtension(xr: CGFloat, y: CGFloat) {
    // legacy: the arm is retired — parked shut, forever inert
    guard LEGACY_EXTENSION else {
        if extShown { closeExtension(instant: true) }
        return
    }
    // the extension is inert until the reveal spring is PARKED — glassDocked
    // alone turns true during the entrance overshoot wobble, and widening the
    // window under a still-integrating spring is the flying-glass bug
    guard stripVisible, !sessionLocked, !mcActive, !cmdOverride, glassDocked, !spring.running else {
        if extShown { closeExtension(instant: !stripVisible || sessionLocked) }
        return   // already retracting: let the animated close finish its handoff
    }
    // which rune is under the cursor, top of the trio down (±3px of slack)
    var hovered: ExtAnchor? = nil
    for (anchor, band) in [(ExtAnchor.bluetooth, anchorBandCG(.bluetooth)),
                           (ExtAnchor.wifi, anchorBandCG(.wifi)),
                           (ExtAnchor.audio, anchorBandCG(.audio)),
                           (ExtAnchor.mic, anchorBandCG(.mic)),
                           (ExtAnchor.power, anchorBandCG(.power))] {
        if xr <= PILL_WIDTH, y >= band.top - 3, y <= band.bottom + 3 { hovered = anchor; break }
    }
    let g = extBandCG(extAnchor)
    let onPanel = extShown
        && xr <= g.left + HIDE_MARGIN && xr >= g.right - HIDE_MARGIN
        && y >= g.top - 8 && y <= g.bottom + 8
    // the bluetooth panel's row hover — the rows still answer the cursor
    // (the gliding band); a click on the row toggles its connection.
    // over the pill the cursor belongs to the runes.
    var rowTarget = -1
    if extShown, extAnchor == .bluetooth,
       xr >= PILL_WIDTH + 10, xr <= g.left + HIDE_MARGIN {
        let top = g.top + BtPanel.rowsTop
        let n = min(btDevices.count, BtPanel.maxRows)
        if n > 0, y >= top, y < top + CGFloat(n) * BtPanel.rowH {
            rowTarget = min(n - 1, Int((y - top) / BtPanel.rowH))
        }
    }
    if rowTarget != extRowTarget {
        extRowTarget = rowTarget
        if extRowAlpha < 0.001, rowTarget >= 0 { extRowPos = CGFloat(rowTarget) }   // first show: bloom in place
        extRowAlphaSpring.start()
        extRowPosSpring.start()
    }
    if hovered != nil || onPanel {
        extHideTimer?.invalidate(); extHideTimer = nil
        if let h = hovered {
            if !extShown {
                extWanted = h
                if extShowTimer == nil {
                    extShowTimer = Timer.scheduledTimer(withTimeInterval: EXT_SHOW_DWELL, repeats: false) { _ in
                        extShowTimer = nil
                        openExtension()
                    }
                }
            } else if h != extAnchor {
                morphExtension(to: h)   // same arm, new rune
            }
        }
    } else {
        extShowTimer?.invalidate(); extShowTimer = nil   // left the rune before the dwell — no flash
        if extShown, extHideTimer == nil {
            extHideTimer = Timer.scheduledTimer(withTimeInterval: EXT_HIDE_DWELL, repeats: false) { _ in
                extHideTimer = nil
                closeExtension()
            }
        }
    }
}

relayoutExt(width: 0)   // parked: zero-width, faded, no slack

// MARK: - the overlay (⌘⇧Space launcher)
//
// the front end now. ⌘⇧Space dims the whole screen and floats one cream
// card in the middle: the time with the date riding the same row, the
// battery status, the Night Shift control row — label · track · live %,
// one line — and the three power actions — restart / sleep / shut down,
// the destructive two behind native AppleScript confirmations. Escape, a
// click on the dimmed desktop, or a session lock puts it away. the notch
// pill is parked behind PILL_ENABLED = false — its machinery stays (it
// works; the launcher replaced it), the daemon just never runs it.

let PILL_ENABLED = false

enum OverlayCard {
    static let pad: CGFloat = 30
    static let width: CGFloat = 540
    static let timeH: CGFloat = 58       // 46pt SF Mono, ink-centered
    static let dateH: CGFloat = 18       // rides the time row, right-aligned
    static let batteryH: CGFloat = 40
    static let controlH: CGFloat = 34    // the Night Shift row: label · track · live %
    static let sliderH: CGFloat = 34     // the pill's own track: 28.25 stadium, knob 28.25
    static let buttonsH: CGFloat = 44
    static let gap: CGFloat = 16
    static let tightGap: CGFloat = 6
    static let radius: CGFloat = 24
    static var height: CGFloat {
        pad + timeH + gap + batteryH + gap + controlH + gap + buttonsH + pad
    }
    static let buttonNames = ["Restart", "Sleep", "Shut Down"]
}

var overlayShown = false
var overlaySnapshotMode = false    // SMALT_SNAPSHOT=2 renders the card bare, no dim
var overlayDragSlider = false
var overlayHoverButton: Int? = nil
var overlayPressButton: Int? = nil
var overlaySliderHover = false
var overlayBatteryHovered = false
var overlayKnobLatched = false     // the knob's first-hover wobble latch — fresh each open
var overlayHapticStep = Int.min    // the drag ratchet
var overlayFaceTarget: CGFloat = 0 // knob face: 0 = Night-Day icon, 1 = %

// the overlay battery's crossfade state — the pill's drawBattery machinery,
// ported; the springs mark the overlay instead of the parked tab
var overlayBatteryInit = false
var overlayBatteryShown = (charging: false, lpm: false)
var overlayBoltAlpha: CGFloat = 0
var overlayFillFrom = Theme.darkShell
var overlayFillTo = Theme.darkShell
var overlayFillBlend: CGFloat = 1
var overlayBatteryPopTimer: Timer?
var overlayBatteryPopV: CGFloat = 0

final class OverlayLauncherView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }   // Escape lands here
    override var wantsDefaultClipping: Bool { false }   // the shadow spills past the card

    // the card + its rows, recomputed on demand — the layout is one column
    // of rows, no state to go stale
    var cardRect: NSRect {
        let b = bounds
        let h = OverlayCard.height
        return NSRect(x: b.midX - OverlayCard.width / 2, y: b.midY - h / 2,
                      width: OverlayCard.width, height: h)
    }

    func rows(card: NSRect) -> (time: NSRect, date: NSRect, battery: NSRect,
                                label: NSRect, slider: NSRect, pct: NSRect,
                                buttons: [NSRect]) {
        var y = card.minY + OverlayCard.pad
        let x = card.minX + OverlayCard.pad
        let w = card.width - 2 * OverlayCard.pad
        // the top row: the clock leads at the left edge, the date rides the
        // same row at the right edge
        let time = NSRect(x: x, y: y, width: w, height: OverlayCard.timeH)
        let date = NSRect(x: x, y: time.maxY - OverlayCard.dateH, width: w, height: OverlayCard.dateH)
        y += OverlayCard.timeH + OverlayCard.gap
        let batt = NSRect(x: x, y: y, width: w, height: OverlayCard.batteryH); y += OverlayCard.batteryH + OverlayCard.gap
        // the control row: the label ON the slider's row, not above it —
        // label · track · live %, one full-width line
        let label = NSRect(x: x, y: y, width: 96, height: OverlayCard.controlH)
        let pct = NSRect(x: x + w - 56, y: y, width: 56, height: OverlayCard.controlH)
        let slider = NSRect(x: label.maxX + 14, y: y,
                            width: w - label.width - pct.width - 28,
                            height: OverlayCard.sliderH)
        y += OverlayCard.controlH + OverlayCard.gap
        let bw = (w - 32) / 3
        var buttons: [NSRect] = []
        for i in 0..<3 {
            buttons.append(NSRect(x: x + CGFloat(i) * (bw + 16), y: y,
                                  width: bw, height: OverlayCard.buttonsH))
        }
        y += OverlayCard.buttonsH
        return (time, date, batt, label, slider, pct, buttons)
    }

    func sliderValue() -> CGFloat { max(0, min(1, Theme.sliderDisplay)) }

    // the pill's dark-skin helpers — the same widgets, ink pointed the other way
    func overlayShellColor(_ lpm: Bool) -> NSColor { lpm ? Theme.darkShellLPM : Theme.darkShell }

    func setSlider(_ v: CGFloat) {
        let clamped = max(0, min(1, v))
        Theme.sliderValue = clamped
        Theme.sliderDisplay = clamped
        Theme.nightOff = (clamped == 0)
        NightShift.set(Float(clamped))
        needsDisplay = true
    }

    // the pill's own M3 slider, horizontal, in the dark skin — full
    // fidelity: quiet run / value run / knob face crossfading Night-Day ⇄ %,
    // knob swell + first-hover wobble (the machine drives Theme.knobHover /
    // Theme.knobPop), drag with the 50% detent and the haptic ratchet.
    func drawOverlaySlider(in slot: NSRect) {
        let v = max(0, min(1, Theme.sliderDisplay))
        let slotHover = max(0, min(1, Theme.sliderHover))
        let knobHover = max(0, min(1, Theme.knobHover))
        let cy = slot.midY
        let knobSize = max(18, Theme.sliderHandle * (1 + 0.08 * knobHover + 0.12 * Theme.knobPop))

        // handle center travel: v=0 parks at the left, v=1 at the right
        let xLeft = slot.minX + knobSize / 2
        let xRight = slot.maxX - knobSize / 2
        let hc = xLeft + (xRight - xLeft) * v

        // track: one thick stadium the slot's full width — Theme.sliderTrack
        // (28.25) tall, the pill's exact metric. the empty run is what lights
        // at 0%: the value run hides entirely under the knob.
        let zero = v < 0.005
        let trackRect = NSRect(x: slot.minX, y: cy - Theme.sliderTrack / 2,
                               width: slot.width, height: Theme.sliderTrack)
        let stadium = NSBezierPath(roundedRect: trackRect, xRadius: Theme.sliderTrack / 2,
                                   yRadius: Theme.sliderTrack / 2)
        let quiet = zero
            ? NSColor.white.withAlphaComponent(0.15 + 0.10 * slotHover)
            : Theme.darkTrack
        quiet.setFill()
        stadium.fill()
        // active run: FLAT-end fill from the track's left edge to the knob's
        // center line, clipped to the stadium; hover brightens one step
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            stadium.addClip()
            lerp(Theme.darkValue, Theme.darkValueHover, slotHover).setFill()
            NSBezierPath(rect: NSRect(x: trackRect.minX, y: trackRect.minY,
                                      width: hc - trackRect.minX + 1,
                                      height: trackRect.height)).fill()
            ctx.restoreGState()
        }

        // knob: cream disc on the dark card — the inversion of the pill's
        // dark disc on cream
        let handle = NSRect(x: hc - knobSize / 2, y: cy - knobSize / 2,
                            width: knobSize, height: knobSize)
        Theme.darkText.setFill()
        NSBezierPath(ovalIn: handle).fill()

        // the face: implode/explode — Night-Day glyph ⇄ %, the pill's own
        // theater, in the knob ink (dark on cream)
        let face = max(0, min(1, Theme.sliderFace))
        let edgeAlpha: (CGFloat) -> CGFloat = { min(1, $0 * 4) }
        let pct = Int((Theme.sliderValue * 100).rounded())

        if face > 0 {
            drawText("\(pct)", font: .tabular(KnobFace.base * face, .semibold),
                     color: Theme.knob.withAlphaComponent(edgeAlpha(face)), in: handle)
        }

        if face < 1 {
            let f = 1 - face
            let size = (knobSize - 6) * f
            SVGIcon.draw(.nightDay, color: Theme.knob, inRect: NSRect(x: handle.midX - size / 2,
                                                                      y: handle.midY - size / 2,
                                                                      width: size, height: size),
                         fraction: edgeAlpha(f))
        }
    }

    // the battery's status group: glyph · pct (+ charging estimate), laid
    // out once and shared by the painter AND the hit-testers — the click
    // target is the group, not the whole row
    func batteryGroup(in row: NSRect) -> (rect: NSRect, detail: String?) {
        let real = batteryLevel()
        var detailStr: String? = nil
        if let d = batteryDetail(), real?.charging ?? false,
           (real?.pct ?? 100) < 100, d.toFull > 0 {
            let hrs = d.toFull / 60, rem = d.toFull % 60
            detailStr = hrs > 0 ? "\(hrs)h \(rem)m to full" : "\(rem)m to full"
        }
        let glyphW: CGFloat = 46, slotH: CGFloat = 34
        let pctW: CGFloat = 64, detailW: CGFloat = 130
        let groupW = glyphW + 10 + pctW + (detailStr != nil ? 10 + detailW : 0)
        return (NSRect(x: row.minX, y: row.midY - slotH / 2,
                       width: groupW, height: slotH), detailStr)
    }

    // the pill's battery painter with its full state machine — plug/unplug
    // bolt crossfade, LPM amber crossfade, hover: the charge brightens one
    // step toward cream (the dark skin's "deepen"), click: Low Power Mode
    // toggle + the underdamped pop.
    func drawOverlayBattery(in row: NSRect) {
        let real = batteryLevel()
        let lpm = ProcessInfo.processInfo.isLowPowerModeEnabled
        let charging = real?.charging ?? false
        guard let pct = real?.pct else { return }

        if !overlayBatteryInit {
            overlayBatteryInit = true
            overlayBatteryShown = (charging: charging, lpm: lpm)
            overlayBoltAlpha = charging ? 1 : 0
            overlayFillFrom = overlayShellColor(lpm); overlayFillTo = overlayFillFrom; overlayFillBlend = 1
        } else {
            if charging != overlayBatteryShown.charging {
                overlayBatteryShown.charging = charging
                overlayBoltSpring.start()
            }
            if lpm != overlayBatteryShown.lpm {
                overlayFillFrom = lerp(overlayFillFrom, overlayFillTo, overlayFillBlend)
                overlayFillTo = overlayShellColor(lpm)
                overlayFillBlend = 0
                overlayBatteryShown.lpm = lpm
                overlayFillSpring.start()
            }
        }
        overlayBoltSpring.start()

        let hover = max(0, min(1, Theme.batteryHover))
        let fillFrom = lerp(overlayFillFrom, Theme.darkShellHover, hover)
        let fillTo = lerp(overlayFillTo, Theme.darkShellHover, hover)

        // the glyph + pct (+ charging estimate) as one left-anchored group —
        // the same rect the hit-testers see (batteryGroup)
        let group = batteryGroup(in: row)
        let detailStr = group.detail
        let gx = group.rect.minX
        let slot = NSRect(x: gx, y: group.rect.midY - 17, width: 46, height: 34)
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.translateBy(x: slot.midX, y: slot.midY)
            ctx.scaleBy(x: 1.4, y: 1.4)
            ctx.translateBy(x: -slot.midX, y: -slot.midY)
            Battery.draw(pct: pct, boltAlpha: overlayBoltAlpha,
                         fillFrom: fillFrom, fillTo: fillTo, fillBlend: overlayFillBlend, in: slot)
            ctx.restoreGState()
        }
        drawText("\(pct)%", font: .tabular(18, .semibold), color: Theme.darkText,
                 in: NSRect(x: gx + 46 + 10, y: row.minY, width: 64, height: row.height))
        if let detailStr {
            drawText(detailStr, font: NSFont.systemFont(ofSize: 12, weight: .regular),
                     color: Theme.darkMuted,
                     in: NSRect(x: gx + 46 + 10 + 64, y: row.minY, width: 130, height: row.height))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // the dim: the whole screen, one dark pass. the card floats above it.
        if !overlaySnapshotMode {
            NSColor.black.withAlphaComponent(0.55).setFill()
            bounds.fill()
        }

        let card = cardRect
        let path = NSBezierPath(roundedRect: card, xRadius: OverlayCard.radius,
                                yRadius: OverlayCard.radius)
        strokeFakeShadow(path)
        Theme.darkGlass.setFill()
        path.fill()
        Theme.darkStroke.setStroke()
        path.lineWidth = 1
        path.stroke()

        let r = rows(card: card)

        // the top row: the clock leads at the left edge, the date rides the
        // same row at the right edge — cream + quiet ink, one line
        let now = Date()
        let cal = Calendar.current
        let h = String(format: "%02d", cal.component(.hour, from: now))
        let m = String(format: "%02d", cal.component(.minute, from: now))
        drawText("\(h):\(m)", font: NSFont.monospacedSystemFont(ofSize: 46, weight: .regular),
                 color: Theme.darkText, in: r.time, align: .left)

        // the date, quiet ink, riding the clock's row
        let df = DateFormatter()
        df.dateFormat = "EEEE d MMM"
        drawText(df.string(from: now), font: NSFont.systemFont(ofSize: 13, weight: .medium),
                 color: Theme.darkMuted, in: r.date, align: .right)

        drawOverlayBattery(in: r.battery)

        // the Night Shift control row — the pill's widget, full
        // interactivity: the label ON the slider's row (left), the live
        // strength at the right in the value ink, the track between them
        drawText("NIGHT SHIFT", font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                 color: Theme.darkMuted, in: r.label, kern: 1.5)
        drawOverlaySlider(in: r.slider)
        if Theme.nightOff {
            drawText("OFF", font: .tabular(15, .semibold),
                     color: Theme.darkMuted, in: r.pct)
        } else {
            drawText("\(Int((Theme.sliderValue * 100).rounded()))%",
                     font: .tabular(15, .semibold),
                     color: Theme.darkValue, in: r.pct)
        }

        // the power chips — Restart · Sleep · Shut Down — each chip one
        // MD3 glyph, inked cream on the dark card, ink-centered
        for (i, br) in r.buttons.enumerated() {
            let hovered = overlayHoverButton == i
            let pressed = overlayPressButton == i
            let chip = NSBezierPath(roundedRect: br, xRadius: 12, yRadius: 12)
            let fill: CGFloat = pressed ? 0.26 : hovered ? 0.14 : 0.06
            NSColor.white.withAlphaComponent(fill).setFill()
            chip.fill()
            NSColor.white.withAlphaComponent(0.14).setStroke()
            chip.lineWidth = 1
            chip.stroke()
            let name: SVGIcon.Name = [.restart, .sleep, .power][i]
            SVGIcon.draw(name, color: Theme.darkText, in: br)
        }
    }

    // MARK: events

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let card = cardRect
        guard card.contains(p) else { hideOverlay(); return }   // the dim: dismiss
        let r = rows(card: card)
        if r.slider.insetBy(dx: -6, dy: -8).contains(p) {
            // the pill's drag: face to %, ratchet armed at the grab point
            overlayDragSlider = true
            overlayFaceTarget = 1
            overlayFaceSpring.start()
            overlayHapticStep = Int((min(1, max(0, (p.x - r.slider.minX) / r.slider.width)) * 20).rounded(.down))
            overlaySetSlider(from: p)
            return
        }
        if batteryGroup(in: r.battery).rect.contains(p) {
            // the battery's click: the Low Power Mode toggle — the pill's
            // own rungs (passwordless sudo → self-installing rule → admin
            // prompt), run off-main so the card never freezes mid-toggle
            fireOverlayBatteryPop()
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            DispatchQueue.global().async {
                setLowPowerMode(!ProcessInfo.processInfo.isLowPowerModeEnabled)
            }
            return
        }
        for (i, br) in r.buttons.enumerated() where br.contains(p) {
            overlayPressButton = i
            needsDisplay = true
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard overlayDragSlider else { return }
        let p = convert(event.locationInWindow, from: nil)
        overlaySetSlider(from: p)
        overlaySliderKnob.sync()   // the cursor IS the knob mid-drag
    }

    override func mouseUp(with event: NSEvent) {
        if overlayDragSlider {
            overlayDragSlider = false
            overlayHapticStep = Int.min          // fresh ratchet next grab
            overlayFaceTarget = 0                // back to the Night-Day icon
            overlayFaceSpring.start()
        }
        guard let press = overlayPressButton else { return }
        overlayPressButton = nil
        needsDisplay = true
        let p = convert(event.locationInWindow, from: nil)
        let r = rows(card: cardRect)
        guard r.buttons[press].contains(p) else { return }
        switch press {
        case 0: hideOverlay(); confirmThen("Restart your Mac now?", "Restart",
                                          "tell application \"System Events\" to restart")
        case 1: hideOverlay(); sleepSystem()
        case 2: hideOverlay(); confirmThen("Shut down the Mac now?", "Shut Down",
                                           "tell application \"System Events\" to shut down")
        default: break
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let r = rows(card: cardRect)
        var changed = false
        let hb = r.buttons.firstIndex { $0.contains(p) }
        if hb != overlayHoverButton { overlayHoverButton = hb; changed = true }
        let sh = r.slider.insetBy(dx: -6, dy: -8).contains(p)
        if sh != overlaySliderHover { overlaySliderHover = sh; changed = true }
        let bh = batteryGroup(in: r.battery).rect.contains(p)
        if bh != overlayBatteryHovered { overlayBatteryHovered = bh; changed = true }
        overlaySliderKnob.sync()   // position-driven knob hover + the wobble latch
        if changed {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    override func mouseExited(with event: NSEvent) {
        if overlayHoverButton != nil || overlaySliderHover || overlayBatteryHovered {
            overlayHoverButton = nil; overlaySliderHover = false; overlayBatteryHovered = false
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { hideOverlay(); return }        // esc
        super.keyDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
        let r = rows(card: cardRect)
        for br in r.buttons { addCursorRect(br, cursor: .pointingHand) }
        addCursorRect(r.slider.insetBy(dx: -6, dy: -8), cursor: .pointingHand)
        addCursorRect(batteryGroup(in: r.battery).rect, cursor: .pointingHand)   // the battery: the LPM toggle
    }
}

let overlayView = OverlayLauncherView(frame: NSRect(origin: .zero,
    size: mainScreen()?.frame.size ?? NSSize(width: 800, height: 600)))

// the overlay's widget springs — the pill's own ChaseTimers, ported; each
// set marks the overlay instead of the parked tab
let overlayValueSpring = ChaseTimer(
    get: { Theme.sliderDisplay },
    set: { Theme.sliderDisplay = $0; overlayView.needsDisplay = true },
    target: { Theme.sliderValue }, rate: 0.22, epsilon: 0.0004)
let overlayFaceSpring = ChaseTimer(
    get: { Theme.sliderFace },
    set: { Theme.sliderFace = $0; overlayView.needsDisplay = true },
    target: { overlayFaceTarget }, rate: 0.25, epsilon: 0.002)
let overlayHoverSpring = ChaseTimer(
    get: { Theme.sliderHover },
    set: { Theme.sliderHover = $0; overlayView.needsDisplay = true },
    target: { overlaySliderHover && !overlayDragSlider ? 1 : 0 }, rate: 0.22, epsilon: 0.004)
let overlayBatteryHoverSpring = ChaseTimer(
    get: { Theme.batteryHover },
    set: { Theme.batteryHover = $0; overlayView.needsDisplay = true },
    target: { overlayBatteryHovered ? 1 : 0 }, rate: 0.7, epsilon: 0.01)
let overlayBoltSpring = ChaseTimer(
    get: { overlayBoltAlpha },
    set: { overlayBoltAlpha = $0; overlayView.needsDisplay = true },
    target: { overlayBatteryShown.charging ? 1 : 0 }, rate: 0.2, epsilon: 0.01)
let overlayFillSpring = ChaseTimer(
    get: { overlayFillBlend },
    set: { overlayFillBlend = $0; overlayView.needsDisplay = true },
    target: { 1 }, rate: 0.2, epsilon: 0.005)

// the same KnobHoverMachine the pill's sliders run — swell + wobble + haptics
let overlaySliderKnob = KnobHoverMachine(
    hovered: { overlayKnobHovered() },
    read: { Theme.knobHover },
    write: { Theme.knobHover = $0; overlayView.needsDisplay = true },
    popWrite: { Theme.knobPop = $0; overlayView.needsDisplay = true },
    latch: { overlayKnobLatched },
    setLatch: { overlayKnobLatched = true },
    haptic: { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) })

// geometry + cursor helpers for the machine
func overlaySliderRect() -> NSRect {
    overlayView.rows(card: overlayView.cardRect).slider
}

func overlayCursorPoint() -> NSPoint? {
    guard let w = overlayView.window else { return nil }
    let p = w.convertFromScreen(NSRect(origin: NSEvent.mouseLocation, size: .zero)).origin
    return overlayView.convert(p, from: nil)
}

func overlayKnobHovered() -> Bool {
    guard overlayShown, let p = overlayCursorPoint() else { return false }
    let r = overlaySliderRect()
    let knobSize = max(18, Theme.sliderHandle
        * (1 + 0.08 * max(0, min(1, Theme.knobHover)) + 0.12 * Theme.knobPop))
    let v = max(0, min(1, Theme.sliderDisplay))
    let hc = r.minX + knobSize / 2 + (r.width - knobSize) * v
    return abs(p.x - hc) <= Theme.sliderHandle / 2 + 3
        && abs(p.y - r.midY) <= Theme.sliderHandle / 2 + 3
}

// the pill's drag writer, ported: cursor → value, the 50% detent, and the
// levelChange ratchet (one tick per 5% crossed during a drag)
func overlaySetSlider(from p: NSPoint) {
    let r = overlaySliderRect()
    var v = min(1, max(0, (p.x - r.minX) / r.width))
    if abs(v - 0.5) < 0.035 { v = 0.5 }   // the 50% detent: within a knob's pull, snap
    Theme.sliderValue = v
    Theme.sliderDisplay = v               // the cursor IS the display mid-drag
    Theme.nightOff = (v == 0)
    NightShift.set(Float(v))
    overlayValueSpring.stop()
    let step = Int((v * 20).rounded(.down))
    if step != overlayHapticStep {
        overlayHapticStep = step
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
    overlayView.needsDisplay = true
}

// the battery's toggle pop — the knobs' own underdamped wobble
func fireOverlayBatteryPop() {
    Theme.batteryPop = 1
    overlayBatteryPopV = 0
    guard overlayBatteryPopTimer == nil else { return }
    let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { _ in
        let K: CGFloat = 420, C: CGFloat = 14, dt: CGFloat = 1.0 / 120.0
        overlayBatteryPopV += (-K * Theme.batteryPop - C * overlayBatteryPopV) * dt
        Theme.batteryPop += overlayBatteryPopV * dt
        if abs(Theme.batteryPop) < 0.002, abs(overlayBatteryPopV) < 0.02 {
            Theme.batteryPop = 0
            overlayBatteryPopTimer?.invalidate(); overlayBatteryPopTimer = nil
        }
        overlayView.needsDisplay = true
    }
    RunLoop.main.add(t, forMode: .common)
    overlayBatteryPopTimer = t
}

let overlayWindow: NSWindow = {
    let f = mainScreen()?.frame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
    let win = OverlayPanel(contentRect: f,
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
    win.backgroundColor = .clear
    win.isOpaque = false
    win.hasShadow = false
    win.level = NSWindow.Level(rawValue: 21)
    win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    win.ignoresMouseEvents = false
    win.alphaValue = 0
    win.contentView = overlayView
    return win
}()

func showOverlay() {
    guard !overlayShown else { return }
    overlayShown = true
    overlayKnobLatched = false           // fresh open, fresh first-hover wobble
    overlayValueSpring.start()           // adopt the live Night Shift value
    overlayFaceSpring.start()
    if let s = mainScreen() { overlayWindow.setFrame(s.frame, display: false) }
    overlayWindow.alphaValue = 0
    overlayWindow.makeKeyAndOrderFront(nil)
    overlayView.window?.makeFirstResponder(overlayView)   // esc lands on the view
    overlayWindow.invalidateCursorRects(for: overlayView)
    NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.18
        overlayWindow.animator().alphaValue = 1
    }
}

func hideOverlay() {
    guard overlayShown else { return }
    overlayShown = false
    overlayDragSlider = false
    overlayPressButton = nil
    NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = 0.15
        overlayWindow.animator().alphaValue = 0
    }, completionHandler: {
        guard !overlayShown else { return }   // re-shown mid-fade
        overlayWindow.orderOut(nil)
    })
}

func toggleOverlay() {
    overlayShown ? hideOverlay() : showOverlay()
}

// tap vs hold for the hotkey. the Carbon registration only ever sees the
// PRESS — so the release is polled: CGEventSource.keyState, the same
// permission-free source family cmdHeld() reads. the grammar:
//
//   tap   → toggle (a press on a hidden card shows it and it STAYS;
//            another tap hides it again)
//   hold  → peek (the card appears on press and collapses on release)
//
// a press while the card is already up defers the decision to the release:
// a quick tap hides it, a long hold just peeks and collapses either way.
// key-repeat hotkey events land while a session is live and are ignored —
// the session is keyed to the one physical key-down.
var overlayHotKeySession: (start: Date, wasVisible: Bool)?
var overlayHotKeyReleaseTimer: Timer?
let overlayHotKeyTapThreshold: TimeInterval = 0.3

func overlayHotKeyDown() {
    guard overlayHotKeySession == nil else { return }   // auto-repeat mid-hold
    let wasVisible = overlayShown
    if !wasVisible { showOverlay() }
    overlayHotKeySession = (Date(), wasVisible)
    overlayHotKeyReleaseTimer?.invalidate()
    overlayHotKeyReleaseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
        guard let session = overlayHotKeySession else {
            overlayHotKeyReleaseTimer?.invalidate()
            overlayHotKeyReleaseTimer = nil
            return
        }
        guard !CGEventSource.keyState(.hidSystemState, key: UInt16(kVK_Space)) else { return }
        overlayHotKeyReleaseTimer?.invalidate()
        overlayHotKeyReleaseTimer = nil
        let held = Date().timeIntervalSince(session.start)
        overlayHotKeySession = nil
        // quick tap on a card that was already up → the toggle-off; anything
        // else that ends a session collapses the card (long hold, or the
        // tap-open that a second tap closes)
        if session.wasVisible || held >= overlayHotKeyTapThreshold {
            hideOverlay()
        }
        // quick tap on a hidden-before card: the show from keyDown stands
    }
}

// restart / shut down behind a NATIVE AppleScript confirmation (NSAlert
// under the hood). osascript treats each -e as one script LINE — the
// dialog rides one line, the action the next. Cancel (or 30s away) does
// nothing. first ever use asks a one-time System Events Automation grant.
func confirmThen(_ message: String, _ button: String, _ action: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = [
        "-e",
        "display dialog \"\(message)\" with title \"smalt\" buttons {\"Cancel\", \"\(button)\"} " +
            "default button \"\(button)\" cancel button \"Cancel\" with icon caution giving up after 30",
        "-e",
        action,
    ]
    try? p.run()
}

// the hotkey: ⌘⇧Space, registered system-wide via Carbon — no permissions,
// no event tap. (⌘Space alone stays Spotlight's; the shift lands the
// combo on us.)
var overlayHotKeyRef: EventHotKeyRef?

func installOverlayHotKey() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let handler: EventHandlerUPP = { _, _, _ in
        DispatchQueue.main.async { overlayHotKeyDown() }
        return noErr
    }
    InstallEventHandler(GetApplicationEventTarget(), handler, 1, &spec, nil, nil)
    let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey | shiftKey),
                                     EventHotKeyID(signature: OSType(0x53_4D_4C_54) /* 'SMLT' */, id: 1),
                                     GetApplicationEventTarget(), 0, &overlayHotKeyRef)
    if status != noErr {
        FileHandle.standardError.write(Data("hotkey registration failed: \(status) — is ⌘⇧Space taken by another app?\n".utf8))
    }
    dbg("hotkey registration status: \(status)")
}

// MARK: - daemon

// one-shot diagnostic (SMALT_SNAPSHOT=2): render the overlay card bare —
// no dim — into a png and exit, same deal as snapshotStrip.
func snapshotOverlay() {
    let pad: CGFloat = 24
    let W = OverlayCard.width + pad * 2
    let H = OverlayCard.height + pad * 2
    let scale: CGFloat = 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale),
        pixelsHigh: Int(H * scale), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.saveGState()
    cg.translateBy(x: pad * scale, y: (H - pad) * scale)   // flipped coords, y down
    cg.scaleBy(x: scale, y: -scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    overlayView.setFrameSize(NSSize(width: W, height: H))
    overlayView.draw(overlayView.bounds)
    NSGraphicsContext.restoreGraphicsState()
    cg.restoreGState()
    try? rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "/tmp/smalt-overlay.png"))
    exit(0)
}

// one-shot diagnostic (SMALT_SNAPSHOT=1): render the strip's widgets into
// a png and exit — lets the agent see exactly what the glass draws without
// screen-recording permission.
func snapshotStrip() {
    // SMALT_SNAPSHOT_ARM=1 renders with the extension arm out (bluetooth),
    // bitmap extended left to include it — lets the agent see the fused
    // silhouette without screen-recording permission
    let armName = ProcessInfo.processInfo.environment["SMALT_SNAPSHOT_ARM"]
    let arm = armName != nil
    let a: ExtAnchor = armName == "audio" ? .audio : armName == "mic" ? .mic
        : armName == "power" ? .power : armName == "wifi" ? .wifi : .bluetooth
    if arm {
        let f = ProcessInfo.processInfo.environment["SMALT_SNAPSHOT_SCALE"]
            .flatMap { Double($0) } ?? 1
        extProgress = EXT_WIDTH * CGFloat(min(1, max(0.02, f)))
        extFade = 1
        extAnchor = a
        extWanted = a
        // snapshot fixture: the panel draws its device tray without a live
        // system_profiler run — same rows the real panel would wear
        if a == .bluetooth, btDevices.isEmpty {
            btDevices = [
                BtDevice(name: "AirPods Pro", kind: "Headset", address: "C1:2A:B3:0E:36:D1", connected: true),
                BtDevice(name: "Jamie’s Magic Mouse", kind: "Mouse", address: "00:81:2A:93:A0:49", connected: true),
                BtDevice(name: "Magic Keyboard with Touch ID", kind: "Keyboard", address: "AC:12:8F:22:71:B9", connected: true),
                BtDevice(name: "MCHOSE L7 Ultra+", kind: "Mouse", address: "C2:65:12:3A:08:E4", connected: false),
                BtDevice(name: "Rainy 75-1", kind: "Keyboard", address: "D1:00:77:DF:9E:FD", connected: false),
                BtDevice(name: "Soundcore Life Q30", kind: "Headset", address: "4B:7D:C0:11:8A:02", connected: false),
                BtDevice(name: "Sony WH-1000XM5", kind: "Headset", address: "08:DF:1F:44:A6:C7", connected: false),
                BtDevice(name: "Wonder boon with a truly endless name to clip", kind: "Mouse", address: "5E:03:99:1B:D2:44", connected: false),
            ]
            btControllerOn = true
        }
        extH = extHeight(for: a)
        extY = extTopOffset(for: a)
        relayoutExt(top: extY)               // position the full-size frame
        extProgress = EXT_WIDTH * CGFloat(min(1, max(0.02, f)))
        extFade = 1
        armView.needsDisplay = true
    }
    let scale: CGFloat = 2
    let pad: CGFloat = 14               // capture the shadow spill around the glass
    let W = pad * 2 + (arm ? EXT_WIDTH : 0) + tab.bounds.width
    let H = tab.bounds.height + pad * 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale),
        pixelsHigh: Int(H * scale), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.saveGState()
    // the glass's flipped space: y counts down, points not pixels; the tab's
    // right edge sits `pad` inside the bitmap's right edge
    cg.translateBy(x: (W - pad - tab.bounds.width) * scale, y: (H - pad) * scale)
    cg.scaleBy(x: scale, y: -scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    tab.draw(tab.bounds)
    if arm {
        cg.saveGState()
        cg.translateBy(x: -extProgress - 8, y: extY - 8)
        armView.draw(armView.bounds)
        cg.restoreGState()
    }
    NSGraphicsContext.restoreGraphicsState()
    cg.restoreGState()
    try? rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "/tmp/smalt-strip.png"))
    exit(0)
}

func runDaemon(showOverlayNow: Bool = false) -> Never {
    if ProcessInfo.processInfo.environment["SMALT_SNAPSHOT"] == "2" {
        overlaySnapshotMode = true
        snapshotOverlay()
    }
    if ProcessInfo.processInfo.environment["SMALT_SNAPSHOT"] != nil { snapshotStrip() }
    // NSApplication is required for workspace/screen notifications to fire.
    // accessory = no dock icon.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    // never App Nap: an accessory app with no active windows gets its
    // timers suspended while idle — the clock tick would freeze until the
    // mouse moves. one activity claim pins the run loop for the daemon's
    // lifetime.
    _ = ProcessInfo.processInfo.beginActivity(
        options: .userInitiated,
        reason: "smalt: menu strip timers")

    // pre-warm the bluetooth TCC gate: the first pairedDevices() call is what
    // makes macOS ask for the Bluetooth permission — do it at launch, once,
    // not under the user's first click (a permission dialog is the last thing
    // anyone expects to find under a spinner). legacy: skipped while the
    // extension arm is retired.
    if LEGACY_EXTENSION {
        btLinkQueue.async { _ = IOBluetoothDevice.pairedDevices() }
    }

    // hardware sync: the sunset→sunrise ramp and the Night Shift pane change
    // the strength behind our back. there is no push channel at our privilege
    // level — CoreBrightness posts no darwin notification — so sample.
    // adaptive rate: 30Hz while the glass is on
    // stage, 2Hz hidden. the RENDER is decoupled from the SAMPLE: the handle
    // springs to each new value at 120fps, so even coarse samples glide like
    // the system's own bezel.
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
        guard tab.dragSlot == nil, !overlayDragSlider else { return }   // mid-drag: we ARE the writer
        if NightShift.available {
            let off = NightShift.isOff()
            let s = off ? CGFloat(0) : CGFloat(NightShift.get())
            if off != Theme.nightOff || abs(s - Theme.sliderValue) > 0.001 {
                Theme.nightOff = off
                Theme.sliderValue = s
                if stripVisible { tab.beginValueSpring() }
                else { Theme.sliderDisplay = s; overlayValueSpring.start() }
                if overlayShown { overlayView.needsDisplay = true }
            }
        }
    }
    scheduleHwSync()
    hwSync.resume()

    // the pill is parked (PILL_ENABLED = false) — the overlay is the front
    // end. when PILL_ENABLED returns, all of this comes back unchanged.
    if PILL_ENABLED {
        // the window is docked from this moment on — it owns the screen edge
        // while on stage (that's the cursor fix); only the glass ever moves.
        // parked at launch = ordered out: an ordered-in window with off-screen
        // content is what the lock-screen zoom reveals.
        strip.setFrame(stripWindowFrame(), display: true)
        setGlassX(glassX(docked: false))   // glass parked off-screen at launch
        applyVisibility(false, animate: false)   // parked = click-through at the edge → window OUT
    }

    // the summon. a global mouse monitor — not an event tap — so there is
    // nothing to intercept and nothing to grant. the cursor entering the
    // right edge, level with the pill, springs it out; dropping left of the
    // pill (or past its band) springs it away. hysteresis between the two
    // lines means edge jitter can't flicker it — and the spring retargets,
    // so even fast in-out is a smooth reversal, never a glitch.
    // the summon monitor + the attention poll — PILL machinery, parked with
    // the pill. the overlay is event-driven by the hotkey, not the cursor.
    if PILL_ENABLED {
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
        if stripVisible, c.xr <= PILL_INSET + PILL_WIDTH, c.y >= top, c.y <= bottom {
            tab.reassertCursor()
        }
        switch hoverVisibility(xr: c.xr, y: c.y, top: top, bottom: bottom) {
        case true:  applyVisibility(true)
        case false: applyVisibility(false)
        case nil:   break
        }
        }   // — the monitor closure
    }

    let wnc = NSWorkspace.shared.notificationCenter
    _ = [
        // space/app transitions re-evaluate the pill's hover state (parked with it)
        NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
        NSWorkspace.didTerminateApplicationNotification,
    ].filter { _ in PILL_ENABLED }.forEach { name in
        wnc.addObserver(forName: name, object: nil, queue: .main) { _ in scheduleUpdate() }
    }
    _ = [
        // lock/unlock: screen lock comes via distributed notifications, fast
        // user switching via the session lifecycle — cover both.
        (NSWorkspace.sessionDidResignActiveNotification, true),
        (NSWorkspace.sessionDidBecomeActiveNotification, false),
    ].forEach { name, lock in
        wnc.addObserver(forName: name, object: nil, queue: .main) { _ in setSessionLocked(lock) }
    }
    let dnc = DistributedNotificationCenter.default()
    dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in setSessionLocked(true) }
    dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in setSessionLocked(false) }

    // battery: plug/unplug + low power mode via the process power state,
    // granular charge-level changes via IOKit's own power-source source
    NotificationCenter.default.addObserver(
        forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
    ) { _ in invalidateBatteryState() }
    if let iops = IOPSNotificationCreateRunLoopSource({ _ in
        invalidateBatteryState()
    }, nil)?.takeRetainedValue() {
        CFRunLoopAddSource(CFRunLoopGetMain(), iops, .defaultMode)
    }

    // display reconfiguration: resolution switch, monitor plug/unplug
    NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification,
        object: nil, queue: .main
    ) { _ in
        if PILL_ENABLED {
            closeExtension(instant: true)                   // geometry changed — don't ride it out
            updateStrip()
            applyVisibility(stripVisible, animate: false)   // snap to the new geometry, don't slide
        }
        // the overlay: re-cover the new main screen, redraw on its geometry
        if let s = mainScreen() {
            overlayView.setFrameSize(s.frame.size)
            overlayWindow.setFrame(s.frame, display: false)
            overlayView.needsDisplay = true
        }
    }

    // the overlay's tick: 1s — clock/date refresh, and a lock-screen
    // self-heal (the overlay must never sit on top of the login screen)
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
        guard overlayShown else { return }
        if loginWindowOnScreen() { hideOverlay(); return }
        overlayView.needsDisplay = true
    }

    // the hotkey — ⌘⇧Space, system-wide, no permissions
    installOverlayHotKey()
    if showOverlayNow { showOverlay() }

    // the attention engine — the poll that drives the whole hover state
    // machine. PILL machinery, parked with the pill.
    if PILL_ENABLED {
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
        if !stripVisible { tab.bouncedThisSummon = false }   // fresh summon, fresh first-hover bounce
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
        if stripVisible, c.xr <= PILL_INSET + PILL_WIDTH, c.y >= top, c.y <= bottom {
            takeAttention()
            tab.reassertCursor()           // belt + suspenders during the activation handoff
        } else {
            releaseAttention()
        }
        // the extension — position-driven off the same tick (see updateExtension)
        updateExtension(xr: c.xr, y: c.y)
    }
    }   // — PILL_ENABLED

    // low power mode toggles repaint the battery instantly
    NotificationCenter.default.addObserver(
        forName: NSNotification.Name("NSProcessInfoPowerStateDidChangeNotification"), object: nil, queue: .main
    ) { _ in
        strip.contentView?.needsDisplay = true
        if overlayShown { overlayView.needsDisplay = true }
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

// drives the real NightShift path the slider uses — the same code, from
// the terminal, so off/on/strength can be verified without dragging:
//   smalt night status | off | <0..1>
func cmdNight(_ arg: String?) -> Never {
    guard NightShift.available else {
        print("CBBlueLightClient unavailable — cannot drive night shift"); exit(1)
    }
    switch arg {
    case "status", nil:
        let m = NightShift.mode()
        print("schedule: \(m) (0 off · 1 custom · 2 sunset-sunrise)")
        print("strength: \(String(format: "%.2f", NightShift.get()))")
        print("state:    \(NightShift.isOff() ? "OFF" : "armed")")
    case "off":
        NightShift.set(0)
        print("night shift: OFF (schedule \(NightShift.mode()), remembered: \(NightShift.lastSchedule))")
    default:
        guard let arg else {
            print("usage: smalt night [status | off | <0..1>]"); exit(1)
        }
        guard let v = Float(arg), v > 0, v <= 1 else {
            print("usage: smalt night [status | off | <0..1>]"); exit(1)
        }
        NightShift.set(v)
        print("night shift: ON at \(String(format: "%.2f", v)) (schedule \(NightShift.mode()))")
    }
    exit(0)
}

// the tray's view of the world, from the terminal — the same IOBluetooth
// read the panel draws, for verifying state (and the TCC grant) without
// hovering the edge:
//   smalt bt
func cmdBt() -> Never {
    guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice], !paired.isEmpty else {
        print("no paired devices visible — is the Bluetooth permission granted?")
        print("check: System Settings → Privacy & Security → Bluetooth")
        exit(1)
    }
    var on = false
    if let hc = IOBluetoothHostController.default() {
        on = hc.powerState == kBluetoothHCIPowerStateON
    }
    print("controller: \(on ? "on" : "OFF")")
    let rows = paired.map { ($0.isConnected(), $0.addressString ?? "??", $0.name ?? "??") }
        .sorted { a, b in
            if a.0 != b.0 { return a.0 }
            return a.2.localizedCaseInsensitiveCompare(b.2) == .orderedAscending
        }
    for r in rows { print("\(r.0 ? "●" : "○") \(r.1)  \(r.2)") }
    exit(0)
}

func cmdStatus() {
    let installed = FileManager.default.fileExists(atPath: plistPath)
    let loaded = agentLoaded()
    let running = daemonRunning()

    print("agent:    \(installed ? "installed (\(plistPath))" : "not installed — run install.sh")")
    print("launchd:  \(loaded ? "loaded" : "not loaded")")
    print("process:  \(running ? "running" : "not running")")

    if running {
        print("overlay:  armed — ⌘⇧Space dims the screen and floats the card")
    } else if loaded {
        print("overlay:  down — launchd is retrying; check \(errLog)")
        if let tail = try? String(contentsOfFile: errLog, encoding: .utf8).suffix(200) {
            print("log:      \(tail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    } else {
        print("overlay:  off (starts again at next login)")
    }
}

// MARK: - entry

switch CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "run" {
case "run":              runDaemon()
case "overlay":          runDaemon(showOverlayNow: true)   // daemon + open the card now
case "on", "enable":     cmdOn()
case "off", "disable":   cmdOff()
case "status":           cmdStatus()
case "night":            cmdNight(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil)
case "bt":               cmdBt()
default:
    print("""
    usage: smalt [command]

      (none)          daemon mode — ⌘⇧Space: tap toggles the overlay, hold peeks it
                      (collapses on release) — what launchd runs
      overlay         daemon + open the overlay card immediately
      on, enable      start the daemon
      off, disable    stop the daemon (starts again at next login)
      status          installed / loaded / running
      night <0..1>    night shift strength
      bt              paired devices, live connection state

    install & uninstall: ./install.sh in the repo folder
    """)
    exit(1)
}
