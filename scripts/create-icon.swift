import AppKit

// A code-drawn app icon: the same sun and forest palette as the native sidebar.
let output = URL(fileURLWithPath: CommandLine.arguments[1])
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let factor = CGFloat(pixels) / 1024
        let transform = NSAffineTransform(); transform.scale(by: factor); transform.concat()
        NSColor(calibratedRed: 0.13, green: 0.29, blue: 0.24, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 210, yRadius: 210).fill()
        NSColor(calibratedRed: 0.91, green: 0.80, blue: 0.49, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 340, y: 340, width: 344, height: 344)).fill()
        NSColor(calibratedRed: 0.91, green: 0.80, blue: 0.49, alpha: 1).setStroke()
        for ray in 0..<8 {
            let angle = CGFloat(ray) * .pi / 4
            let path = NSBezierPath(); path.lineWidth = 43; path.lineCapStyle = .round
            path.move(to: NSPoint(x: 512 + cos(angle) * 250, y: 512 + sin(angle) * 250))
            path.line(to: NSPoint(x: 512 + cos(angle) * 316, y: 512 + sin(angle) * 316)); path.stroke()
        }
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
