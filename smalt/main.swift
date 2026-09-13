import AppKit
import QuartzCore
import ApplicationServices
import CoreWLAN
import IOKit
import IOKit.ps

// smalt — ground cobalt glass.
//
// for centuries, if you wanted a strip of cobalt blue across something —
// stained glass, porcelain, delft tile — you ground cobalt glass into
// powder and laid it down. smalt is that glass — a floating cobalt pill
// docked at the right edge of the screen, dead center, nothing in it.
//
//   hidden by default. the cursor entering the right edge, level with the
//   pill, summons it: a real spring drives it out (underdamped — it pops
//   past the dock and settles). dropping left of the pill dismisses it.
//   the spring retargets mid-flight, so fast in-out just reverses it
//   smoothly — no completion-handler races, no flicker.
//
//   the pill is deliberately empty for now — a pane of glass first,
//   contents later.
//   mission control    off the stage — it's not part of the expose grid
//
// zero permissions: the reveal is a global mouse monitor, not an event
// tap. nothing is intercepted, nothing is rewritten, nothing is polled.

let PILL_WIDTH: CGFloat = 84
let PILL_HEIGHT: CGFloat = 220
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

    // the glass: soft violet (D0BCFF), rounded — no border, the shadow does the lifting
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: PILL_RADIUS, yRadius: PILL_RADIUS)
        NSColor(srgbRed: 0xD0/255.0, green: 0xBC/255.0, blue: 0xFF/255.0, alpha: 1).setFill()
        path.fill()
        drawWidgets(in: bounds)
    }

    // clock / date / battery, stacked from the top, centered — permission-free
    private func drawWidgets(in bounds: NSRect) {
        var y: CGFloat = 12
        y = drawCentered(Widget.timeForm.string(from: Date()), color: Widget.ink, topY: y, rowH: 20, in: bounds)
        y = drawCentered(Widget.dateForm.string(from: Date()), color: Widget.ink, topY: y, rowH: 16, in: bounds)
        drawBatteryVertical(centerX: bounds.midX, topY: y, rowH: 26)
    }
}

// MARK: - widgets
//// dark ink on the glass. all sources are permission-free: IOKit power
// sources, clock. (CoreWLAN rssi could join later.)

enum Widget {
    static let ink = NSColor(srgbRed: 0.13, green: 0.06, blue: 0.24, alpha: 1)
    static let inkDim = NSColor(srgbRed: 0.13, green: 0.06, blue: 0.24, alpha: 0.45)
    static let glass = NSColor(srgbRed: 0xD0/255.0, green: 0xBC/255.0, blue: 0xFF/255.0, alpha: 1)

    static let timeForm: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    static let dateForm: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f
    }()
}

// centered text; returns the y below the row
func drawCentered(_ s: String, color: NSColor, topY: CGFloat, rowH: CGFloat,
                  in bounds: NSRect, font: NSFont = NSFont.systemFont(ofSize: 13, weight: .medium)) -> CGFloat {
    let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let size = (s as NSString).size(withAttributes: a)
    (s as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: topY + (rowH - size.height) / 2),
                         withAttributes: a)
    return topY + rowH
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

// battery glyph + percentage, centered as one row
func drawBatteryVertical(centerX: CGFloat, topY: CGFloat, rowH: CGFloat) {
    guard let (pct, charging) = batteryLevel() else { return }
    let label = "\(pct)%"
    let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: Widget.ink]
    let ts = (label as NSString).size(withAttributes: a)
    let glyphW: CGFloat = 22
    let total = glyphW + 5 + ts.width
    let x0 = centerX - total / 2
    let gy = topY + (rowH - 12) / 2

    let g = NSRect(x: x0, y: gy, width: glyphW, height: 12)
    Widget.ink.setStroke()
    let outline = NSBezierPath(roundedRect: g, xRadius: 3, yRadius: 3)
    outline.lineWidth = 1
    outline.stroke()
    Widget.ink.setFill()
    NSRect(x: g.maxX + 1, y: gy + 3.5, width: 2, height: 5).fill() // nub
    let fillW = (glyphW - 4) * CGFloat(pct) / 100
    NSRect(x: g.minX + 2, y: g.minY + 2, width: max(fillW, 2), height: g.height - 4).fill()

    if charging {
        // bolt knocked out of the fill in glass color
        Widget.glass.setFill()
        let bolt = NSBezierPath()
        bolt.move(to: NSPoint(x: g.midX + 2, y: g.maxY - 1))
        bolt.line(to: NSPoint(x: g.midX - 3, y: g.minY + 3.5))
        bolt.line(to: NSPoint(x: g.midX - 0.5, y: g.minY + 3.5))
        bolt.line(to: NSPoint(x: g.midX - 2, y: g.maxY - 1))
        bolt.line(to: NSPoint(x: g.midX + 3, y: g.minY + 3.5))
        bolt.line(to: NSPoint(x: g.midX + 0.5, y: g.minY + 3.5))
        bolt.close()
        bolt.fill()
    }
    (label as NSString).draw(at: NSPoint(x: g.maxX + 5, y: topY + (rowH - ts.height) / 2), withAttributes: a)
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
var globalCocoaTopY: CGFloat {
    NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
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
        print("pill:     up — empty cobalt glass, mid-right edge (summon zone: \(Int(REVEAL_WIDTH))px)")
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