import AppKit
import Foundation

// Offline, deterministic exports from the approved transparent raster masters.
let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let names = ["cleanup", "applications", "projects", "space", "large-files", "privacy", "startup", "rules", "history", "settings"]
for name in names {
    let input = source.appendingPathComponent(name + ".png")
    guard let image = NSImage(contentsOf: input),
          let rep = NSBitmapImageRep(data: try Data(contentsOf: input)) else { throw CocoaError(.fileReadCorruptFile) }
    let width = name == "cleanup" ? 1320 : 1080
    let height = name == "cleanup" ? 990 : 840
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: width, height: height)
    let scale = min(Double(width) / Double(rep.pixelsWide), Double(height) / Double(rep.pixelsHigh))
    let drawWidth = Double(rep.pixelsWide) * scale
    let drawHeight = Double(rep.pixelsHigh) * scale
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill(using: .copy)
    NSGraphicsContext.current!.imageInterpolation = .high
    image.draw(in: NSRect(x: (Double(width) - drawWidth) / 2, y: (Double(height) - drawHeight) / 2,
                          width: drawWidth, height: drawHeight), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: destination.appendingPathComponent(name + ".png"))
}
