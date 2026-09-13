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
    static let cell: CGFloat = 28
    static let gap: CGFloat = 4
    static let pad: CGFloat = 10

    // icons — real heroicons: the verbatim svg `d` strings (see SVGPath
    // below), rendered on heroicons' own 24×24 grid at their own
    // stroke-width 1.5, scaled so the grid is iconSize points.
    static let iconSize: CGFloat = 20

    // type — SF Pro tabular digits at a weight whose stems sit at the icon
    // stroke weight (medium at 14pt ≈ 1.2pt vs 1.25pt strokes)
    static let typeSize: CGFloat = 14     // clock digits
    static let pctSize: CGFloat = 8       // battery percentage (6.5 for "100")

    // the pill is exactly its grid
    static var pillWidth: CGFloat { cell + 2 * pad }
    static var pillHeight: CGFloat { 2 * pad + 4 * cell + 3 * gap }

    // the four slots, top to bottom — battery / calendar / hour / minute.
    // each widget receives exactly this rect and draws centered in it.
    static func slot(_ index: Int, in bounds: NSRect) -> NSRect {
        NSRect(x: pad, y: pad + CGFloat(index) * (cell + gap), width: cell, height: cell)
    }
}

let PILL_WIDTH = Theme.pillWidth
let PILL_HEIGHT = Theme.pillHeight
let PILL_INSET: CGFloat = 6      // gap between pill and the right screen edge
let PILL_RADIUS: CGFloat = 14
let REVEAL_WIDTH: CGFloat = 12   // summon zone: cursor within this of the right edge
let HIDE_MARGIN: CGFloat = 6     // cursor must drop this far left of the pill before it springs away
// spring constants: ω ≈ 23.7 rad/s, ζ ≈ 0.68 — a crisp pop with ~5% overshoot
let SPRING_K: CGFloat = 560
let SPRING_C: CGFloat = 32

// MARK: - the pill

final class StripView: NSView {
    override var isFlipped: Bool { true }   // y counts down from the pill top

    // the glass: #FAF6F3, rounded — no border, the shadow does the lifting
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: PILL_RADIUS, yRadius: PILL_RADIUS)
        Theme.glass.setFill()
        path.fill()

        // the grid: battery / calendar / hour / minute — one uniform slot
        // each, every widget centered in its own fixed spot
        for i in 0..<4 {
            let r = Theme.slot(i, in: bounds)
            switch i {
            case 0: drawBattery(in: r)
            case 1: drawCalendar(in: r)
            default: drawClock(i == 2 ? .hour : .minute, in: r)
            }
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
    // heroicons "calendar" (outline)
    static let calendar = "M6.75 3v2.25M17.25 3v2.25M3 18.75V7.5a2.25 2.25 0 0 1 2.25-2.25h13.5A2.25 2.25 0 0 1 21 7.5v11.25m-18 0A2.25 2.25 0 0 0 5.25 21h13.5A2.25 2.25 0 0 0 21 18.75m-18 0v-7.5A2.25 2.25 0 0 1 5.25 9h13.5A2.25 2.25 0 0 1 21 11.25v7.5"
    // heroicons "battery" (outline)
    static let battery = "M21 10.5h.375c.621 0 1.125.504 1.125 1.125v2.25c0 .621-.504 1.125-1.125 1.125H21M3.75 18h15A2.25 2.25 0 0 0 21 15.75v-6a2.25 2.25 0 0 0-2.25-2.25h-15A2.25 2.25 0 0 0 1.5 9.75v6A2.25 2.25 0 0 0 3.75 18Z"

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
    static func draw(_ d: String, color: NSColor, in slot: NSRect) {
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.saveGState()
        let s = Theme.iconSize / 24
        ctx.translateBy(x: slot.midX, y: slot.midY)
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -12, y: -12)   // flipped view + svg y-down: already aligned
        ctx.addPath(SVGPath.cgPath(d))
        ctx.setLineWidth(1.5)             // the svg's own stroke-width, in grid units
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        color.setStroke()
        ctx.strokePath()
        ctx.restoreGState()
    }

    // svg-grid rect → view rect, for text placed inside a glyph feature
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
    static func tabular(_ size: CGFloat) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
    }
}

// MARK: - widgets
//
// calendar + battery are SF Symbols — the same vectors the menu bar itself
// uses (NSImage(systemSymbolName:), tinted to the palette). the heroicon
// SVGs stay as fallbacks in case the symbol lookup ever misses. type is
// matching tabular SF Pro, everything centered in its slot. sources are
// permission-free: IOKit power sources, the clock, ProcessInfo LPM state.

// an SF Symbol at a given point size, tinted to one palette color
func symbolImage(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
    return base
        .withSymbolConfiguration(.init(pointSize: size, weight: .regular))?
        .withSymbolConfiguration(.init(paletteColors: [color]))
}

// an image rect of the image's own size, centered in the slot
func centered(_ size: NSSize, in slot: NSRect) -> NSRect {
    NSRect(x: slot.midX - size.width / 2, y: slot.midY - size.height / 2,
           width: size.width, height: size.height)
}

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

// SF Symbols battery.0 — no fill, the percentage IS the gauge; it sits
// optically centered in the symbol's body. low power mode: icon + number
// in one amber.
func drawBattery(in slot: NSRect) {
    guard let (pct, _) = batteryLevel() else { return }
    let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    let color = lowPower ? Theme.lpm : Theme.ink
    guard let img = symbolImage("battery.0", size: Theme.iconSize, color: color) else {
        Heroicon.draw(SVGPath.battery, color: color, in: slot)
        return
    }
    let r = centered(img.size, in: slot)
    img.draw(in: r)

    // the number inside the body — the nub takes the last ~18% of the
    // glyph's width; the body spans the full glyph height
    let body = NSRect(x: r.minX, y: r.minY, width: r.width * 0.82, height: r.height)
    let size: CGFloat = pct >= 100 ? Theme.pctSize - 1.5 : Theme.pctSize
    drawText("\(pct)", font: .tabular(size), color: color, in: body)
}

// SF Symbols calendar, the same one the menu bar's date UI uses
func drawCalendar(in slot: NSRect) {
    guard let img = symbolImage("calendar", size: Theme.iconSize, color: Theme.ink) else {
        Heroicon.draw(SVGPath.calendar, color: Theme.ink, in: slot)
        return
    }
    img.draw(in: centered(img.size, in: slot))
}

// time: hour over minute — one CELL slot each, tabular SF Pro centered
func drawClock(_ component: Calendar.Component, in slot: NSRect) {
    let value = String(format: "%02d", Calendar.current.component(component, from: Date()))
    drawText(value, font: .tabular(Theme.typeSize), color: Theme.ink, in: slot)
}

// MARK: - state

var stripVisible = false       // hidden until the cursor hovers the right edge
var evalItem: DispatchWorkItem?

func mainScreen() -> NSScreen? {
    // the CG main display — cursor global coordinates are relative to THIS
    // screen's arrangement, so the pill must anchor to the same one.
    NSScreen.screens.first { displayID($0) == CGMainDisplayID() } ?? NSScreen.main
}

// where the pill sits: docked against the right edge, vertically centered.
// hidden = fully off-screen right.
func pillFrame(visible: Bool) -> NSRect {
    guard let screen = mainScreen() else { return .zero }
    let f = screen.frame
    let x = visible ? f.maxX - PILL_WIDTH - PILL_INSET : f.maxX + 4
    let y = f.minY + (f.height - PILL_HEIGHT) / 2
    return NSRect(x: x, y: y, width: PILL_WIDTH, height: PILL_HEIGHT)
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

    func chase(_ targetX: CGFloat) {
        target = targetX
        guard !running else { return }             // already chasing — just retargeted
        x = strip.frame.origin.x
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
        var f = strip.frame
        f.origin.x = x.rounded()               // whole pixels: no subpixel shimmer on the glass
        strip.setFrame(f, display: false)
        if abs(x - target) < 0.25, abs(v) < 2 {
            f.origin.x = target
            strip.setFrame(f, display: true)
            stop()
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
    let changed = desired != stripVisible
    stripVisible = desired
    guard changed else { return }
    let target = pillFrame(visible: desired)
    if animate {
        // sync y/size, then let the spring chase the x
        var f = strip.frame
        f.origin.y = target.origin.y
        f.size = target.size
        strip.setFrame(f, display: true)
        spring.chase(target.origin.x)
    } else {
        spring.stop()
        strip.setFrame(target, display: true)
    }
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
    let fr = pillFrame(visible: true)
    let top = globalCocoaTopY - fr.maxY
    return (top, top + fr.height)
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

func updateStrip() {
    if missionControlActive() {
        applyVisibility(false)                                 // mission control: off the stage
    } else {
        // hover decides: visible iff the cursor is in the summon zone —
        // within 12px of the right edge, level with the pill.
        let (top, bottom) = pillBandCG()
        guard let loc = CGEvent(source: nil)?.location else { return }
        let inBand = loc.y >= top - 26 && loc.y <= bottom + 26
        let xr = cursorXFromRight()
        applyVisibility(xr <= REVEAL_WIDTH && inBand)
    }
}

// debounce — space/app transitions fire notification bursts
func scheduleUpdate() {
    evalItem?.cancel()
    let item = DispatchWorkItem { updateStrip() }
    evalItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
}

// MARK: - the pill (window)

let strip: NSWindow = {
    let win = NSPanel(contentRect: pillFrame(visible: false), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    win.backgroundColor = .clear
    win.isOpaque = false             // rounded corners composite cleanly
    win.hasShadow = true             // a floating pill wants a shadow
    win.ignoresMouseEvents = false   // clickable for whatever lands in it later
    // level 21 — above every app window and fullscreen windows, still below
    // the native menu bar (24). the pill lives mid-right-edge, nowhere near
    // the native bar, so there's nothing to fight with.
    win.level = NSWindow.Level(rawValue: 21)
    // every desktop space, pinned to the screen, present over fullscreen apps
    win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    win.contentView = StripView(frame: NSRect(origin: .zero, size: pillFrame(visible: false).size))
    return win
}()

// MARK: - daemon

func runDaemon() -> Never {
    // NSApplication is required for workspace/screen notifications to fire.
    // accessory = no dock icon.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    updateStrip()
    strip.orderFrontRegardless()

    // the summon. a global mouse monitor — not an event tap — so there is
    // nothing to intercept and nothing to grant. the cursor entering the
    // right edge, level with the pill, springs it out; dropping left of the
    // pill (or past its band) springs it away. hysteresis between the two
    // lines means edge jitter can't flicker it — and the spring retargets,
    // so even fast in-out is a smooth reversal, never a glitch.
    NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .otherMouseDragged]) { _ in
        let (top, bottom) = pillBandCG()
        guard let loc = CGEvent(source: nil)?.location else { return }
        let y = loc.y
        let xr = cursorXFromRight()
        if xr <= REVEAL_WIDTH, y >= top - 26, y <= bottom + 26 {
            applyVisibility(true)
        } else if xr > PILL_WIDTH + HIDE_MARGIN || y > bottom + 26 || y < top - 26 {
            applyVisibility(false)
        }
    }

    let wnc = NSWorkspace.shared.notificationCenter
    _ = [
        wnc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in scheduleUpdate() },
        wnc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in scheduleUpdate() },
        wnc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { _ in scheduleUpdate() },
    ]

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
