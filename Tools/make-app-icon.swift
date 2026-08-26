import AppKit
import CoreGraphics
import Foundation

// The Tabler "terminal" icon, drawn on the macOS application icon shape.
// Glyph, in the 24 by 24 grid Tabler uses:
//   M5 7 l5 5 l-5 5      the prompt chevron
//   M12 19 h7            the input line
let scale: CGFloat = 30
let offset = CGPoint(x: 152, y: 122)

func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: offset.x + x * scale, y: offset.y + y * scale)
}

func draw(size: Int) -> CGImage {
    let side = 1024
    let space = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                            bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Draw with the origin at the top left, the way the SVG grid works.
    context.translateBy(x: 0, y: CGFloat(side))
    context.scaleBy(x: 1, y: -1)
    context.setAllowsAntialiasing(true)

    // The rounded square that macOS expects, inside a clear margin.
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.231, green: 0.259, blue: 0.322, alpha: 1),  // #3B4252
        CGColor(red: 0.106, green: 0.118, blue: 0.149, alpha: 1),  // #1B1E26
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 100),
                               end: CGPoint(x: 0, y: 924), options: [])
    context.restoreGState()

    context.setLineWidth(2 * scale)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    context.setStrokeColor(CGColor(red: 0.290, green: 0.871, blue: 0.502, alpha: 1))  // #4ADE80
    context.move(to: point(5, 7))
    context.addLine(to: point(10, 12))
    context.addLine(to: point(5, 17))
    context.strokePath()

    context.setStrokeColor(CGColor(red: 0.949, green: 0.957, blue: 0.973, alpha: 1))  // #F2F4F8
    context.move(to: point(12, 19))
    context.addLine(to: point(19, 19))
    context.strokePath()

    let full = context.makeImage()!
    guard size != side else { return full }

    let small = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                          bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    small.interpolationQuality = .high
    small.draw(full, in: CGRect(x: 0, y: 0, width: size, height: size))
    return small.makeImage()!
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

for (name, size) in [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
] {
    let image = draw(size: size)
    let url = directory.appendingPathComponent("\(name).png")
    let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil
    )!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}
print("wrote \(directory.path)")
