import AppKit
import QuartzCore

// smalt — ground cobalt glass.
//
// for centuries, if you wanted a strip of cobalt blue across something —
// stained glass, porcelain, delft tile — you ground cobalt glass into
// powder and laid it down. smalt is that strip: a pane of cobalt glass
// laid across the top of the screen.
//
// v0 scope is deliberately tiny. no widgets, no config — just the strip
// and its behavior:
//
//   hidden everywhere by default. the cursor entering the top edge —
//   desktop or fullscreen — summons it: on the desktop it slides out from
//   under the native menu bar; in fullscreen it slides from behind the top
//   edge. dropping below the strip dismisses it again.
//   mission control    off the stage — it's not part of the expose grid
//
// zero permissions: the reveal is a global mouse monitor, not an event
// tap. nothing is intercepted, nothing is rewritten, nothing is polled.

let BAR_HEIGHT: CGFloat = 36
// the summon zone: cursor within this distance of the strip's top edge.
// desktop: the strip hides under the menu bar, so this reads as "12px below
// the menu bar" — below cobalt-60's 5px wall clamp, so the hover always
// lands, wall relaxed or not. fullscreen: 12px from the top edge.
let REVEAL_HEIGHT: CGFloat = 12
let HIDE_MARGIN: CGFloat = 6     // cursor must drop this far below the strip before it slides away
let SLIDE_DURATION: TimeInterval = 0.22

// MARK: - the strip

final class StripView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        // the glass: soft violet (D0BCFF), nothing more
        NSColor(srgbRed: 0xD0/255.0, green: 0xBC/255.0, blue: 0xFF/255.0, alpha: 1).setFill()
        bounds.fill()
    }
}

// MARK: - state

var inFullscreenMode = false   // a fullscreen app owns the main display
var stripVisible = false       // hidden until the cursor hovers the top edge
var evalItem: DispatchWorkItem?

func mainScreen() -> NSScreen? {
    NSScreen.screens.first { $0.frame.origin.y == 0 } ?? NSScreen.main
}

// where the strip sits. three anchors:
//   fullscreen, visible   the very top edge — the native bar is gone, the glass takes its place
//   desktop, visible      tucked directly under the native menu bar
//   hidden (any mode)     fully above the screen — on the desktop that's behind the menu bar's airspace, never painted over anything
func stripFrame(visible: Bool) -> NSRect {
    guard let screen = mainScreen() else { return .zero }
    let f = screen.frame
    let anchor = inFullscreenMode ? f.maxY : screen.visibleFrame.maxY
    let y = visible ? anchor - BAR_HEIGHT : f.maxY + 2
    return NSRect(x: f.minX, y: y, width: f.width, height: BAR_HEIGHT)
}

func refreshStrip(animate: Bool) {
    let target = stripFrame(visible: stripVisible)
    if animate {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = SLIDE_DURATION
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            strip.animator().setFrame(target, display: true)
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

// current cursor position, as distance from the very top of the main display.
// CGEvent coordinates are top-left origin.
func cursorYFromTop() -> CGFloat {
    CGEvent(source: nil)?.location.y ?? .infinity
}

// distance from the top of the screen to the strip's visible top edge
// (fullscreen: 0 — no menu bar. desktop: the menu bar's height.)
func barTopFromTop() -> CGFloat {
    guard let screen = mainScreen() else { return 0 }
    return inFullscreenMode ? 0 : screen.frame.height - screen.visibleFrame.maxY
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
    let mc = missionControlActive()
    inFullscreenMode = !mc && mainDisplayFullscreen()

    if mc {
        applyVisibility(false)                                 // mission control: off the stage
    } else {
        // hover decides, everywhere. the strip has no "default" state —
        // visible iff the cursor is in the summon zone.
        applyVisibility(cursorYFromTop() <= barTopFromTop() + REVEAL_HEIGHT)
    }
}

// debounce — space/app transitions fire notification bursts
func scheduleUpdate() {
    evalItem?.cancel()
    let item = DispatchWorkItem { updateStrip() }
    evalItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
}

// MARK: - the strip (window)

let strip: NSWindow = {
    let win = NSWindow(contentRect: stripFrame(visible: false), styleMask: [.borderless], backing: .buffered, defer: false)
    win.backgroundColor = .clear
    win.isOpaque = true
    win.hasShadow = false
    win.ignoresMouseEvents = true   // v0: the glass is look-only; widgets flip this in v1
    // level 21 — same lesson cobalt-60 already learned the hard way: MUST be
    // ≥ 20, because elgiloy's begin() guard only ignores the topmost window
    // when it's system chrome (layer ≥ 20). a floating-level (3) strip reads
    // as "a launcher overlay is open" and elgiloy swallows ctrl+tab entirely.
    // 21 keeps the design constraint: above every app window and fullscreen
    // windows, still below the menu bar (24) so the slide never paints over
    // the native bar, and below elgiloy's overlay (25).
    win.level = NSWindow.Level(rawValue: 21)
    // every desktop space, pinned to the screen, present over fullscreen apps
    win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    win.contentView = StripView(frame: NSRect(origin: .zero, size: stripFrame(visible: false).size))
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
    // nothing to intercept and nothing to grant. the strip ignores mouse
    // events, so every move lands in some other app and passes through here.
    // cursor into the summon zone → slide down; below the strip → slide away.
    // hysteresis between the two lines means edge jitter can't flicker it.
    NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .otherMouseDragged]) { _ in
        let y = cursorYFromTop()
        let top = barTopFromTop()
        if y <= top + REVEAL_HEIGHT {
            applyVisibility(true)
        } else if y > top + BAR_HEIGHT + HIDE_MARGIN {
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
        print("strip:    up — \(Int(BAR_HEIGHT))px of cobalt glass at the top (summon zone: \(Int(REVEAL_HEIGHT))px)")
    } else if loaded {
        print("strip:    down — launchd is retrying; check \(errLog)")
        if let tail = try? String(contentsOfFile: errLog, encoding: .utf8).suffix(200) {
            print("log:      \(tail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    } else {
        print("strip:    off (starts again at next login)")
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

      (none)          daemon mode — the strip (what launchd runs)
      on, enable      start the daemon
      off, disable    stop the daemon (starts again at next login)
      status          installed / loaded / running

    install & uninstall: ./install.sh in the repo folder
    """)
    exit(1)
}
