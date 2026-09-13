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
//   pill, summons it: it springs out with an overshoot and settles.
//   dropping left of the pill dismisses it again.
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
// the spring: fast pop past the dock position, then a short settle back.
let POP_DURATION: TimeInterval = 0.16
let OVERSHOOT: CGFloat = 7
let HIDE_DURATION: TimeInterval = 0.18

// MARK: - the pill

final class StripView: NSView {
    // the glass: soft violet (D0BCFF), rounded, one subtle border — nothing else
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: PILL_RADIUS, yRadius: PILL_RADIUS)
        NSColor(srgbRed: 0xD0/255.0, green: 0xBC/255.0, blue: 0xFF/255.0, alpha: 1).setFill()
        path.fill()
        NSColor(srgbRed: 0.13, green: 0.06, blue: 0.24, alpha: 0.15).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

// MARK: - state

var stripVisible = false       // hidden until the cursor hovers the right edge
var evalItem: DispatchWorkItem?

func mainScreen() -> NSScreen? {
    NSScreen.screens.first { $0.frame.origin.y == 0 } ?? NSScreen.main
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

// springy: pop out fast with a small overshoot, then settle back into the
// dock. hide is a plain ease-in retract.
func refreshStrip(animate: Bool) {
    let target = pillFrame(visible: stripVisible)
    if animate {
        if stripVisible {
            var overshoot = target
            overshoot.origin.x -= OVERSHOOT
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = POP_DURATION
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                strip.animator().setFrame(overshoot, display: true)
            }, completionHandler: {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = POP_DURATION
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    strip.animator().setFrame(target, display: true)
                }
            })
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = HIDE_DURATION
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                strip.animator().setFrame(target, display: true)
            }
        }
    } else {
        strip.setFrame(target, display: true)
    }
}

func applyVisibility(_ desired: Bool, animate: Bool = true) {
    let changed = desired != stripVisible
    stripVisible = desired
    refreshStrip(animate: animate && changed)
}

// current cursor position. CGEvent coordinates are top-left origin.
func cursorYFromTop() -> CGFloat {
    CGEvent(source: nil)?.location.y ?? .infinity
}
func cursorXFromRight() -> CGFloat {
    guard let loc = CGEvent(source: nil)?.location, let screen = mainScreen() else { return .infinity }
    return screen.frame.width - loc.x
}

// the pill's vertical band, as distances from the top of the display.
// the summon only fires when the cursor is level with the pill — hovering
// the right edge above or below it does nothing.
func pillBandFromTop() -> (top: CGFloat, bottom: CGFloat) {
    guard let screen = mainScreen() else { return (0, 0) }
    let f = screen.frame
    let top = (f.height + PILL_HEIGHT) / 2
    return (top, top + PILL_HEIGHT)
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
        let (top, bottom) = pillBandFromTop()
        let y = cursorYFromTop()
        let inBand = y >= top - 26 && y <= bottom + 26
        applyVisibility(cursorXFromRight() <= REVEAL_WIDTH && inBand)
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
    // lines means edge jitter can't flicker it.
    NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .otherMouseDragged]) { _ in
        let (top, bottom) = pillBandFromTop()
        let y = cursorYFromTop()
        let xr = cursorXFromRight()
        if xr <= REVEAL_WIDTH, y >= top - 26, y <= bottom + 26 {
            applyVisibility(true)
        } else if xr > PILL_WIDTH + HIDE_MARGIN || y > bottom + 26 {
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
        refreshStrip(animate: false)   // snap to the new geometry, don't slide
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