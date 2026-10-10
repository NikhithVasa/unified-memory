import AppKit

let destination = CommandLine.arguments[1]
let iconSet = URL(fileURLWithPath: destination).deletingLastPathComponent().appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

func drawIcon(size: Int) -> Data {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let scale = CGFloat(size) / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)
    let rect = NSRect(x: 60, y: 60, width: 904, height: 904)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 202, yRadius: 202)
    NSGradient(starting: NSColor(red: 0.10, green: 0.39, blue: 0.95, alpha: 1), ending: NSColor(red: 0.24, green: 0.13, blue: 0.62, alpha: 1))!
        .draw(in: shape, angle: -50)
    if let symbol = NSImage(systemSymbolName: "memorychip", accessibilityDescription: nil) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 480, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        let configured = symbol.withSymbolConfiguration(configuration)!
        configured.isTemplate = false
        let symbolRect = NSRect(x: 232, y: 295, width: 560, height: 434)
        configured.draw(in: symbolRect)
    }
    // A live-status light is part of the icon, not a runtime status indicator.
    NSColor(red: 0.30, green: 0.94, blue: 0.70, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 694, y: 200, width: 92, height: 92)).fill()
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return bitmap.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let suffix = factor == 2 ? "@2x" : ""
        let url = iconSet.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        try drawIcon(size: points * factor).write(to: url)
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconSet.path, "-o", destination]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { exit(task.terminationStatus) }
try FileManager.default.removeItem(at: iconSet)
