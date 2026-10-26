// Build native icon representations from Shou's canonical raster mascot.
import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "assets/brand", isDirectory: true)
let source = URL(fileURLWithPath: "assets/brand/shou-mascot-source.png")
guard let image = NSImage(contentsOf: source),
      let representation = NSBitmapImageRep(data: try Data(contentsOf: source)),
      representation.pixelsWide == 1024, representation.pixelsHigh == 1024 else {
    throw NSError(domain: "ShouIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected a 1024 × 1024 canonical PNG at \(source.path)"])
}
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let iconset = destination.appendingPathComponent("Shou.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func drawIcon() {
    let rect = NSRect(x: 96, y: 96, width: 832, height: 832)
    let tile = NSBezierPath(roundedRect: rect, xRadius: 184, yRadius: 184)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(srgbRed: 0.08, green: 0.25, blue: 0.22, alpha: 0.18)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.white.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
}

func raster(_ pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: pixels, height: pixels).fill(using: .copy)
    NSGraphicsContext.current!.imageInterpolation = .high
    let transform = AffineTransform(scale: CGFloat(pixels) / 1024)
    (transform as NSAffineTransform).concat()
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try raster(size * scale).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
try raster(1024).write(to: destination.appendingPathComponent("shou-icon-1024.png"))

// PDF contains the same raster artwork and native rounded mask; it is not a vector master.
let data = NSMutableData()
let consumer = CGDataConsumer(data: data)!
var media = CGRect(x: 0, y: 0, width: 1024, height: 1024)
let pdf = CGContext(consumer: consumer, mediaBox: &media, nil)!
pdf.beginPDFPage(nil)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
drawIcon()
NSGraphicsContext.restoreGraphicsState()
pdf.endPDFPage()
pdf.closePDF()
try (data as Data).write(to: destination.appendingPathComponent("shou-icon.pdf"))

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["--convert", "icns", iconset.path, "--output", destination.appendingPathComponent("Shou.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    throw NSError(domain: "ShouIcon", code: Int(process.terminationStatus))
}
print("Generated Shou.icns, 10 native PNG representations, 1024px preview and raster PDF.")
