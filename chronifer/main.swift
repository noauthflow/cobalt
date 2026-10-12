import AppKit

// chronifer — live Downloads folder icon: a custom folder icon with the
// current 24-hour time (HH:mm) rendered in red, dead centre. Runs as the
// dev.cobalt.chronifer launchd daemon and fires exactly on each wall-clock
// minute boundary (sleeps precisely until just past :00 of the next minute).

let folderPath = NSHomeDirectory() + "/Downloads"
let size = NSSize(width: 512, height: 512)

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

func sleepUntilNextMinute() {
    let now = Date().timeIntervalSince1970
    let secondsIntoMinute = now.truncatingRemainder(dividingBy: 60)
    // wake just past the boundary so the displayed time is the new minute
    Thread.sleep(forTimeInterval: (60 - secondsIntoMinute) + 0.05)
}

// resolve the icns asset: first look next to the installed binary
// (~/.local/bin/), then fall back to the repo checkout
func iconPath() -> String? {
    let candidates: [String] = [
        (Bundle.main.executableURL?.deletingLastPathComponent().path ?? "") + "/blackfolder.icns",
        NSHomeDirectory() + "/dev/cobalt/chronifer/blackfolder.icns"
    ]
    for c in candidates where FileManager.default.fileExists(atPath: c) {
        return c
    }
    return nil
}

guard let iconFile = iconPath(),
      let folderIcon = NSImage(contentsOfFile: iconFile) else {
    fail("chronifer: could not load blackfolder.icns")
}

// force 24-hour clock regardless of system locale settings
let formatter = DateFormatter()
formatter.locale = Locale(identifier: "en_US_POSIX")
formatter.dateFormat = "HH:mm"

// draw the timestamp in dark red, mono font, properly centred via a measured
// bounding rect (nudged down a touch so it sits in the visual middle of the folder)
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 126, weight: .semibold),
    .foregroundColor: NSColor(calibratedRed: 0.55, green: 0.07, blue: 0.07, alpha: 1.0)
]

func render() {
    let image = NSImage(size: size)
    image.lockFocus()

    // draw the base folder icon scaled to fill the canvas
    folderIcon.draw(in: NSRect(origin: .zero, size: size),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1.0)

    let attributed = NSAttributedString(string: formatter.string(from: Date()), attributes: attributes)
    let textRect = attributed.boundingRect(with: size, options: .usesLineFragmentOrigin)
    let nudge: CGFloat = 24 // slight downward offset from geometric centre
    attributed.draw(in: NSRect(x: (size.width - textRect.width) / 2,
                               y: (size.height - textRect.height) / 2 - nudge,
                               width: textRect.width,
                               height: textRect.height))

    image.unlockFocus()

    // apply as the folder's custom icon
    guard NSWorkspace.shared.setIcon(image, forFile: folderPath) else {
        fail("chronifer: failed to set icon on \(folderPath)")
    }
}

// render once now, then loop: fire exactly on every minute boundary forever
render()
while true {
    sleepUntilNextMinute()
    render()
}
