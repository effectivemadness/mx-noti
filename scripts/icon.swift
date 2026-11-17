import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for (points, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let pixels = points * scale
    let representation = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    let p = CGFloat(pixels)
    NSColor(calibratedRed: 0.13, green: 0.31, blue: 0.26, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: p*0.06, y: p*0.06, width: p*0.88, height: p*0.88), xRadius: p*0.21, yRadius: p*0.21).fill()
    NSColor(calibratedRed: 0.86, green: 0.95, blue: 0.81, alpha: 1).setStroke()
    let heights: [CGFloat] = [0.16, 0.34, 0.55, 0.36, 0.20]
    for (i, height) in heights.enumerated() {
        let x = p * (0.25 + CGFloat(i)*0.125)
        let path = NSBezierPath(); path.lineWidth = max(1, p*0.046); path.lineCapStyle = .round
        path.move(to: NSPoint(x: x, y: p*(0.5-height/2))); path.line(to: NSPoint(x: x, y: p*(0.5+height/2))); path.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    let data = representation.representation(using: .png, properties: [:])!
    let name = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
    try data.write(to: directory.appendingPathComponent(name))
}
