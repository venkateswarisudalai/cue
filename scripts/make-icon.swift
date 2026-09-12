// Renders Resources/AppIcon.icns: a speech bubble with a spark on an indigo→teal squircle.
// Usage: swift scripts/make-icon.swift <output-dir>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Squircle background with the standard macOS icon margin.
    let inset = s * 0.1
    let bg = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset),
                          xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [NSColor(red: 0.29, green: 0.25, blue: 0.85, alpha: 1),
                        NSColor(red: 0.07, green: 0.62, blue: 0.68, alpha: 1)])!
        .draw(in: bg, angle: -60)

    // Speech bubble.
    let bubble = NSRect(x: s * 0.24, y: s * 0.36, width: s * 0.52, height: s * 0.36)
    let path = NSBezierPath(roundedRect: bubble, xRadius: s * 0.1, yRadius: s * 0.1)
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: s * 0.34, y: s * 0.38))
    tail.line(to: NSPoint(x: s * 0.29, y: s * 0.26))
    tail.line(to: NSPoint(x: s * 0.46, y: s * 0.37))
    tail.close()
    NSColor.white.setFill()
    path.fill()
    tail.fill()

    // Three "listening" bars inside the bubble.
    let barColor = NSColor(red: 0.2, green: 0.35, blue: 0.8, alpha: 1)
    barColor.setFill()
    let heights: [CGFloat] = [0.1, 0.18, 0.12]
    for (i, h) in heights.enumerated() {
        let w = s * 0.055
        let x = s * 0.395 + CGFloat(i) * s * 0.085
        NSBezierPath(roundedRect: NSRect(x: x, y: s * 0.54 - s * h / 2, width: w, height: s * h),
                     xRadius: w / 2, yRadius: w / 2).fill()
    }

    // Spark in the top-right corner.
    let c = NSPoint(x: s * 0.72, y: s * 0.74)
    let r = s * 0.09
    let spark = NSBezierPath()
    spark.move(to: NSPoint(x: c.x, y: c.y + r))
    spark.curve(to: NSPoint(x: c.x + r, y: c.y), controlPoint1: NSPoint(x: c.x + r * 0.15, y: c.y + r * 0.15), controlPoint2: NSPoint(x: c.x + r * 0.15, y: c.y + r * 0.15))
    spark.curve(to: NSPoint(x: c.x, y: c.y - r), controlPoint1: NSPoint(x: c.x + r * 0.15, y: c.y - r * 0.15), controlPoint2: NSPoint(x: c.x + r * 0.15, y: c.y - r * 0.15))
    spark.curve(to: NSPoint(x: c.x - r, y: c.y), controlPoint1: NSPoint(x: c.x - r * 0.15, y: c.y - r * 0.15), controlPoint2: NSPoint(x: c.x - r * 0.15, y: c.y - r * 0.15))
    spark.curve(to: NSPoint(x: c.x, y: c.y + r), controlPoint1: NSPoint(x: c.x - r * 0.15, y: c.y + r * 0.15), controlPoint2: NSPoint(x: c.x - r * 0.15, y: c.y + r * 0.15))
    NSColor(red: 1, green: 0.84, blue: 0.35, alpha: 1).setFill()
    spark.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try p.run()
p.waitUntilExit()
exit(p.terminationStatus)
