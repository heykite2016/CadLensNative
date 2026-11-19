// Draws the 1024 pt master icon for CadLens and writes it as PNG.
//
//   swiftc -O Tools/make_icon.swift -o /tmp/mkicon -framework AppKit
//   /tmp/mkicon Resources/AppIcon-1024.png
//
// Tools/make_icon.sh turns the result into Resources/AppIcon.icns.

import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "Resources/AppIcon-1024.png"

guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size),
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

// MARK: Squircle body

let inset: CGFloat = 100
let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius: CGFloat = body.width * 0.2237
let plate = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius,
                   transform: nil)

// Soft drop shadow beneath the plate.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 36,
              color: NSColor.black.withAlphaComponent(0.28).cgColor)
ctx.addPath(plate)
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillPath()
ctx.restoreGState()

// Blueprint plate: deep navy, like a drafting sheet negative.
ctx.saveGState()
ctx.addPath(plate)
ctx.clip()
let colors = [NSColor(srgbRed: 0.13, green: 0.27, blue: 0.46, alpha: 1).cgColor,
              NSColor(srgbRed: 0.05, green: 0.11, blue: 0.21, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: body.midX, y: body.maxY),
                       end: CGPoint(x: body.midX, y: body.minY), options: [])

// Faint drafting grid.
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.06).cgColor)
ctx.setLineWidth(2)
var gx = body.minX + 48
while gx < body.maxX {
    ctx.move(to: CGPoint(x: gx, y: body.minY))
    ctx.addLine(to: CGPoint(x: gx, y: body.maxY))
    gx += 48
}
var gy = body.minY + 48
while gy < body.maxY {
    ctx.move(to: CGPoint(x: body.minX, y: gy))
    ctx.addLine(to: CGPoint(x: body.maxX, y: gy))
    gy += 48
}
ctx.strokePath()
ctx.restoreGState()

// MARK: Floor plan

ctx.saveGState()
ctx.addPath(plate)
ctx.clip()

let paper = NSColor(srgbRed: 0.97, green: 0.98, blue: 1.0, alpha: 1)
let accent = NSColor(srgbRed: 0.25, green: 0.80, blue: 0.98, alpha: 1)

let plan = CGRect(x: 268, y: 392, width: 488, height: 356)
let wall: CGFloat = 38

// Outer walls.
ctx.setStrokeColor(paper.cgColor)
ctx.setLineWidth(wall)
ctx.setLineJoin(.miter)
ctx.setLineCap(.butt)
ctx.addRect(plan.insetBy(dx: wall / 2, dy: wall / 2))
ctx.strokePath()

// Partition with a door opening in the middle.
let partitionX = plan.minX + plan.width * 0.56
let gapBottom = plan.minY + plan.height * 0.30
let gapTop = plan.minY + plan.height * 0.58
let partition = CGMutablePath()
partition.move(to: CGPoint(x: partitionX, y: plan.minY + wall / 2))
partition.addLine(to: CGPoint(x: partitionX, y: gapBottom))
partition.move(to: CGPoint(x: partitionX, y: gapTop))
partition.addLine(to: CGPoint(x: partitionX, y: plan.maxY - wall / 2))
ctx.setLineWidth(wall * 0.66)
ctx.addPath(partition)
ctx.strokePath()

// Door leaf and swing arc.
let hinge = CGPoint(x: partitionX, y: gapTop)
let leaf = gapTop - gapBottom
ctx.setLineWidth(wall * 0.5)
ctx.setLineCap(.round)
ctx.move(to: hinge)
ctx.addLine(to: CGPoint(x: partitionX + leaf, y: gapTop))
ctx.strokePath()

let swing = CGMutablePath()
swing.addArc(center: hinge, radius: leaf, startAngle: .pi / 2,
             endAngle: 0, clockwise: true)
ctx.setLineDash(phase: 0, lengths: [20, 14])
ctx.setLineWidth(8)
ctx.setStrokeColor(paper.withAlphaComponent(0.5).cgColor)
ctx.addPath(swing)
ctx.strokePath()
ctx.setLineDash(phase: 0, lengths: [])

// Dimension line: the measurement motif of the app.
let dimY = plan.minY - 68
ctx.setStrokeColor(accent.cgColor)
ctx.setLineWidth(12)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: plan.minX + 2, y: dimY))
ctx.addLine(to: CGPoint(x: plan.maxX - 2, y: dimY))
ctx.strokePath()

for (x, direction) in [(plan.minX + 2, CGFloat(1)), (plan.maxX - 2, CGFloat(-1))] {
    ctx.setLineWidth(10)
    ctx.setLineCap(.butt)
    ctx.move(to: CGPoint(x: x, y: dimY - 32))
    ctx.addLine(to: CGPoint(x: x, y: dimY + 32))
    ctx.strokePath()
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: x, y: dimY))
    arrow.addLine(to: CGPoint(x: x + 40 * direction, y: dimY + 20))
    arrow.addLine(to: CGPoint(x: x + 40 * direction, y: dimY - 20))
    arrow.closeSubpath()
    ctx.addPath(arrow)
    ctx.setFillColor(accent.cgColor)
    ctx.fillPath()
}

ctx.restoreGState()

// Crisp edge highlight on the plate.
ctx.addPath(plate)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
ctx.setLineWidth(3)
ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()

guard let image = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
let url = URL(fileURLWithPath: output)
try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
try data.write(to: url)
print("wrote \(output)")
