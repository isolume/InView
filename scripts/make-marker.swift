// Generates the check-in marker: a high-contrast, non-repeating pattern that ARKit tracks well,
// plus a print-ready PDF at the exact physical width the app expects (Marker.physicalWidth).
//
// Usage: swift scripts/make-marker.swift AccessNav/Resources/marker.png print/check-in-marker.pdf

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let markerWidthCentimeters = 18.0
let pixels = 1024

/// SplitMix64, so the pattern is identical every run.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

func drawText(_ string: String, size: CGFloat, centeredAt point: CGPoint, in context: CGContext) {
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    context.textPosition = CGPoint(x: point.x - width / 2, y: point.y)
    CTLineDraw(line, context)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: swift make-marker.swift <marker.png> <marker.pdf>")
    exit(1)
}
let pngURL = URL(fileURLWithPath: arguments[1])
let pdfURL = URL(fileURLWithPath: arguments[2])

// Pattern
let canvas = CGRect(x: 0, y: 0, width: pixels, height: pixels)
let context = CGContext(
    data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
context.setFillColor(color(1, 1, 1))
context.fill(canvas)

let black = color(0, 0, 0)
let palette = [black, black, black, color(0.05, 0.35, 0.95), color(0.98, 0.55, 0.05), color(0.85, 0.1, 0.2), color(0.1, 0.6, 0.3)]
var random = SeededGenerator(state: 2026)
for _ in 0..<90 {
    context.saveGState()
    context.translateBy(x: .random(in: 60...964, using: &random), y: .random(in: 60...964, using: &random))
    context.rotate(by: .random(in: 0...(2 * .pi), using: &random))
    context.setFillColor(palette.randomElement(using: &random)!)
    let w = CGFloat.random(in: 24...180, using: &random), h = CGFloat.random(in: 24...180, using: &random)
    let box = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
    switch Int.random(in: 0..<3, using: &random) {
    case 0:
        context.fill(box)
    case 1:
        context.fillEllipse(in: box)
    default:
        context.move(to: CGPoint(x: box.minX, y: box.minY))
        context.addLine(to: CGPoint(x: box.maxX, y: box.minY))
        context.addLine(to: CGPoint(x: box.midX * 0.3, y: box.maxY))
        context.closePath()
        context.fillPath()
    }
    context.restoreGState()
}
// A thick frame and one solid corner block make the orientation unambiguous.
context.setStrokeColor(black)
context.setLineWidth(48)
context.stroke(canvas.insetBy(dx: 24, dy: 24))
context.setFillColor(black)
context.fill(CGRect(x: 48, y: CGFloat(pixels) - 48 - 150, width: 150, height: 150))
let image = context.makeImage()!

let png = CGImageDestinationCreateWithURL(pngURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(png, image, nil)
guard CGImageDestinationFinalize(png) else { fatalError("could not write \(pngURL.path)") }

// Print sheet (US Letter; also fits A4 when printed at actual size)
var page = CGRect(x: 0, y: 0, width: 612, height: 792)
let pdf = CGContext(pdfURL as CFURL, mediaBox: &page, nil)!
pdf.beginPDFPage(nil)
let side = markerWidthCentimeters / 2.54 * 72
let markerRect = CGRect(x: (page.width - side) / 2, y: page.height - 110 - side, width: side, height: side)
pdf.draw(image, in: markerRect)
pdf.setFillColor(black)
drawText("AccessNav check-in point", size: 26, centeredAt: CGPoint(x: page.midX, y: page.height - 80), in: pdf)
drawText("Point your camera here to start navigation", size: 16, centeredAt: CGPoint(x: page.midX, y: markerRect.minY - 36), in: pdf)
drawText("Print at 100% (actual size). The pattern must measure exactly \(Int(markerWidthCentimeters)) cm wide.", size: 11, centeredAt: CGPoint(x: page.midX, y: 60), in: pdf)
drawText("Do not move this sign between scanning and navigating.", size: 11, centeredAt: CGPoint(x: page.midX, y: 44), in: pdf)
pdf.endPDFPage()
pdf.closePDF()

print("wrote \(pngURL.path) and \(pdfURL.path)")
