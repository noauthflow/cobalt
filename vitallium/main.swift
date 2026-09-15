// vitallium — living wallpaper daemon
// a looping video behind everything: apps, widgets, desktop icons, the glass
// menu bar. one window per display at the desktop layer, AVPlayer under it.
// every display is configured individually, by name, and remembered.
//
//     vitallium monitors                     list displays + what's on them
//     vitallium set --monitor "NAME" FILE    bind a video to a display (flag required)
//     vitallium pause                        freeze every display
//     vitallium resume                       unfreeze
//     vitallium reload                       re-read the config
//     vitallium status                       per-display state
//
// zero permissions, zero network, zero supply chain: built from this file,
// on your machine, and nothing ever updates itself.

import AppKit
import AVFoundation
import QuartzCore
import IOKit.ps

// MARK: - config

// ~/.config/vitallium.conf — one block per display, keyed by the display's
// name (`vitallium monitors` prints it). the file IS the cache: blocks for
// displays that aren't plugged in stay put and re-apply when they return.
//
//     # global
//     battery-pause on
//
//     monitor "Built-in Retina Display"
//     video ~/Movies/TOP G.mp4
//     scrim 0.22              // black veil over the video (legibility)
//     gravity fill            // fill (crop) or fit (letterbox)
//
//     monitor "DELL U2723QE"
//     video ~/Movies/odyssey.mp4

struct MonitorConfig {
    var name = ""
    var video = ""
    var scrim: Float = 0.22
    var gravity: AVLayerVideoGravity = .resizeAspectFill
}

struct Config {
    var monitors: [MonitorConfig] = []
    var batteryPause = false   // off by default — freezing because of a power
                               // reading surprised nobody, ever

    static let path = NSString(string: "~/.config/vitallium.conf").expandingTildeInPath

    static func load() -> Config {
        var c = Config()
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return c }
        var current: MonitorConfig? = nil
        for rawLine in raw.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0]
            let val = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "monitor":
                if let cur = current { c.monitors.append(cur) }
                current = MonitorConfig()
                current!.name = val.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "battery-pause":
                c.batteryPause = val != "off"
            case "video":
                current?.video = NSString(string: val).expandingTildeInPath
            case "scrim":
                if let f = Float(val) { current?.scrim = f }
            case "gravity":
                current?.gravity = val == "fit" ? .resizeAspect : .resizeAspectFill
            default: break
            }
        }
        if let cur = current { c.monitors.append(cur) }   // the last block
        return c
    }

    // save a monitor block, preserving everything we don't manage
    static func saveBlock(name: String, video: String?, scrim: Float?, gravity: AVLayerVideoGravity?, remove: Bool = false) {
        var blocks: [String: [String: String]] = [:]   // name -> key/val lines
        var order: [String] = []
        var batteryLine = "battery-pause on"
        var current: String? = nil
        if let raw = try? String(contentsOfFile: path, encoding: .utf8) {
            for rawLine in raw.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "monitor":
                    current = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if blocks[current!] == nil { order.append(current!) }
                    blocks[current!] = blocks[current!] ?? [:]
                case "battery-pause":
                    batteryLine = line
                default:
                    if let c = current { blocks[c]![parts[0]] = parts[1] }
                }
            }
        }

        // apply the update
        if remove {
            blocks[name] = nil
            order.removeAll { $0 == name }
        } else {
            var block = blocks[name] ?? [:]
            if block.isEmpty { order.append(name) }
            if let v = video { block["video"] = v }
            if let s = scrim { block["scrim"] = String(s) }
            if let g = gravity { block["gravity"] = g == .resizeAspect ? "fit" : "fill" }
            blocks[name] = block
        }

        // regenerate
        var out = ["# vitallium — one block per display (names from: vitallium monitors)",
                   batteryLine, ""]
        for n in order {
            let b = blocks[n] ?? [:]
            guard !(b["video"] ?? "").isEmpty else { continue }
            out.append("monitor \"\(n)\"")
            for k in ["video", "scrim", "gravity"] {
                if let v = b[k] { out.append("\(k) \(v)") }
            }
            out.append("")
        }
        try? FileManager.default.createDirectory(
            atPath: NSString(string: "~/.config").expandingTildeInPath,
            withIntermediateDirectories: true)
        try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// MARK: - helpers

func log(_ s: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    FileHandle.standardError.write(Data("vitallium [\(f.string(from: Date()))] \(s)\n".utf8))
}

func onBatteryPower() -> Bool {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let srcs = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
        log("power: no sources readable — assuming AC")
        return false
    }
    var battery = false
    for src in srcs {
        guard let desc = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue()
                as? [String: Any],
              let state = desc[kIOPSPowerSourceStateKey] as? String else {
            log("power: unreadable source — ignoring")
            continue
        }
        log("power: source state = \(state)")
        if state == kIOPSBatteryPowerValue { battery = true }
    }
    return battery
}

func screenID(_ screen: NSScreen) -> CGDirectDisplayID {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
}

// live display inventory: (displayID, name, frame)
func liveDisplays() -> [(id: CGDirectDisplayID, name: String, frame: NSRect)] {
    _ = NSApplication.shared   // NSScreen wants an app context, even in CLI mode
    return NSScreen.screens.map {
        (id: screenID($0), name: $0.localizedName, frame: $0.frame)
    }
}

func bestMatch(for query: String, in displays: [(id: CGDirectDisplayID, name: String, frame: NSRect)])
    -> (id: CGDirectDisplayID, name: String, frame: NSRect)? {
    let q = query.lowercased()
    if let exact = displays.first(where: { $0.name.lowercased() == q }) { return exact }
    let partial = displays.filter { $0.name.lowercased().contains(q) }
    return partial.count == 1 ? partial[0] : nil   // ambiguous prefix = no match
}

// MARK: - engine

final class Engine: NSObject, NSApplicationDelegate {
    var config = Config()
    var windows: [CGDirectDisplayID: NSWindow] = [:]
    var walls: [CGDirectDisplayID: WallBox] = [:]

    // the three reasons every player might be frozen
    var userPaused = false
    var powerBlocked = false
    var displaysAsleep = false

    var configMtime = Date.distantPast
    var lastPowerReading = false
    var sources: [DispatchSourceSignal] = []

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        try? "\(ProcessInfo.processInfo.processIdentifier)".write(
            toFile: "/tmp/vitallium.pid", atomically: true, encoding: .utf8)

        reload(quiet: false)
        applyPlayState()

        // config file watcher — cheap mtime poll, `set`/hand edits land live
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let attrs = try? FileManager.default.attributesOfItem(atPath: Config.path)
            let mtime = attrs?[.modificationDate] as? Date ?? .distantPast
            if mtime != self.configMtime {
                self.reload(quiet: false)
                self.applyPlayState()
            } else if self.config.batteryPause {
                // debounced re-check: a reading only counts after two agree,
                // so one garbage IOPS read can't freeze the wall
                let blocked = self.shouldPowerBlock()
                if blocked == self.lastPowerReading, blocked != self.powerBlocked {
                    self.powerBlocked = blocked
                    self.applyPlayState()
                }
                self.lastPowerReading = blocked
            }
        }

        // signals: USR1 pause, USR2 resume, HUP reload
        signal(SIGUSR1, SIG_IGN); signal(SIGUSR2, SIG_IGN); signal(SIGHUP, SIG_IGN)
        func signalSource(_ sig: Int32, _ handler: @escaping () -> Void) {
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler(handler: DispatchWorkItem(block: handler))
            src.resume()
            sources.append(src)
        }
        signalSource(SIGUSR1) { [weak self] in self?.userPaused = true; self?.applyPlayState() }
        signalSource(SIGUSR2) { [weak self] in self?.userPaused = false; self?.applyPlayState() }
        signalSource(SIGHUP)  { [weak self] in self?.reload(quiet: false); self?.applyPlayState() }

        // displays sleep -> freeze; wake -> re-evaluate
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                           object: nil, queue: .main) { [weak self] _ in
            self?.displaysAsleep = true; self?.applyPlayState()
        }
        for name in [NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.didWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.displaysAsleep = false
                self?.reload(quiet: true)   // displays may have changed
                self?.applyPlayState()
            }
        }

        // displays plugged / unplugged / resolution changed
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.reload(quiet: true); self?.applyPlayState()
        }
    }

    // MARK: config -> objects

    func reload(quiet: Bool) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: Config.path)
        configMtime = attrs?[.modificationDate] as? Date ?? .distantPast
        config = Config.load()
        syncDisplays()

        if !quiet {
            let bound = config.monitors.filter { !$0.video.isEmpty }.count
            log("config loaded — \(bound) display\(bound == 1 ? "" : "s") bound")
        }
    }

    func syncDisplays() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let alive = Set(screens.map(screenID))

        // drop walls + windows for displays that went away
        for (id, box) in walls where !alive.contains(id) {
            log("display \(id) (\(box.name)) gone — releasing its \(box.isVideo ? "video" : "image")")
            box.stop()
            walls.removeValue(forKey: id)
        }
        for (id, win) in windows where !alive.contains(id) {
            win.orderOut(nil)
            windows.removeValue(forKey: id)
        }

        for screen in screens {
            let id = screenID(screen)
            let name = screen.localizedName
            let cfg = config.monitors.first { $0.name.lowercased() == name.lowercased() }

            // recreate the window when new or when geometry changed
            if let win = windows[id], win.frame != screen.frame {
                log("display \(id) geometry changed — rebuilding its window")
                win.orderOut(nil)
                windows.removeValue(forKey: id)
            }

            guard let cfg = cfg, !cfg.video.isEmpty else {
                if windows[id] != nil {
                    log("\(name): unbound — standing down (native wallpaper shows)")
                    windows[id]?.orderOut(nil)
                    windows.removeValue(forKey: id)
                    walls[id]?.stop()
                    walls.removeValue(forKey: id)
                }
                continue
            }
            guard FileManager.default.fileExists(atPath: cfg.video) else {
                if windows[id] != nil {
                    log("\(name): FILE GONE (\(cfg.video)) — standing down")
                    windows[id]?.orderOut(nil)
                    windows.removeValue(forKey: id)
                    walls[id]?.stop()
                    walls.removeValue(forKey: id)
                } else {
                    log("\(name): bound file missing — \(cfg.video)")
                }
                continue
            }

            // (re)create the wall if the source changed — and rebuild the
            // window with it, because the old view holds the old layer
            if let box = walls[id], box.path != cfg.video {
                box.stop()
                walls.removeValue(forKey: id)
                windows[id]?.orderOut(nil)
                windows.removeValue(forKey: id)
            }
            if walls[id] == nil {
                walls[id] = WallBox(name: name, path: cfg.video)
                log("\(name): \(walls[id]!.isVideo ? "looping \(cfg.video)" : "still image \(cfg.video)")")
            }
            let box = walls[id]!

            if windows[id] == nil {
                windows[id] = makeWindow(screen: screen, box: box, cfg: cfg)
                log("\(name): window on \(screen.frame) — \(cfg.gravity == .resizeAspectFill ? "fill" : "fit"), scrim \(cfg.scrim)")
            } else {
                box.setGravity(cfg.gravity)
                box.scrim?.opacity = cfg.scrim
            }
        }
    }

    func makeWindow(screen: NSScreen, box: WallBox, cfg: MonitorConfig) -> NSWindow {
        let view = PlayerHostView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true   // layer-backed, or view.layer is nil and nothing renders

        box.setGravity(cfg.gravity)
        box.layer.frame = view.bounds
        box.layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.videoLayer = box.layer
        view.layer?.addSublayer(box.layer)

        let scrim = CALayer()
        scrim.backgroundColor = CGColor(gray: 0, alpha: 1)
        scrim.frame = view.bounds
        scrim.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        scrim.opacity = cfg.scrim
        view.scrimLayer = scrim
        view.layer?.addSublayer(scrim)
        box.scrim = scrim

        let win = NSWindow(contentRect: NSRect(origin: .zero, size: screen.frame.size),
                           styleMask: .borderless,
                           backing: .buffered,
                           defer: false,
                           screen: screen)
        // AppKit gotcha: passing a secondary display's global frame as
        // contentRect double-applies its origin — create at size-only,
        // then move explicitly.
        win.setFrame(screen.frame, display: false)
        // the whole trick lives in these lines:
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        win.isOpaque = false
        win.backgroundColor = .clear
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.hasShadow = false
        win.contentView = view
        win.orderFrontRegardless()
        log("\(screen.localizedName): win.frame = \(win.frame) (wanted \(screen.frame))")
        return win
    }

    // MARK: play state

    func shouldPowerBlock() -> Bool {
        guard config.batteryPause else { return false }
        return onBatteryPower() || ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    func applyPlayState() {
        let rate: Float = (userPaused || powerBlocked || displaysAsleep) ? 0 : 1
        var changed = false
        for (_, box) in walls where box.isVideo && box.rate != rate { box.rate = rate; changed = true }
        if changed {
            if rate == 0 {
                var why: String? = nil
                if displaysAsleep { why = "displays asleep" }
                else if powerBlocked { why = "power (battery/low power mode)" }
                else if userPaused { why = "paused by user" }
                if let why = why { log("frozen — \(why)") }
            } else {
                log("playing")
            }
        }
    }
}

// one content source per display: a looping video or a still image,
// plus the layers it feeds
final class WallBox: NSObject {
    let name: String
    let path: String
    let isVideo: Bool
    let layer: CALayer          // AVPlayerLayer for video, contents-layer for images
    var scrim: CALayer?
    private(set) var queue: AVQueuePlayer?
    private(set) var looper: AVPlayerLooper?

    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "heif",
                                         "tiff", "tif", "gif", "bmp", "webp"]

    init(name: String, path: String) {
        self.name = name
        self.path = path
        let ext = (path as NSString).pathExtension.lowercased()
        let wantsImage = WallBox.imageExts.contains(ext)
        let img = wantsImage ? WallBox.loadImage(path) : nil
        if wantsImage && img == nil {
            log("\(name): image FAILED to load (\(path)) — falling back to video path")
        }

        if let img = img {
            isVideo = false
            let l = CALayer()
            l.contents = img
            l.contentsGravity = .resizeAspectFill
            layer = l
            super.init()
            return
        }

        isVideo = true
        let pl = AVPlayerLayer()
        layer = pl
        super.init()
        let item = AVPlayerItem(url: URL(fileURLWithPath: path))
        let q = AVQueuePlayer()
        q.isMuted = true
        looper = AVPlayerLooper(player: q, templateItem: item)
        queue = q
        pl.player = q
        item.addObserver(self, forKeyPath: "status", options: [.new], context: nil)
        NotificationCenter.default.addObserver(
            forName: AVPlayerItem.newErrorLogEntryNotification,
            object: item, queue: .main) { note in
            log("\(name): player error — \(String(describing: note.userInfo))")
        }
        NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: item, queue: .main) { _ in
            log("\(name): playback stalled (file on a slow/cloud volume?)")
        }
    }

    static func loadImage(_ path: String) -> CGImage? {
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        var rect = CGRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    func setGravity(_ g: AVLayerVideoGravity) {
        if isVideo {
            (layer as? AVPlayerLayer)?.videoGravity = g
        } else {
            layer.contentsGravity = g == .resizeAspectFill ? .resizeAspectFill : .resizeAspect
        }
    }

    var rate: Float {
        get { queue?.rate ?? 1 }
        set {
            guard let q = queue else { return }   // images: no-op
            q.rate = newValue
            // a player paused before its first frame decodes renders nothing —
            // a transparent window. force one frame through, then re-freeze.
            if newValue == 0 {
                q.play()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: DispatchWorkItem { q.rate = 0 })
            }
        }
    }

    func stop() {
        looper?.disableLooping()
        queue?.pause()
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "status", let item = object as? AVPlayerItem {
            switch item.status {
            case .readyToPlay: log("\(name): item ready to play")
            case .failed:      log("\(name): item FAILED — \(item.error.map(String.init(describing:)) ?? "?")")
            default: break
            }
        }
    }
}

// a plain view that hosts the player layer; exists so the layer survives
// view reuse and can be swapped without rebuilding windows
final class PlayerHostView: NSView {
    var videoLayer: CALayer?
    var scrimLayer: CALayer?
    override func layout() {
        super.layout()
        videoLayer?.frame = bounds
        scrimLayer?.frame = bounds
    }
}

// MARK: - cli

func pidFromFile() -> pid_t? {
    guard let s = try? String(contentsOfFile: "/tmp/vitallium.pid", encoding: .utf8) else { return nil }
    guard let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    return kill(pid, 0) == 0 ? pid : nil
}

func signalDaemon(_ sig: Int32) -> Bool {
    guard let pid = pidFromFile() else { return false }
    kill(pid, sig)
    return true
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

func cmdMonitors() -> Never {
    let config = Config.load()
    let displays = liveDisplays()
    print(pad("NAME", 32) + pad("RESOLUTION", 12) + pad("STATE", 9) + "VIDEO")
    for d in displays {
        let cfg = config.monitors.first { $0.name.lowercased() == d.name.lowercased() }
        let res = "\(Int(d.frame.width))×\(Int(d.frame.height))"
        let video = cfg?.video.isEmpty == false ? (cfg!.video as NSString).lastPathComponent : "(not configured)"
        let state = cfg?.video.isEmpty == false ? "bound" : "native"
        print(pad(d.name, 32) + pad(res, 12) + pad(state, 9) + video)
    }
    // remembered-but-absent displays
    let liveNames = Set(displays.map { $0.name.lowercased() })
    for m in config.monitors where !liveNames.contains(m.name.lowercased()) {
        let video = m.video.isEmpty ? "" : (m.video as NSString).lastPathComponent
        print(pad(m.name, 32) + pad("—", 12) + pad("absent", 9) + video)
    }
    exit(0)
}

func cmdSet(_ rest: [String]) -> Never {
    var monitor: String? = nil
    var file: String? = nil
    var scrim: Float? = nil
    var gravity: AVLayerVideoGravity? = nil
    var strayFlag: String? = nil   // a --flag we didn't recognize, consumed as the file
    var i = 0
    while i < rest.count {
        switch rest[i] {
        case "--monitor", "-m", "--display":
            guard i + 1 < rest.count else { print("error: --monitor needs a name"); exit(1) }
            monitor = rest[i + 1]; i += 2
        case "--scrim":
            guard i + 1 < rest.count, let f = Float(rest[i + 1]) else { print("error: --scrim needs a number 0–1"); exit(1) }
            scrim = f; i += 2
        case "--gravity":
            guard i + 1 < rest.count else { print("error: --gravity needs fill|fit"); exit(1) }
            gravity = rest[i + 1] == "fit" ? .resizeAspect : .resizeAspectFill; i += 2
        default:
            if file == nil {
                if rest[i].hasPrefix("--") { strayFlag = String(rest[i].dropFirst(2)) }
                file = rest[i]
            }
            else {
                var hint = ""
                if rest[i].hasPrefix("--") {
                    hint = "\n  known flags: --monitor \"NAME\" (--monitor all), --scrim N, --gravity fill|fit"
                } else if let stray = strayFlag,
                          bestMatch(for: stray, in: liveDisplays()) != nil {
                    // the classic typo: --Built-in Retina Display instead of --monitor "Built-in..."
                    hint = "\n  did you mean: vitallium set --monitor \"\(stray)\" <file> ?"
                } else {
                    hint = "\n  (monitor names with spaces must be quoted: --monitor \"Built-in Retina Display\")"
                }
                print("error: unexpected argument \(rest[i])\(hint)")
                exit(1)
            }
            i += 1
        }
    }

    guard let name = monitor else {
        FileHandle.standardError.write(Data("""
        error: --monitor is required — there is no default display

          vitallium monitors                    see the names
          vitallium set --monitor "NAME" FILE   bind a video

        """.utf8))
        exit(1)
    }
    guard name != "all" || file != nil else { print("error: --monitor all needs a FILE"); exit(1) }

    let displays = liveDisplays()

    if name == "all" {
        guard !displays.isEmpty else { print("error: no displays connected"); exit(1) }
        for d in displays {
            Config.saveBlock(name: d.name, video: file, scrim: scrim, gravity: gravity)
            print("set \(d.name) → \(file!)")
        }
    } else {
        guard let file = file else {
            FileHandle.standardError.write(Data("error: no video file given\nusage: vitallium set --monitor \"NAME\" FILE\n".utf8)); exit(1)
        }
        let expanded = NSString(string: file).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            FileHandle.standardError.write(Data("vitallium: no such file: \(expanded)\n".utf8)); exit(1)
        }
        // warn when the name doesn't match anything live (still saved — the
        // config is the cache, it applies whenever that display appears)
        if bestMatch(for: name, in: displays) == nil {
            print("note: no live display matches \"\(name)\" — saved anyway; it will apply when connected")
        } else {
            print("set \(name) → \(file)")
        }
        Config.saveBlock(name: bestMatch(for: name, in: displays)?.name ?? name,
                         video: file, scrim: scrim, gravity: gravity)
    }

    if signalDaemon(SIGHUP) { print("(daemon reloaded)") }
    else { print("(daemon not running — starts at next login)") }
    exit(0)
}

func cmdClear(_ rest: [String]) -> Never {
    var monitor: String? = nil
    var i = 0
    while i < rest.count {
        if rest[i] == "--monitor", i + 1 < rest.count { monitor = rest[i + 1]; i += 2 }
        else { print("error: unexpected argument \(rest[i])"); exit(1) }
    }
    guard let name = monitor else {
        FileHandle.standardError.write(Data("""
        error: --monitor is required — there is no default display

          vitallium clear --monitor "NAME"    unbind a display (native wallpaper returns)
          vitallium clear --monitor all       unbind everything

        """.utf8))
        exit(1)
    }

    if name == "all" {
        let config = Config.load()
        guard !config.monitors.isEmpty else { print("nothing bound"); exit(0) }
        for m in config.monitors { Config.saveBlock(name: m.name, video: nil, scrim: nil, gravity: nil, remove: true) }
        print("cleared \(config.monitors.count) display\(config.monitors.count == 1 ? "" : "s")")
    } else {
        let displays = liveDisplays()
        let resolved = bestMatch(for: name, in: displays)?.name ?? name
        Config.saveBlock(name: resolved, video: nil, scrim: nil, gravity: nil, remove: true)
        print("cleared \(resolved) — native wallpaper returns")
    }

    if signalDaemon(SIGHUP) { print("(daemon reloaded)") }
    exit(0)
}

func handleCommand(_ cmd: String, _ rest: [String]) -> Never {
    switch cmd {
    case "monitors", "displays", "ls":
        cmdMonitors()

    case "set":
        cmdSet(rest)

    case "pause":
        guard signalDaemon(SIGUSR1) else { notRunning(); exit(1) }
        print("paused"); exit(0)

    case "resume":
        guard signalDaemon(SIGUSR2) else { notRunning(); exit(1) }
        print("resumed"); exit(0)

    case "reload":
        guard signalDaemon(SIGHUP) else { notRunning(); exit(1) }
        print("reloaded"); exit(0)

    case "stop", "quit":
        let label = "dev.cobalt.vitallium"
        let gui = "gui/\(getuid())"
        shell("/bin/launchctl", ["bootout", "\(gui)/\(label)"])
        if let pid = pidFromFile() { kill(pid, SIGTERM) }
        try? FileManager.default.removeItem(atPath: "/tmp/vitallium.pid")
        print("stopped — the launchd agent is bootout'ed; it returns at next login or `vitallium start`")
        exit(0)

    case "start":
        let label = "dev.cobalt.vitallium"
        let gui = "gui/\(getuid())"
        let plist = NSString(string: "~/Library/LaunchAgents/\(label).plist").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: plist) else {
            FileHandle.standardError.write(Data("error: not installed — run install.sh first\n".utf8)); exit(1)
        }
        shell("/bin/launchctl", ["bootstrap", gui, plist])
        print("started")
        exit(0)

    case "clear", "unbind":
        cmdClear(rest)

    case "status":
        let config = Config.load()
        if pidFromFile() == nil {
            print("not running (launchd agent: dev.cobalt.vitallium)")
            exit(0)
        }
        print("running")
        let displays = liveDisplays()
        for d in displays {
            let cfg = config.monitors.first { $0.name.lowercased() == d.name.lowercased() }
            let video = cfg?.video.isEmpty == false ? (cfg!.video as NSString).lastPathComponent : "(not configured)"
            print("  \(d.name) [\("\(Int(d.frame.width))×\(Int(d.frame.height))")]: \(video)")
        }
        print("battery:  \(config.batteryPause ? "pause on battery/low power" : "always play")")
        exit(0)

    default:
        FileHandle.standardError.write(Data("""
        usage: vitallium [command]
          monitors                          list displays + what's on them
          set --monitor "NAME" FILE         bind a video/image to a display
              [--scrim 0.22] [--gravity fill|fit]
          clear --monitor "NAME"            unbind a display ("all" for everything)
          pause / resume                    freeze / unfreeze videos
          start / stop                      start / quit the daemon (launchd agent)
          reload                            re-read the config
          status                            what's happening

        """.utf8))
        exit(1)
    }
}

func notRunning() -> Never {
    FileHandle.standardError.write(Data("""
    vitallium: daemon not running
      start it:  vitallium start   (or ./install.sh)

    """.utf8))
    exit(1)
}

@discardableResult
func shell(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

// MARK: - entry

let args = CommandLine.arguments
if args.count > 1 {
    handleCommand(args[1], Array(args.dropFirst(2)))
}

// daemon mode: refuse to run twice — a second instance would fight the
// launchd one for the desktop layer and leave a stale pid file behind
if let existing = pidFromFile(), existing != ProcessInfo.processInfo.processIdentifier {
    FileHandle.standardError.write(Data("vitallium: already running (pid \(existing)) — 'vitallium stop' quits it\n".utf8))
    exit(1)
}

let app = NSApplication.shared
let engine = Engine()
app.delegate = engine
app.setActivationPolicy(.accessory)   // no dock icon, no menu, just the wall
app.run()
