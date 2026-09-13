import AppKit
import CoreGraphics

// cobalt-60 — keeps the mouse cursor from entering the top 5px of the
// screen (the menu bar area). event-tap based, zero polling. runs as a
// launchd agent; install/uninstall lives in install.sh.
//
//   cobalt-60          daemon mode (what launchd runs)
//   cobalt-60 on       start the wall (bootstrap + kickstart the agent)
//   cobalt-60 off      stop the wall (agent unloaded; restarts at next login)
//   cobalt-60 status   installed / loaded / running

let TOP_MARGIN: CGFloat = 5
// the wall keeps its hands off the top-right corner so the native menu bar
// stays usable (clock, control center, status items): within this many px of
// the main screen's right edge, mouse events pass through unclamped and the
// cursor can enter the menu bar like normal. outside the zone the 5px wall
// applies as before.
let CORNER_EXEMPT: CGFloat = 5

// feature switches — persisted via `defaults` (domain dev.cobalt.cobalt-60),
// read by the daemon at startup. the CLI flips them and kickstarts the
// agent, so a toggle takes effect immediately and survives logins.
let defaultsSuite = "dev.cobalt.cobalt-60"
var wallOn = true
var cornersOn = true

func loadFeatures() {
    let d = UserDefaults(suiteName: defaultsSuite) ?? .standard
    wallOn = d.object(forKey: "wallEnabled") as? Bool ?? true
    cornersOn = d.object(forKey: "cornersEnabled") as? Bool ?? true
}
let label = "dev.cobalt.cobalt-60"
let name = "cobalt-60"
let errLog = "/tmp/cobalt-60.err"
let plistPath = FileManager.default.homeDirectoryForCurrentUser.path
    + "/Library/LaunchAgents/\(label).plist"

// MARK: - tap state (file scope — CGEventTapCallBack is a C function pointer
// and cannot capture local context)

var minYFromTop: CGFloat = 0
// events right of this x pass through unclamped (recomputed with minY)
var exemptFromX: CGFloat = .greatestFiniteMagnitude

func recomputeMinY() {
    guard let mainScreen = NSScreen.screens.first(where: { $0.frame.origin.y == 0 }) ?? NSScreen.main else { return }
    let screenHeight = mainScreen.frame.height
    // bottom edge of the menu bar, as distance from the top of the screen
    minYFromTop = screenHeight - mainScreen.visibleFrame.maxY + TOP_MARGIN
    exemptFromX = mainScreen.frame.maxX - CORNER_EXEMPT
}

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    switch type {
    case .mouseMoved, .leftMouseDragged, .otherMouseDragged:
        if wallOn {
            let loc = event.location
            // top-right exemption: clock / control center stay reachable
            if loc.y < minYFromTop && loc.x < exemptFromX {
                event.location = CGPoint(x: loc.x, y: minYFromTop)
            }
        }
    default:
        break
    }
    return Unmanaged.passRetained(event)
}

// MARK: - corner filler (minimal)

// the window server rounds fullscreen windows; wallpaper shows through the
// cutouts. tiny black squares pinned at each screen corner, faded in while a
// fullscreen window is onscreen. nothing else.

// shaped black patches layered ABOVE the fullscreen window (a transparent
// app would see straight through anything behind it, so above is the only
// option). each patch is a square minus a disc — the black hugs the window
// server's rounding arc exactly. if a wallpaper sliver ever shows, bump
// CORNER_OVERLAP to 1 or 2.
let CORNER_RADIUS: CGFloat = 14
let CORNER_OVERLAP: CGFloat = 0

var cornerWindows: [NSWindow] = []
var cornersShown = false
var cornerEval: DispatchWorkItem?

final class CornerView: NSView {
    let corner: Int // which screen corner this patch is: 0 TL, 1 TR, 2 BL, 3 BR

    init(corner: Int, frame rect: NSRect) {
        self.corner = corner
        super.init(frame: rect)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func draw(_ dirtyRect: NSRect) {
        let r = CORNER_RADIUS
        let d = r - CORNER_OVERLAP
        let w = bounds.width, h = bounds.height
        guard let ctx = NSGraphicsContext.current else { return }

        // 1. black over the whole patch…
        NSColor.black.setFill()
        bounds.fill()

        // 2. …then erase a disc inset from the screen corner, so the black
        //    only fills the rounded cutout and follows the arc
        let c: NSPoint
        switch corner {
        case 0:  c = NSPoint(x: r,     y: h - r) // TL — screen corner at patch top-left
        case 1:  c = NSPoint(x: w - r, y: h - r) // TR
        case 2:  c = NSPoint(x: r,     y: r)     // BL
        default: c = NSPoint(x: w - r, y: r)     // BR
        }
        ctx.compositingOperation = .clear
        NSColor.clear.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - d, y: c.y - d, width: 2 * d, height: 2 * d)).fill()
        ctx.compositingOperation = .sourceOver
    }
}

func makeCornerFillers() {
    for w in cornerWindows { w.orderOut(nil) }
    cornerWindows.removeAll()
    let s = CORNER_RADIUS + CORNER_OVERLAP
    var corner = 0
    for screen in NSScreen.screens {
        let f = screen.frame
        for rect in [
            NSRect(x: f.minX,     y: f.maxY - s, width: s, height: s),  // top-left
            NSRect(x: f.maxX - s, y: f.maxY - s, width: s, height: s),  // top-right
            NSRect(x: f.minX,     y: f.minY,     width: s, height: s),  // bottom-left
            NSRect(x: f.maxX - s, y: f.minY,     width: s, height: s),  // bottom-right
        ] {
            let w = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
            w.backgroundColor = .clear
            w.isOpaque = false
            w.hasShadow = false
            w.ignoresMouseEvents = true
            // level 21: above fullscreen windows (0) and the dock (20), below
            // the menu bar (24) and elgiloy's overlay (25). MUST be ≥ 20 —
            // elgiloy's begin() guard ignores the topmost window only when it's
            // system chrome (layer ≥ 20); a floating-level patch up here used to
            // make elgiloy think a launcher overlay was open and swallow ctrl+tab
            w.level = NSWindow.Level(rawValue: 21)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            w.alphaValue = 0
            w.contentView = CornerView(corner: corner, frame: NSRect(origin: .zero, size: rect.size))
            corner += 1
            cornerWindows.append(w)
        }
    }
}

func setCorners(_ shown: Bool) {
    guard shown != cornersShown else { return }
    cornersShown = shown
    for w in cornerWindows {
        if shown { w.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            w.animator().alphaValue = shown ? 1 : 0
        }
        if !shown {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if !cornersShown { w.orderOut(nil) }
            }
        }
    }
}

// true if any onscreen layer-0 window covers a display (i.e. fullscreen app)
func anyFullscreenWindow() -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
    let displays = NSScreen.screens.compactMap {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { CGDisplayBounds($0) }
    }
    return list.contains { d in
        guard (d[kCGWindowLayer as String] as? Int) == 0,
              let b = d[kCGWindowBounds as String] as? [String: NSNumber] else { return false }
        let r = CGRect(x: b["X"]?.doubleValue ?? 0, y: b["Y"]?.doubleValue ?? 0,
                       width: b["Width"]?.doubleValue ?? 0, height: b["Height"]?.doubleValue ?? 0)
        return displays.contains { db in
            abs(r.minX - db.minX) <= 2 && abs(r.minY - db.minY) <= 2
                && r.width >= db.width - 2 && r.height >= db.height - 2
        }
    }
}

func scheduleCornerUpdate() {
    cornerEval?.cancel()
    let item = DispatchWorkItem { setCorners(anyFullscreenWindow()) }
    cornerEval = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
}

// MARK: - daemon

func runDaemon() -> Never {
    loadFeatures()
    recomputeMinY()
    // recompute on display changes (resolution switch, monitor plug/unplug)
    NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification,
        object: nil, queue: nil
    ) { _ in
        recomputeMinY()
        if cornersOn {
            makeCornerFillers()
            scheduleCornerUpdate()
        }
    }

    if cornersOn { makeCornerFillers() }

    // corner updates are driven by workspace events (space change, app
    // activate/quit — entering/exiting fullscreen always fires one of these).
    // only observed when the corner filler is enabled.
    if cornersOn {
        let wnc = NSWorkspace.shared.notificationCenter
        let observers = [
            wnc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil) { _ in scheduleCornerUpdate() },
            wnc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { _ in scheduleCornerUpdate() },
            wnc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) { _ in scheduleCornerUpdate() },
        ]
        _ = observers // keep alive for the life of the process
    }

    guard let tap = CGEvent.tapCreate(
        tap: .cghidEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: CGEventMask((1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.otherMouseDragged.rawValue)),
        callback: tapCallback,
        userInfo: nil
    ) else {
        FileHandle.standardError.write("failed to create event tap — grant accessibility to the binary\n".data(using: .utf8)!)
        exit(1)
    }

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    // full app run loop — needed for workspace notifications to fire
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.run()
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

let gui = "gui/\(getuid())"

func agentLoaded() -> Bool {
    sh("launchctl print \(gui)/\(label) >/dev/null 2>&1") == 0
}

// the daemon registers as "cobalt-60" — but so does this CLI invocation,
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
        ? "agent is up — wall: \(wallOn ? "on" : "off"), corners: \(cornersOn ? "on" : "off")"
        : "starting… if it won't stay up, check \(errLog) (usually a missing accessibility grant)")
}

func cmdOff() {
    guard agentLoaded() || daemonRunning() else {
        print("already off"); exit(0)
    }
    sh("launchctl bootout \(gui)/\(label)")
    sh("pkill -x \(name) 2>/dev/null")
    print("agent is down (starts again at next login — plist kept; wall/corner switches are kept too)")
}

// flip one feature switch and bounce the daemon so it re-reads it
func toggleFeature(key: String, enable: Bool, name: String) {
    guard FileManager.default.fileExists(atPath: plistPath) else {
        print("not installed — run install.sh first"); exit(1)
    }
    let d = UserDefaults(suiteName: defaultsSuite) ?? .standard
    d.set(enable, forKey: key)
    if agentLoaded() {
        sh("launchctl kickstart -k \(gui)/\(label)")
    }
    print("\(name): \(enable ? "on" : "off")")
    print(daemonRunning()
        ? "  daemon reloaded"
        : "  note: daemon not running — switch applies at next start")
}

func cmdStatus() {
    let installed = FileManager.default.fileExists(atPath: plistPath)
    let loaded = agentLoaded()
    let running = daemonRunning()

    print("agent:    \(installed ? "installed (\(plistPath))" : "not installed — run install.sh")")
    print("launchd:  \(loaded ? "loaded" : "not loaded")")
    print("process:  \(running ? "running" : "not running")")

    if running {
        if wallOn {
            print("wall:     up — cursor held \(Int(TOP_MARGIN))px below the menu bar (top \(Int(CORNER_EXEMPT))px exempt)")
        } else {
            print("wall:     disabled — cursor boundary inactive")
        }
        if cornersOn {
            print("corners:  on — black while a fullscreen app is up (\(cornerWindows.count/4) displays watched)")
        } else {
            print("corners:  disabled — fullscreen cutouts show wallpaper")
        }
    } else if loaded {
        print("state:    down — launchd is retrying; check \(errLog)")
        if let tail = try? String(contentsOfFile: errLog, encoding: .utf8).suffix(200) {
            print("log:      \(tail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    } else {
        print("state:    off (starts again at next login)")
    }
    print("switches: wall \(wallOn ? "on" : "off") · corners \(cornersOn ? "on" : "off") (persisted)")
}

// MARK: - entry

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "run" {
case "run":              runDaemon()
case "on", "enable":     loadFeatures(); cmdOn()
case "off", "disable":   loadFeatures(); cmdOff()
case "status":           loadFeatures(); cmdStatus()
case "wall":
    loadFeatures()
    guard args.count > 2, ["on", "off"].contains(args[2]) else {
        print("usage: cobalt-60 wall on|off"); exit(1)
    }
    toggleFeature(key: "wallEnabled", enable: args[2] == "on", name: "wall")
case "corners", "corner":
    loadFeatures()
    guard args.count > 2, ["on", "off"].contains(args[2]) else {
        print("usage: cobalt-60 corners on|off"); exit(1)
    }
    toggleFeature(key: "cornersEnabled", enable: args[2] == "on", name: "corners")
default:
    print("""
    usage: cobalt-60 [command]

      (none)              daemon mode (what launchd runs)
      on, enable          start the agent
      off, disable        stop the agent (starts again at next login)
      status              installed / loaded / running + per-feature state
      wall on|off         toggle the cursor boundary on its own
      corners on|off      toggle the fullscreen corner filler on its own

    switches persist across logins (defaults domain \(defaultsSuite));
    the daemon re-reads them on start, so toggling restarts it instantly.

    install & uninstall: ./install.sh in the repo folder
    """)
    exit(1)
}
