import AppKit

/// Hand-drawn icon set for the CAD chrome.
///
/// SF Symbols were the wrong vocabulary for this application: `ruler`,
/// `hexagon` and `circle.dashed` are generic system metaphors, they carry no
/// drafting meaning, and at 14 pt they cannot be told apart in a vertical
/// strip of fourteen near-identical glyphs. These are drawn on a 24×24 grid
/// with drafting semantics — a dimension line with its witness lines and
/// architectural tick, a hatched region, an arc with its end arrows — so the
/// tool strip reads like the tool palettes in AutoCAD, ZWCAD and CADbro.
enum CADGlyph {
    // View / file
    case select, pan, zoomWindow, zoomFit, zoomIn, zoomOut
    case open, print, export, undo, redo, settings, layers, annotations
    case eye, eyeOff, trash, trashAll

    // Measurement
    case aligned, linear, continuous, batch, rectangle, polygon
    case circleArea, hatchArea, sideArea, radius, angle, arcLength
    case note, calibrate

    // Drafting aids
    case snap, ortho, grid, lineweight, ruler, chevronDown, panel

    /// Draws the glyph centred in `rect` (a y-down rectangle).
    func draw(in ctx: CGContext, rect: CGRect, color: NSColor, lineWidth: CGFloat = 1.5) {
        let side = min(rect.width, rect.height)
        guard side > 1 else { return }
        let s = side / 24
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        // The design grid is y-up; every chrome view in this app is flipped.
        ctx.translateBy(x: rect.midX - 12 * s, y: rect.midY + 12 * s)
        ctx.scaleBy(x: s, y: -s)
        ctx.setLineWidth(lineWidth / s)
        paint(ctx)
        ctx.restoreGState()
    }

    /// Template image for places that need an `NSImage` (menus, table cells).
    func image(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            self.draw(in: ctx, rect: rect, color: .black, lineWidth: 1.6)
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: Painting

    private func paint(_ c: CGContext) {
        switch self {
        case .select: select(c)
        case .pan: pan(c)
        case .zoomWindow: zoomWindow(c)
        case .zoomFit: zoomFit(c)
        case .zoomIn: magnifier(c, plus: true)
        case .zoomOut: magnifier(c, plus: false)
        case .open: folder(c)
        case .print: printer(c)
        case .export: export(c)
        case .undo: curvedArrow(c, mirrored: false)
        case .redo: curvedArrow(c, mirrored: true)
        case .settings: gear(c)
        case .layers: layers(c)
        case .annotations: annotationList(c)
        case .eye: eye(c, open: true)
        case .eyeOff: eye(c, open: false)
        case .trash: trash(c, crossed: false)
        case .trashAll: trash(c, crossed: true)
        case .aligned: aligned(c)
        case .linear: linear(c)
        case .continuous: continuous(c)
        case .batch: batch(c)
        case .rectangle: rectangle(c)
        case .polygon: polygon(c)
        case .circleArea: circleArea(c)
        case .hatchArea: hatchArea(c)
        case .sideArea: sideArea(c)
        case .radius: radius(c)
        case .angle: angle(c)
        case .arcLength: arcLength(c)
        case .note: note(c)
        case .calibrate: calibrate(c)
        case .snap: snap(c)
        case .ortho: ortho(c)
        case .grid: grid(c)
        case .lineweight: lineweight(c)
        case .ruler: ruler(c)
        case .chevronDown: chevron(c)
        case .panel: panel(c)
        }
    }

    private func line(_ c: CGContext, _ x1: CGFloat, _ y1: CGFloat,
                      _ x2: CGFloat, _ y2: CGFloat) {
        c.move(to: CGPoint(x: x1, y: y1))
        c.addLine(to: CGPoint(x: x2, y: y2))
        c.strokePath()
    }

    private func rect(_ c: CGContext, _ x: CGFloat, _ y: CGFloat,
                      _ w: CGFloat, _ h: CGFloat, fill: Bool = false) {
        let r = CGRect(x: x, y: y, width: w, height: h)
        if fill { c.fill(r) } else { c.stroke(r) }
    }

    private func dashedRect(_ c: CGContext, _ x: CGFloat, _ y: CGFloat,
                            _ w: CGFloat, _ h: CGFloat) {
        c.saveGState()
        c.setLineDash(phase: 0, lengths: [2.6, 2.0])
        rect(c, x, y, w, h)
        c.restoreGState()
    }

    /// Architectural 45° tick — the GB/T 50001 dimension terminator.
    private func tick(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 2.6) {
        line(c, x - size, y - size, x + size, y + size)
    }

    private func dot(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat = 1.1) {
        c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    /// Solid arrowhead whose tip is `(x, y)`, pointing along `(dx, dy)`.
    private func arrow(_ c: CGContext, _ x: CGFloat, _ y: CGFloat,
                       _ dx: CGFloat, _ dy: CGFloat, size: CGFloat = 4.2) {
        let len = max(hypot(dx, dy), 0.001)
        let ux = dx / len, uy = dy / len
        let px = -uy, py = ux
        c.move(to: CGPoint(x: x, y: y))
        c.addLine(to: CGPoint(x: x - ux * size + px * size * 0.42,
                              y: y - uy * size + py * size * 0.42))
        c.addLine(to: CGPoint(x: x - ux * size - px * size * 0.42,
                              y: y - uy * size - py * size * 0.42))
        c.closePath()
        c.fillPath()
    }

    private func circle(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
        c.strokeEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    // MARK: View / file glyphs

    private func select(_ c: CGContext) {
        // 标准指针箭头：尖在左上、尾部的两个倒钩在右下。之前这组坐标画出来是
        // 倒着的（尖朝右下），工具栏上看着像个"后退"符号，不像选择。
        c.move(to: CGPoint(x: 6, y: 21))
        c.addLine(to: CGPoint(x: 6, y: 6.5))
        c.addLine(to: CGPoint(x: 9.6, y: 10.1))
        c.addLine(to: CGPoint(x: 12.2, y: 3.5))
        c.addLine(to: CGPoint(x: 14.6, y: 4.6))
        c.addLine(to: CGPoint(x: 12.1, y: 10.9))
        c.addLine(to: CGPoint(x: 17.5, y: 11.3))
        c.closePath()
        c.fillPath()
    }

    private func pan(_ c: CGContext) {
        // Longer arms with small heads read as a plus sign — the "add" glyph.
        // Short arms and a 5-unit head read as a four-way move handle.
        line(c, 12, 6.6, 12, 17.4)
        line(c, 6.6, 12, 17.4, 12)
        arrow(c, 12, 3.6, 0, -1, size: 5.2)
        arrow(c, 12, 20.4, 0, 1, size: 5.2)
        arrow(c, 3.6, 12, -1, 0, size: 5.2)
        arrow(c, 20.4, 12, 1, 0, size: 5.2)
    }

    private func zoomWindow(_ c: CGContext) {
        dashedRect(c, 3, 5, 12, 11)
        circle(c, 15.2, 15.2, 4.4)
        line(c, 18.4, 18.4, 21.2, 21.2)
    }

    private func zoomFit(_ c: CGContext) {
        // Four corner brackets around the extents.
        let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (3.5, 3.5, 1, 1), (20.5, 3.5, -1, 1),
            (3.5, 20.5, 1, -1), (20.5, 20.5, -1, -1)]
        for (x, y, sx, sy) in corners {
            line(c, x, y, x + sx * 4.5, y)
            line(c, x, y, x, y + sy * 4.5)
        }
        rect(c, 9.5, 9.5, 5, 5)
    }

    private func magnifier(_ c: CGContext, plus: Bool) {
        circle(c, 10.5, 10.5, 6)
        line(c, 15, 15, 20.5, 20.5)
        line(c, 7.6, 10.5, 13.4, 10.5)
        if plus { line(c, 10.5, 7.6, 10.5, 13.4) }
    }

    private func folder(_ c: CGContext) {
        c.move(to: CGPoint(x: 3, y: 6.5))
        c.addLine(to: CGPoint(x: 9.2, y: 6.5))
        c.addLine(to: CGPoint(x: 11, y: 8.8))
        c.addLine(to: CGPoint(x: 21, y: 8.8))
        c.addLine(to: CGPoint(x: 21, y: 19))
        c.addLine(to: CGPoint(x: 3, y: 19))
        c.closePath()
        c.strokePath()
        line(c, 3, 11.5, 21, 11.5)
    }

    private func printer(_ c: CGContext) {
        rect(c, 6.5, 3.5, 11, 5.5)
        rect(c, 3, 9, 18, 7.5)
        rect(c, 6.5, 14, 11, 6.5)
        line(c, 6.5, 17.2, 17.5, 17.2)
    }

    private func export(_ c: CGContext) {
        line(c, 12, 15, 12, 3.6)
        arrow(c, 12, 3.2, 0, -1, size: 4)
        c.move(to: CGPoint(x: 4.5, y: 12))
        c.addLine(to: CGPoint(x: 4.5, y: 20.5))
        c.addLine(to: CGPoint(x: 19.5, y: 20.5))
        c.addLine(to: CGPoint(x: 19.5, y: 12))
        c.strokePath()
    }

    private func curvedArrow(_ c: CGContext, mirrored: Bool) {
        c.saveGState()
        if mirrored {
            c.translateBy(x: 24, y: 0)
            c.scaleBy(x: -1, y: 1)
        }
        // A flat arc plus a 4-unit head was indistinguishable from a stray
        // curve at 17 pt; the head is now a third of the glyph and the arc
        // drops further so the direction reads at a glance.
        c.move(to: CGPoint(x: 20, y: 16.8))
        c.addCurve(to: CGPoint(x: 6.4, y: 11.2),
                   control1: CGPoint(x: 19, y: 8.6),
                   control2: CGPoint(x: 12.2, y: 7.4))
        c.strokePath()
        arrow(c, 5.6, 11.6, -1.0, 0.62, size: 5.4)
        c.restoreGState()
    }

    private func gear(_ c: CGContext) {
        circle(c, 12, 12, 4)
        for i in 0..<8 {
            let angle = Double(i) * .pi / 4 + .pi / 8
            let x1 = 12 + cos(angle) * 5.4, y1 = 12 + sin(angle) * 5.4
            let x2 = 12 + cos(angle) * 7.6, y2 = 12 + sin(angle) * 7.6
            line(c, x1, y1, x2, y2)
        }
        circle(c, 12, 12, 7.6)
    }

    /// 信息面板：一个框 + 右侧实心栏，读作"侧栏"。
    private func panel(_ c: CGContext) {
        rect(c, 3, 4.5, 18, 15)
        c.fill(CGRect(x: 14.4, y: 4.5, width: 6.6, height: 15))
        line(c, 14.4, 4.5, 14.4, 19.5)
    }

    private func layers(_ c: CGContext) {
        // Three stacked plates: the classic layer-manager metaphor.
        for (index, dy) in [(-5.2 as CGFloat), 0, 5.2].enumerated() {
            let y = 12 + dy
            c.move(to: CGPoint(x: 12, y: y - 3.6))
            c.addLine(to: CGPoint(x: 20, y: y))
            c.addLine(to: CGPoint(x: 12, y: y + 3.6))
            c.addLine(to: CGPoint(x: 4, y: y))
            c.closePath()
            if index == 1 { c.fillPath() } else { c.strokePath() }
        }
    }

    private func annotationList(_ c: CGContext) {
        for (i, y) in [5.5, 12, 18.5].enumerated() {
            dot(c, 4.5, y, 1.5)
            line(c, 8, y, 20, y)
            if i == 0 { line(c, 8, y + 2.4, 15, y + 2.4) }
        }
    }

    private func eye(_ c: CGContext, open: Bool) {
        c.move(to: CGPoint(x: 2.5, y: 12))
        c.addCurve(to: CGPoint(x: 21.5, y: 12),
                   control1: CGPoint(x: 7, y: 5),
                   control2: CGPoint(x: 17, y: 5))
        c.addCurve(to: CGPoint(x: 2.5, y: 12),
                   control1: CGPoint(x: 17, y: 19),
                   control2: CGPoint(x: 7, y: 19))
        c.strokePath()
        if open {
            circle(c, 12, 12, 3)
            dot(c, 12, 12, 1.4)
        } else {
            line(c, 4, 20, 20, 4)
        }
    }

    private func trash(_ c: CGContext, crossed: Bool) {
        // 桶身在下、桶盖在上：原来的坐标把盖子画到了桶底，缩到 14pt 就是一个
        // 说不出是什么的方块。
        // 设计网格是 y 向上的（绘制时整体上下翻转），所以桶盖要写在 y 大的
        // 那一侧，否则整个垃圾桶会倒过来——之前就是这个毛病。
        rect(c, 6.2, 4, 11.6, 12.6)
        line(c, 5.2, 16.6, 18.8, 16.6)
        line(c, 9.6, 19.4, 14.4, 19.4)
        line(c, 9.6, 19.4, 9.6, 16.6)
        line(c, 14.4, 19.4, 14.4, 16.6)
        line(c, 10.2, 14.2, 10.2, 7.4)
        line(c, 13.8, 14.2, 13.8, 7.4)
        if crossed {
            c.saveGState()
            c.setStrokeColor(NSColor.black.cgColor)
            c.setLineWidth(3.4)
            line(c, 5, 4, 19, 20)
            c.restoreGState()
        }
    }

    // MARK: Measurement glyphs

    private func aligned(_ c: CGContext) {
        // Witness lines dropped from the two picked points, a slanted dimension
        // line between them and 45° architectural ticks at both ends.
        line(c, 4.5, 7, 4.5, 17)
        line(c, 19.5, 12, 19.5, 21.5)
        line(c, 4.5, 15.5, 19.5, 9.5)
        tick(c, 4.5, 15.5, size: 2.2)
        tick(c, 19.5, 9.5, size: 2.2)
    }

    private func linear(_ c: CGContext) {
        // Horizontal dimension: two witness lines, one dimension line, arrowed.
        line(c, 4.5, 5.5, 4.5, 18.5)
        line(c, 19.5, 5.5, 19.5, 18.5)
        line(c, 4.5, 13, 19.5, 13)
        // 45° terminators, not arrowheads: this is what the canvas actually
        // draws (GB/T 50001), and the icon should not promise another style.
        tick(c, 4.5, 13, size: 2.5)
        tick(c, 19.5, 13, size: 2.5)
    }

    private func continuous(_ c: CGContext) {
        let pts: [(CGFloat, CGFloat)] = [(3.5, 17.5), (9, 11), (15, 15), (20.5, 8)]
        c.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
        for p in pts.dropFirst() { c.addLine(to: CGPoint(x: p.0, y: p.1)) }
        c.strokePath()
        for (x, y) in pts {
            line(c, x, y - 2.4, x, y + 2.4)
            dot(c, x, y, 1.2)
        }
    }

    private func batch(_ c: CGContext) {
        // Three separate small dimensions stacked: several measurements at once.
        for (i, y) in [(7.0 as CGFloat), 12.5, 18.0].enumerated() {
            line(c, 4, y - 3, 4, y + 1.5)
            line(c, 20, y - 3, 20, y + 1.5)
            line(c, 4, y, 20, y)
            if i != 2 {
                tick(c, 4, y, size: 1.9)
                tick(c, 20, y, size: 1.9)
            }
        }
    }

    private func rectangle(_ c: CGContext) {
        // Two opposite corners and the dashed region they would sweep. The
        // diagonal that used to join them made the whole glyph read as a
        // "no" slash inside a box at palette size.
        dashedRect(c, 4, 6, 16, 12)
        dot(c, 4, 6, 1.8)
        dot(c, 20, 18, 1.8)
    }

    private func polygon(_ c: CGContext) {
        c.move(to: CGPoint(x: 12, y: 3.5))
        c.addLine(to: CGPoint(x: 20.5, y: 9.5))
        c.addLine(to: CGPoint(x: 17.2, y: 19.5))
        c.addLine(to: CGPoint(x: 6.8, y: 19.5))
        c.addLine(to: CGPoint(x: 3.5, y: 9.5))
        c.closePath()
        c.strokePath()
        for p in [(12.0, 3.5), (20.5, 9.5), (17.2, 19.5), (6.8, 19.5), (3.5, 9.5)] {
            dot(c, p.0, p.1, 1.1)
        }
    }

    private func circleArea(_ c: CGContext) {
        circle(c, 12, 12, 8)
        // Hatch inside the circle. A dashed diameter through the middle read
        // as the "no entry" sign at 17 pt; hatching says "the area of this
        // closed region", which is what the tool measures.
        c.saveGState()
        c.clip(to: CGRect(x: 4, y: 4, width: 16, height: 16))
        c.addEllipse(in: CGRect(x: 4, y: 4, width: 16, height: 16))
        c.clip()
        for i in stride(from: -6.0, through: 22.0, by: 4.4) {
            line(c, i, 4, i + 10, 20)
        }
        c.restoreGState()
        circle(c, 12, 12, 8)
    }

    private func hatchArea(_ c: CGContext) {
        rect(c, 4, 5.5, 16, 13)
        c.saveGState()
        c.clip(to: CGRect(x: 4, y: 5.5, width: 16, height: 13))
        for i in stride(from: -6.0, through: 26.0, by: 4.2) {
            line(c, i, 5.5, i + 13, 18.5)
        }
        c.restoreGState()
    }

    private func sideArea(_ c: CGContext) {
        // A wall face with its height dimension on the right: the tool is
        // length × height, so the glyph has to show both a face and a height.
        rect(c, 3.5, 7, 10.5, 12.5)
        line(c, 17.5, 7, 17.5, 19.5)
        line(c, 14, 7, 19, 7)
        line(c, 14, 19.5, 19, 19.5)
        tick(c, 17.5, 7, size: 2.2)
        tick(c, 17.5, 19.5, size: 2.2)
    }

    private func radius(_ c: CGContext) {
        circle(c, 11, 12, 7.5)
        dot(c, 11, 12, 1.3)
        line(c, 11, 12, 16.0, 8.0)
        arrow(c, 16.6, 7.4, 0.7, -0.7, size: 4.8)
    }

    private func angle(_ c: CGContext) {
        line(c, 4, 19, 21, 19)
        line(c, 4, 19, 18, 6)
        c.addArc(center: CGPoint(x: 4, y: 19), radius: 8,
                 startAngle: 0, endAngle: -0.72, clockwise: true)
        c.strokePath()
    }

    private func arcLength(_ c: CGContext) {
        c.move(to: CGPoint(x: 4.5, y: 18.5))
        c.addQuadCurve(to: CGPoint(x: 19.5, y: 18.5),
                       control: CGPoint(x: 12, y: 2.5))
        c.strokePath()
        arrow(c, 4.2, 18.4, -0.6, 0.8, size: 3.4)
        arrow(c, 19.8, 18.4, 0.6, 0.8, size: 3.4)
        dot(c, 12, 10.6, 1.3)
    }

    private func note(_ c: CGContext) {
        // Leader from the picked point up to a text frame.
        line(c, 5, 21, 10.5, 14.5)
        dot(c, 4.6, 21.4, 1.3)
        rect(c, 10, 4, 10.5, 8)
        line(c, 12.4, 7, 18.1, 7)
        line(c, 12.4, 9.4, 16.4, 9.4)
    }

    private func calibrate(_ c: CGContext) {
        c.saveGState()
        c.translateBy(x: 12, y: 12)
        c.rotate(by: -.pi / 5)
        rect(c, -9, -3, 18, 6)
        var shortIndex = 0
        for i in stride(from: -6.5, through: 6.5, by: 3.2) {
            line(c, i, 3, i, shortIndex.isMultiple(of: 2) ? -1.6 : 1.2)
            shortIndex += 1
        }
        c.restoreGState()
    }

    // MARK: Drafting aids

    private func snap(_ c: CGContext) {
        rect(c, 7.5, 7.5, 9, 9)
        line(c, 12, 3, 12, 7.5)
        line(c, 12, 16.5, 12, 21)
        line(c, 3, 12, 7.5, 12)
        line(c, 16.5, 12, 21, 12)
        dot(c, 12, 12, 1.2)
    }

    private func ortho(_ c: CGContext) {
        line(c, 5, 20, 5, 9)
        line(c, 5, 9, 19, 9)
        rect(c, 5, 9, 3.2, 3.2)
        arrow(c, 5, 20.6, 0, 1, size: 3.2)
        arrow(c, 19.6, 9, 1, 0, size: 3.2)
    }

    private func grid(_ c: CGContext) {
        rect(c, 3.5, 3.5, 17, 17)
        for v in [9.2, 14.8] {
            line(c, v, 3.5, v, 20.5)
            line(c, 3.5, v, 20.5, v)
        }
    }

    private func lineweight(_ c: CGContext) {
        c.setLineWidth(3.2)
        line(c, 3.5, 7, 20.5, 7)
        c.setLineWidth(1.9)
        line(c, 3.5, 12, 20.5, 12)
        c.setLineWidth(1.0)
        line(c, 3.5, 17, 20.5, 17)
    }

    private func ruler(_ c: CGContext) {
        // Dimension *style*, not a ruler: a block of dimension text over the
        // dimension line it is attached to. A ruler glyph said "measure this
        // drawing", which is the annotation tool, not the style of it.
        line(c, 3.5, 4.5, 14, 4.5)
        line(c, 3.5, 9, 20.5, 9)
        line(c, 3.5, 13.5, 10.5, 13.5)
        line(c, 3.5, 16.5, 3.5, 21)
        line(c, 20.5, 16.5, 20.5, 21)
        line(c, 3.5, 18.8, 20.5, 18.8)
        tick(c, 3.5, 18.8, size: 2.2)
        tick(c, 20.5, 18.8, size: 2.2)
    }

    private func chevron(_ c: CGContext) {
        c.move(to: CGPoint(x: 8, y: 10))
        c.addLine(to: CGPoint(x: 12, y: 14))
        c.addLine(to: CGPoint(x: 16, y: 10))
        c.strokePath()
    }
}

extension MeasureKind {
    var glyph: CADGlyph {
        switch self {
        case .aligned: return .aligned
        case .linear: return .linear
        case .continuous: return .continuous
        case .batch: return .batch
        case .rectangle: return .rectangle
        case .polygon: return .polygon
        case .circleArea: return .circleArea
        case .hatchArea: return .hatchArea
        case .sideArea: return .sideArea
        case .radius: return .radius
        case .angle: return .angle
        case .arcLength: return .arcLength
        case .note: return .note
        }
    }
}
