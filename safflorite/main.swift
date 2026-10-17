import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Darwin

// safflorite — hold ⌘⇧Space to show a translucent pill anchored to the bottom
// of every screen with the 24-hour time (HH:mm:ss); release to hide. The pill
// is a hudWindow vibrancy capsule so it reads cleanly over any background, and
// it fades in/out instead of popping. Runs as the dev.cobalt.safflorite
// launchd agent. The hotkey is a Carbon registered hotkey, so no TCC
// permissions are needed.
//
// Release detection, in order of trust:
//   1. kEventHotKeyReleased from the Carbon handler (fired by some systems)
//   2. Polling CGEventSource.keyState on both the session and HID sources,
//      with hysteresis (3 consecutive all-false readings ≈ 90ms). The poll is
//      only trusted if it ever reported the key as down — some setups never
//      report it for hotkey-consumed keys, in which case the poll stays out of
//      the way and (1) handles the release.
// Every transition is logged to /tmp/safflorite.err so misbehaviour is visible.

let pillAlpha: CGFloat = 1.0    // fully opaque
let bottomMargin: CGFloat = 12  // gap between the pill and the top of the dock
let pillFontSize: CGFloat = 22  // small, minimal
let hPad: CGFloat = 12          // pill padding around the text
let vPad: CGFloat = 8

final class AppDelegate: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    var labels: [NSTextField] = []
    var hotkeyRef: EventHotKeyRef?
    var releaseTimer: Timer?
    var showing = false
    var everSawKeyDown = false
    var missedPolls = 0

    let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX") // force 24h regardless of system locale
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // no Dock icon

        // one pill per screen
        for screen in NSScreen.screens {
            let fontSize = pillFontSize

            let label = NSTextField(labelWithString: "00:00:00")
                        label.font = .systemFont(ofSize: fontSize, weight: .medium)
            label.alignment = .center
            label.textColor = .white
            label.translatesAutoresizingMaskIntoConstraints = false

            // pill sized to the text plus padding, capsule corners
            let textSize = label.intrinsicContentSize
            let pillW = ceil(textSize.width) + hPad * 2
            let pillH = ceil(textSize.height) + vPad * 2

            // solid black capsule, no vibrancy
            let pill = NSView(frame: NSRect(origin: .zero,
                                            size: NSSize(width: pillW, height: pillH)))
            pill.wantsLayer = true
            pill.layer?.backgroundColor = NSColor.black.cgColor
            pill.layer?.cornerRadius = pillH / 2
            pill.layer?.masksToBounds = true
            // subtle grey edge so the capsule reads against both light and dark
            pill.layer?.borderWidth = 1.5
            pill.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
            pill.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: pill.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            ])

            // bottom-centre of the screen, above the dock (visibleFrame excludes it)
            let visible = screen.visibleFrame
            let frame = NSRect(x: visible.midX - pillW / 2,
                               y: visible.minY + bottomMargin,
                               width: pillW,
                               height: pillH)
            let window = NSWindow(contentRect: frame,
                                  styleMask: [.borderless],
                                  backing: .buffered,
                                  defer: false)
            window.contentView = pill
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.ignoresMouseEvents = true // clicks fall through
            window.alphaValue = 0
            window.orderOut(nil) // start hidden

            windows.append(window)
            labels.append(label)
        }

        // tick 4x per second so seconds roll over without visible lag
        let clock = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.update()
        }
        RunLoop.main.add(clock, forMode: .common)

        registerHotkey()
    }

    func update() {
        guard showing else { return }
        let now = formatter.string(from: Date())
        for label in labels { label.stringValue = now }
    }

    func showPill() {
        missedPolls = 0 // key repeats / double presses count as still-held
        guard !showing else { return }
        log("press → show")
        showing = true
        update()
        for window in windows {
            window.orderFrontRegardless() // never steals focus
            fade(window, to: pillAlpha)
        }
        startReleasePolling()
    }

    func hidePill(reason: String) {
        guard showing else { return }
        log("release → hide (\(reason))")
        showing = false
        releaseTimer?.invalidate()
        releaseTimer = nil
        for window in windows {
            fade(window, to: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                if !(self?.showing ?? true) { window.orderOut(nil) }
            }
        }
    }

    func fade(_ window: NSWindow, to alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = alpha
        }
    }

    // poll the physical space key state (no permissions required)
    func startReleasePolling() {
        everSawKeyDown = false
        missedPolls = 0
        releaseTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            guard let self = self, self.showing else { return }
            let space = UInt16(kVK_Space)
            let down = CGEventSource.keyState(.combinedSessionState, key: space)
                    || CGEventSource.keyState(.hidSystemState, key: space)
            if down {
                self.everSawKeyDown = true
                self.missedPolls = 0
            } else if self.everSawKeyDown {
                // only trust the poll once it has positively confirmed a press;
                // 3 consecutive misses filter glitchy single readings
                self.missedPolls += 1
                if self.missedPolls >= 3 {
                    self.hidePill(reason: "poll, \(self.missedPolls) misses")
                }
            }
            // if the poll never sees the key as down at all (some setups don't
            // report hotkey-consumed keys), it stays silent and the
            // kEventHotKeyReleased event handles the release instead
        }
    }

    // Carbon global hotkey: ⌘⇧Space. RegisterEventHotKey needs no
    // Accessibility or Input Monitoring grant (unlike NSEvent global monitors).
    func registerHotkey() {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            let kind = GetEventKind(event!)
            let released = kind == EventKind(kEventHotKeyReleased)
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async {
                if released {
                    delegate.hidePill(reason: "hotkey released event")
                } else {
                    delegate.showPill()
                }
            }
            return noErr
        }, types.count, &types, selfPtr, nil)

        RegisterEventHotKey(UInt32(kVK_Space),            // space
                            UInt32(cmdKey | shiftKey),    // ⌘⇧
                            EventHotKeyID(signature: OSType(0x5341_464C) /* 'SAFL' */, id: 1),
                            GetApplicationEventTarget(), 0,
                            &hotkeyRef)
    }
}

func log(_ msg: String) {
    let ts = String(format: "%.2f", Date().timeIntervalSince1970)
    FileHandle.standardError.write(("[\(ts)] \(msg)\n").data(using: .utf8)!)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
