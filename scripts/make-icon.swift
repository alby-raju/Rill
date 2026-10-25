import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let folder = root.appendingPathComponent("dist/Rill.iconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    NSColor(calibratedRed: 0.035, green: 0.14, blue: 0.22, alpha: 1).setFill()
    NSBezierPath(
        roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 210, yRadius: 210
    ).fill()
    for (index, color) in [NSColor.systemTeal, NSColor.white, NSColor.systemMint].enumerated() {
        color.setStroke()
        let path = NSBezierPath()
        let y = CGFloat(310 + index * 190)
        path.move(to: NSPoint(x: 220, y: y))
        path.curve(
            to: NSPoint(x: 804, y: y + 45), controlPoint1: NSPoint(x: 430, y: y + 220),
            controlPoint2: NSPoint(x: 570, y: y - 175))
        path.lineWidth = 66
        path.lineCapStyle = .round
        path.stroke()
    }
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let data = bitmap.representation(using: .png, properties: [:])!
    let names: [String] =
        size == 16
        ? ["icon_16x16"]
        : size == 1024
            ? ["icon_512x512@2x"] : ["icon_\(size)x\(size)", "icon_\(size/2)x\(size/2)@2x"]
    for name in names { try data.write(to: folder.appendingPathComponent(name + ".png")) }
}
