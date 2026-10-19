// The editable vector master for Shou's macOS icon. No external packages.
import AppKit
import Foundation

let destination=URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "assets/brand", isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let iconset=destination.appendingPathComponent("Shou.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: alpha)
}
func polygon(_ points: [NSPoint]) -> NSBezierPath {
    let path=NSBezierPath(); path.move(to: points[0])
    for point in points.dropFirst() { path.line(to: point) }
    path.close(); path.lineJoinStyle = .round
    return path
}
func gradient(_ path: NSBezierPath, _ top: UInt32, _ bottom: UInt32) {
    NSGradient(starting: color(bottom), ending: color(top))!.draw(in: path, angle: 90)
}
func drawMark() {
    NSGraphicsContext.saveGraphicsState()
    let shadow=NSShadow(); shadow.shadowColor=color(0x3D2217, alpha: 0.20)
    shadow.shadowBlurRadius=28; shadow.shadowOffset=NSSize(width: 0, height: -14); shadow.set()
    let tile=NSBezierPath(roundedRect: NSRect(x: 96, y: 96, width: 832, height: 832), xRadius: 184, yRadius: 184)
    gradient(tile, 0xFFFCF7, 0xEDE8E1)
    NSGraphicsContext.restoreGraphicsState()
    color(0xFFFFFF, alpha: 0.88).setStroke(); tile.lineWidth=3; tile.stroke()

    // A folded container: the sides gather inward, the front makes a quiet smile.
    let body=NSBezierPath()
    body.move(to: NSPoint(x: 296, y: 568))
    body.line(to: NSPoint(x: 728, y: 568))
    body.line(to: NSPoint(x: 706, y: 344))
    body.curve(to: NSPoint(x: 660, y: 302), controlPoint1: NSPoint(x: 704, y: 317), controlPoint2: NSPoint(x: 687, y: 302))
    body.line(to: NSPoint(x: 364, y: 302))
    body.curve(to: NSPoint(x: 318, y: 344), controlPoint1: NSPoint(x: 337, y: 302), controlPoint2: NSPoint(x: 320, y: 317))
    body.close()
    NSGraphicsContext.saveGraphicsState()
    let objectShadow=NSShadow();objectShadow.shadowColor=color(0xA64A25, alpha: 0.23)
    objectShadow.shadowBlurRadius=26;objectShadow.shadowOffset=NSSize(width:0,height:-18);objectShadow.set()
    gradient(body, 0xE98A50, 0xC85A32)
    NSGraphicsContext.restoreGraphicsState()

    let inside=polygon([NSPoint(x:296,y:568),NSPoint(x:512,y:681),NSPoint(x:728,y:568),NSPoint(x:512,y:454)])
    gradient(inside,0xBD542F,0x9F4329)
    let left=polygon([NSPoint(x:296,y:568),NSPoint(x:244,y:656),NSPoint(x:458,y:752),NSPoint(x:512,y:681)])
    let right=polygon([NSPoint(x:512,y:681),NSPoint(x:566,y:752),NSPoint(x:780,y:656),NSPoint(x:728,y:568)])
    gradient(left,0xFFB978,0xEE9457);gradient(right,0xF2A264,0xDE753F)

    // The white fold flows down into the box; it remains readable at Dock size.
    let fold=NSBezierPath()
    fold.move(to:NSPoint(x:473,y:634));fold.line(to:NSPoint(x:551,y:634))
    fold.line(to:NSPoint(x:551,y:527));fold.line(to:NSPoint(x:600,y:527))
    fold.line(to:NSPoint(x:512,y:440));fold.line(to:NSPoint(x:424,y:527))
    fold.line(to:NSPoint(x:473,y:527));fold.close()
    gradient(fold,0xFFFCF4,0xF8E4CC)

    let lip=NSBezierPath()
    lip.move(to:NSPoint(x:325,y:397))
    lip.curve(to:NSPoint(x:699,y:397),controlPoint1:NSPoint(x:435,y:356),controlPoint2:NSPoint(x:589,y:356))
    color(0xFFD0A6,alpha:0.55).setStroke();lip.lineWidth=8;lip.lineCapStyle = .round;lip.stroke()
}

func raster(_ pixels: Int) throws -> Data {
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    bitmap.size=NSSize(width:pixels,height:pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
    NSGraphicsContext.current!.imageInterpolation = .high
    let transform=AffineTransform(scale:CGFloat(pixels)/1024);(transform as NSAffineTransform).concat()
    drawMark();NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using:.png,properties:[:])!
}

for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let suffix=scale == 2 ? "@2x" : ""
        try raster(size*scale).write(to:iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
try raster(1024).write(to:destination.appendingPathComponent("shou-icon-1024.png"))
// A vector PDF is exported from the same drawing commands as the raster sizes.
let vector=NSMutableData()
let consumer=CGDataConsumer(data:vector)!
var media=CGRect(x:0,y:0,width:1024,height:1024)
let pdf=CGContext(consumer:consumer,mediaBox:&media,nil)!
pdf.beginPDFPage(nil)
NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:pdf,flipped:false)
drawMark();NSGraphicsContext.restoreGraphicsState();pdf.endPDFPage();pdf.closePDF()
try (vector as Data).write(to:destination.appendingPathComponent("shou-icon.pdf"))
let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/iconutil")
process.arguments=["--convert","icns",iconset.path,"--output",destination.appendingPathComponent("Shou.icns").path]
try process.run();process.waitUntilExit()
guard process.terminationStatus == 0 else { throw NSError(domain:"ShouIcon",code:Int(process.terminationStatus)) }
print("Generated Shou.icns, 10 native icon representations, PNG preview and vector PDF.")
