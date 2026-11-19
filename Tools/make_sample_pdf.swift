// Generates Samples/plan.pdf — a vector PDF drawing used to exercise the
// PDFKit path of the viewer (page navigation, zoom fidelity, measurement).
//
//   swiftc -O Tools/make_sample_pdf.swift -o /tmp/mps -framework AppKit -framework CoreGraphics
//   /tmp/mps Samples/plan.pdf

import AppKit

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Samples/plan.pdf"
let pageWidth: CGFloat = 1191  // A3 landscape, points
let pageHeight: CGFloat = 842

func withGraphicsContext(_ ctx: CGContext, _ body: () -> Void) {
    let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    body()
    NSGraphicsContext.restoreGraphicsState()
}

func drawSheet(_ ctx: CGContext, offsetX: CGFloat, title: String) {
    ctx.saveGState()
    ctx.translateBy(x: offsetX, y: 0)

    let ink = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
    let thin = NSColor(calibratedWhite: 0.45, alpha: 1).cgColor

    // Outer wall loop (a 8.4 m x 6.2 m unit at 1:50 → 1 pt = 0.5 mm → 1 m = 56.7 pt)
    let unit: CGFloat = 56.7
    let wall: CGFloat = 6
    let plan = CGRect(x: 150, y: 300, width: 8.4 * unit, height: 6.2 * unit)

    ctx.setFillColor(NSColor(calibratedWhite: 0.92, alpha: 1).cgColor)
    ctx.fill(plan.insetBy(dx: 0, dy: 0))
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(wall)
    ctx.stroke(plan)

    // Interior partitions
    ctx.setLineWidth(3)
    let partitions: [(CGPoint, CGPoint)] = [
        (CGPoint(x: plan.minX + 4.6 * unit, y: plan.minY),
         CGPoint(x: plan.minX + 4.6 * unit, y: plan.minY + 3.5 * unit)),
        (CGPoint(x: plan.minX + 4.6 * unit, y: plan.minY + 3.5 * unit),
         CGPoint(x: plan.maxX, y: plan.minY + 3.5 * unit)),
        (CGPoint(x: plan.minX, y: plan.minY + 3.9 * unit),
         CGPoint(x: plan.minX + 2.6 * unit, y: plan.minY + 3.9 * unit)),
    ]
    for (a, b) in partitions {
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()
    }

    // Door swings
    ctx.setLineWidth(1)
    ctx.setStrokeColor(thin)
    for center in [CGPoint(x: plan.minX + 4.6 * unit, y: plan.minY + 1.2 * unit),
                   CGPoint(x: plan.minX + 1.6 * unit, y: plan.minY + 3.9 * unit)] {
        let r = 0.9 * unit
        ctx.addArc(center: center, radius: r, startAngle: 0, endAngle: .pi / 2, clockwise: false)
        ctx.strokePath()
    }

    // Window symbols on the north wall
    ctx.setLineWidth(1.2)
    ctx.setStrokeColor(ink)
    var x = plan.minX + 1.2 * unit
    while x < plan.maxX - 1.2 * unit {
        ctx.addRect(CGRect(x: x, y: plan.maxY - 3, width: 1.1 * unit, height: 6))
        x += 2.4 * unit
    }
    ctx.strokePath()

    // Grid axes with bubbles
    ctx.setLineWidth(0.6)
    ctx.setStrokeColor(NSColor(calibratedRed: 0.55, green: 0.15, blue: 0.15, alpha: 1).cgColor)
    ctx.setLineDash(phase: 0, lengths: [12, 4, 3, 4])
    for i in 0...3 {
        let gx = plan.minX + CGFloat(i) * 2.8 * unit
        ctx.move(to: CGPoint(x: gx, y: plan.minY - 60))
        ctx.addLine(to: CGPoint(x: gx, y: plan.maxY + 60))
        ctx.strokePath()
    }
    ctx.setLineDash(phase: 0, lengths: [])
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(1)
    for i in 0...3 {
        let gx = plan.minX + CGFloat(i) * 2.8 * unit
        let bubble = CGRect(x: gx - 11, y: plan.maxY + 62, width: 22, height: 22)
        ctx.strokeEllipse(in: bubble)
        let label = NSAttributedString(string: "\(i + 1)", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.black,
        ])
        let size = label.size()
        withGraphicsContext(ctx) {
            label.draw(at: CGPoint(x: bubble.midX - size.width / 2,
                                   y: bubble.midY - size.height / 2))
        }
    }

    // Dimension line along the bottom
    ctx.setLineWidth(0.8)
    ctx.setStrokeColor(ink)
    let dimY = plan.minY - 38
    ctx.move(to: CGPoint(x: plan.minX, y: dimY))
    ctx.addLine(to: CGPoint(x: plan.maxX, y: dimY))
    ctx.strokePath()
    for edge in [plan.minX, plan.maxX] {
        ctx.move(to: CGPoint(x: edge, y: dimY - 5))
        ctx.addLine(to: CGPoint(x: edge, y: dimY + 5))
        ctx.move(to: CGPoint(x: edge, y: dimY))
        ctx.addLine(to: CGPoint(x: edge, y: plan.minY))
        ctx.strokePath()
    }
    let dimText = NSAttributedString(string: "8400", attributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
        .foregroundColor: NSColor.black,
    ])
    let dimSize = dimText.size()
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: plan.midX - dimSize.width / 2 - 3, y: dimY - 3,
                    width: dimSize.width + 6, height: dimSize.height + 2))
    withGraphicsContext(ctx) {
        dimText.draw(at: CGPoint(x: plan.midX - dimSize.width / 2, y: dimY - 3))
    }

    // Room labels
    let rooms: [(String, CGPoint, CGFloat)] = [
        ("起居室 LIVING", CGPoint(x: plan.minX + 2.3 * unit, y: plan.minY + 2.5 * unit), 15),
        ("主卧 BEDROOM", CGPoint(x: plan.minX + 6.5 * unit, y: plan.minY + 1.7 * unit), 15),
        ("厨房 KITCHEN", CGPoint(x: plan.minX + 1.3 * unit, y: plan.minY + 5.0 * unit), 13),
        ("阳台", CGPoint(x: plan.minX + 5.6 * unit, y: plan.minY + 4.9 * unit), 13),
    ]
    for (text, center, size) in rooms {
        let label = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: NSColor(calibratedWhite: 0.15, alpha: 1),
        ])
        let s = label.size()
        withGraphicsContext(ctx) {
            label.draw(at: CGPoint(x: center.x - s.width / 2, y: center.y - s.height / 2))
        }
    }

    // Title block
    let block = CGRect(x: pageWidth - 430, y: 60, width: 380, height: 150)
    ctx.setLineWidth(1.2)
    ctx.setStrokeColor(ink)
    ctx.stroke(block)
    ctx.setLineWidth(0.6)
    for y in stride(from: block.minY + 30, to: block.maxY, by: 30) {
        ctx.move(to: CGPoint(x: block.minX, y: y))
        ctx.addLine(to: CGPoint(x: block.maxX, y: y))
    }
    ctx.strokePath()

    let titleText = NSAttributedString(string: title, attributes: [
        .font: NSFont.systemFont(ofSize: 20, weight: .medium),
        .foregroundColor: NSColor.black,
    ])
    withGraphicsContext(ctx) {
        titleText.draw(at: CGPoint(x: block.minX + 12, y: block.maxY - 26))
    }
    let rows = ["比例 1:50", "图号 A-102", "日期 2026-11-14", "制图 CadLens"]
    for (index, row) in rows.enumerated() {
        let text = NSAttributedString(string: row, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor(calibratedWhite: 0.25, alpha: 1),
        ])
        withGraphicsContext(ctx) {
            text.draw(at: CGPoint(x: block.minX + 12,
                                  y: block.maxY - 52 - CGFloat(index) * 30))
        }
    }
    ctx.restoreGState()
}

var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
guard let ctx = CGContext(URL(fileURLWithPath: outputPath) as CFURL, mediaBox: &mediaBox, nil) else {
    FileHandle.standardError.write("cannot create PDF\n".data(using: .utf8)!)
    exit(1)
}

let titles = ["首层平面图 GROUND FLOOR", "二层平面图 FIRST FLOOR"]
for (index, title) in titles.enumerated() {
    ctx.beginPDFPage(nil)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(mediaBox)
    drawSheet(ctx, offsetX: 0, title: title)
    // Sheet frame + page number
    ctx.setStrokeColor(NSColor(calibratedWhite: 0.2, alpha: 1).cgColor)
    ctx.setLineWidth(1.6)
    ctx.stroke(mediaBox.insetBy(dx: 24, dy: 24))
    let pageLabel = NSAttributedString(string: "\(index + 1) / \(titles.count)", attributes: [
        .font: NSFont.systemFont(ofSize: 10),
        .foregroundColor: NSColor(calibratedWhite: 0.35, alpha: 1),
    ])
    withGraphicsContext(ctx) {
        pageLabel.draw(at: CGPoint(x: 40, y: 34))
    }
    ctx.endPDFPage()
}
ctx.closePDF()
print("wrote \(outputPath)")
