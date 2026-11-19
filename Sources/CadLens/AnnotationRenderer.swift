import AppKit

// MARK: - Style model

/// Dimension terminators. Six is the whole vocabulary a Chinese drawing office
/// actually uses: filled arrow (机械/通用), 45° tick (建筑 GB/T 50001),
/// narrow arrow (ISO-25), open arrow (工程), dot (小数/总图), end bar (紧凑).
enum AnnotationMarker: String, CaseIterable {
    case filledArrow, architecturalTick, narrowArrow, openArrow, dot, endBar

    var title: String {
        switch self {
        case .filledArrow: return "实心箭头"
        case .architecturalTick: return "建筑斜线"
        case .narrowArrow: return "窄箭头"
        case .openArrow: return "开口箭头"
        case .dot: return "圆点"
        case .endBar: return "端线"
        }
    }

    /// 设置面板只有两档：箭头类、斜线类。端线/圆点这些冷门端符仍然由标注
    /// 样式带出来，不给它们单独的开关。
    var usesTickGlyph: Bool {
        switch self {
        case .architecturalTick, .endBar: return true
        case .filledArrow, .narrowArrow, .openArrow, .dot: return false
        }
    }
}

struct AnnotationMetrics {
    var textSize: CGFloat = 11.5
    var arrowSize: CGFloat = 7.5
    var lineWidth: CGFloat = 1.2
    var extensionOffset: CGFloat = 4.0
    var extensionOverrun: CGFloat = 10.0
    var textGap: CGFloat = 9.0
    var marker: AnnotationMarker = .architecturalTick
    /// GB 建筑图把数字注在尺寸线上方；机械/ISO 允许压在线的中断处。
    /// 这个开关只影响线性尺寸，半径/角度/弧长各有自己的文字规则。
    var textAboveLine = false
}

/// A named dimension style. The numbers follow the reference implementation's
/// `annotationStyleMetrics()` so a drawing annotated in either app measures
/// and reads the same.
enum AnnotationStyle: String, CaseIterable, Codable {
    case architectural, standard, mechanical, engineering, decimal, compact

    var title: String {
        switch self {
        case .architectural: return "建筑（45° 斜线）"
        case .standard: return "标准（实心箭头）"
        case .mechanical: return "机械 ISO-25"
        case .engineering: return "工程（开口箭头）"
        case .decimal: return "小数（圆点）"
        case .compact: return "紧凑（端线）"
        }
    }

    var shortTitle: String {
        switch self {
        case .architectural: return "建筑"
        case .standard: return "标准"
        case .mechanical: return "机械"
        case .engineering: return "工程"
        case .decimal: return "小数"
        case .compact: return "紧凑"
        }
    }

    var metrics: AnnotationMetrics {
        switch self {
        // 线宽统一压到 1.0~1.3：尺寸线、界线、斜线在 Retina 上已经有 2 个像素，
        // 再粗就和图上的墙线抢注意力了。
        case .architectural:
            // 以 H 为基准的国标比例：斜线约 0.76H（3.5mm 字高下 2.7mm），
            // 界线起点 0.6H（2.1mm），超出 0.7H（2.45mm）。原先 4.8/11
            // 的界线让数字和端符都贴到墙线上，读图时和墙线混在一起。
            return AnnotationMetrics(textSize: 11.5, arrowSize: 5.6, lineWidth: 0.9,
                                     extensionOffset: 6.9, extensionOverrun: 8.0,
                                     textGap: 9.0, marker: .architecturalTick,
                                     textAboveLine: true)
        case .standard:
            return AnnotationMetrics(textSize: 11.5, arrowSize: 7.0, lineWidth: 1.2,
                                     extensionOffset: 3.2, extensionOverrun: 9.0,
                                     textGap: 8.0, marker: .filledArrow)
        case .mechanical:
            return AnnotationMetrics(textSize: 11.5, arrowSize: 4.8, lineWidth: 1.1,
                                     extensionOffset: 3.0, extensionOverrun: 9.0,
                                     textGap: 8.5, marker: .narrowArrow)
        case .engineering:
            return AnnotationMetrics(textSize: 11.5, arrowSize: 7.0, lineWidth: 1.3,
                                     extensionOffset: 4.5, extensionOverrun: 12.0,
                                     textGap: 10.0, marker: .openArrow)
        case .decimal:
            return AnnotationMetrics(textSize: 11.5, arrowSize: 5.6, lineWidth: 1.2,
                                     extensionOffset: 3.8, extensionOverrun: 9.5,
                                     textGap: 9.0, marker: .dot)
        case .compact:
            return AnnotationMetrics(textSize: 10.5, arrowSize: 5.2, lineWidth: 1.0,
                                     extensionOffset: 2.5, extensionOverrun: 7.5,
                                     textGap: 7.0, marker: .endBar)
        }
    }
}

// MARK: - Renderer

/// Draws measurements the way a drafting application draws a dimension: witness
/// lines that stop short of the geometry and overrun the dimension line, a thin
/// dimension line, a standard terminator at each end and the value set **on**
/// the dimension line with the line broken around it.
///
/// The previous renderer wrapped every value in a rounded translucent chip with
/// white text. That is an annotation-pin idiom from document review tools; on a
/// construction sheet it covers the geometry the user is measuring and it makes
/// the annotation look like a comment instead of a dimension.
enum AnnotationRenderer {

    /// Global style, pushed from the settings panel / toolbar.
    static var style: AnnotationStyle = .architectural
    /// When true the annotation scales with the drawing like a real DIMENSION
    /// entity; when false it keeps a constant screen size, which is what a
    /// viewer needs at 0.1× and at 40× alike.
    static var scalesWithDrawing = false

    /// Colour of new dimension ink. `nil` keeps the drawing-office green.
    /// Stored as hex in the settings so a lighter colour can be chosen for a
    /// dark sheet without changing the style.
    static var inkOverride: NSColor?

    /// World height of the sheet's own dimension text, measured once per space.
    /// 图纸自己的尺寸数字在世界坐标里的高度（纸空间是"模型字高 × 视口比例"
    /// 后的纸面高度）。画标注时按当前缩放换算成屏幕点数——图纸放多大，我们
    /// 的数字就多大，和图上原有尺寸永远同一个字号。
    static var sheetTextHeight: CGFloat = 0

    /// 整张图适配窗口时的缩放。历史遗留：标注字号曾经锁在这个比例上以保持
    /// 固定屏幕大小，现在改为跟随图纸字高（见 `sheetTextHeight`），这个值
    /// 只留给打印/侧栏显示用。
    static var fitScale: CGFloat = 0

    /// 端符单独覆盖：标注样式（字高、线宽、界线）仍然按 建筑/标准/机械 走，
    /// 但两端用箭头还是 45° 短斜线，让用户自己定。`nil` 时跟样式默认。
    static var markerOverride: AnnotationMarker?

    private static var metrics: AnnotationMetrics {
        var m = style.metrics
        if let markerOverride { m.marker = markerOverride }
        return m
    }

    private static var ink: NSColor { inkOverride ?? Theme.measurementStroke }

    /// 正在画的那一根线用哪支笔。
    ///
    /// 测量过程中的橡皮筋、落点小圆点必须和成图同色：先画蓝线、松手才变成
    /// 设定的颜色，会让人以为颜色设置没生效。选中态另算（那是"当前选中"，
    /// 该用强调色）。
    static var currentInk: NSColor { ink }
    /// 正在画的那一条标注的颜色。尺寸线走 ctx 的颜色，文字却是单独一次绘制，
    /// 不接这个值就会出现"线跟了新颜色、数字还是旧颜色"。
    private static var activeInk: NSColor?
    private static var fill: NSColor {
        ink.withAlphaComponent(Theme.isDark ? 0.085 : 0.075)
    }

    // MARK: Entry point

    static func draw(_ annotation: Annotation, in ctx: CGContext,
                     transform: ViewTransform, document: CadDocument,
                     selected: Bool, badge: Int? = nil,
                     hoverTint: NSColor? = nil) {
        guard !annotation.hidden else { return }
        let world = annotation.points
        let view = world.map { transform.toView($0) }
        guard !view.isEmpty else { return }

        let color = annotation.colorHex.flatMap(NSColor.init(hex:)) ?? ink
        var m = metrics
        // 屏幕显示和出图是两套诉求：
        // - 设置里“跟随图纸缩放”打开，或正在打印/导出：字号对齐图纸自己的
        //   尺寸数字（世界字高 × 当前/出图比例），纸上和原标注同大；
        // - 默认关闭：保持屏幕常数大小。看图软件在整张 A1 的 fit 视图下，
        //   3.5mm 的纸上字只剩几个像素，不放大根本读不出测量值——这对
        //   “看图量尺寸”比“和原图逐像素一致”更重要。
        let nominalTextSize = m.textSize
        // 布局是“一张纸”：标注字高必须和纸上原有尺寸文字一致，不能因为
        // 屏幕缩放比它小/大。模型空间才按用户设置决定是否跟随图纸。
        let paperFaithful = annotation.space > 0 || scalesWithDrawing
            || Theme.PrintAppearance.isPrinting
        // CadFont.fitted 的 size 是“字冠高”；旧实现直接拿 NSFont 的 em 当
        // 字高，屏幕上实际只有约 0.72 倍。屏幕常数模式乘 0.8，保持和旧版
        // 接近的视觉大小，不再让模型视图里的数字突然变大一圈。
        let screenTextSize = nominalTextSize * 0.8
        if paperFaithful, sheetTextHeight > 0 {
            m.textSize = min(max(sheetTextHeight * transform.scale, 4), 160)
        } else {
            m.textSize = screenTextSize
                * (paperFaithful ? geometryScale(transform: transform) : 1)
        }
        // 斜线、界线、字间距都跟着字号走：数字缩到 3pt 而斜线还是 8pt 的话，
        // 标注看起来像一堆散落的短线。
        let ratio = m.textSize / nominalTextSize
        m.arrowSize *= ratio
        m.lineWidth = max(0.85, m.lineWidth * min(ratio, 2.2))
        m.extensionOffset *= ratio
        m.extensionOverrun *= ratio
        m.textGap *= ratio

        // 悬停时用悬停色画整条标注：只是"我能点你"，不改标注自己的颜色设置。
        let active = selected ? Theme.selection : (hoverTint ?? color)
        activeInk = active
        ctx.saveGState()
        ctx.setStrokeColor(active.cgColor)
        ctx.setFillColor(active.cgColor)
        ctx.setLineWidth(max(0.9, m.lineWidth * (selected ? 1.35 : 1)))
        ctx.setLineJoin(.miter)
        ctx.setLineCap(.butt)

        switch annotation.kind {
        case .aligned:
            drawAligned(annotation, view, m, ctx)
        case .sideArea:
            // 侧面积 = 每段墙长压在测量线上 + 面积单独引线出去。长度和面积
            // 是两个量，挤在同一行文字里（长 × 高 = 面积）谁都读不顺。
            drawContinuous(annotation, world, view, m, ctx, document, transform)
        case .batch:
            drawAligned(annotation, view, m, ctx)
        case .linear:
            drawLinear(annotation, view, m, ctx)
        case .continuous:
            drawContinuous(annotation, world, view, m, ctx, document, transform)
        case .rectangle, .hatchArea:
            drawRectangle(annotation, view, m, ctx, document)
        case .polygon:
            drawPolygon(annotation, world, view, m, ctx, document, transform)
        case .circleArea, .radius:
            drawCircle(annotation, world, view, transform, m, ctx)
        case .angle:
            drawAngle(annotation, view, m, ctx)
        case .arcLength:
            drawArc(annotation, world, view, transform, m, ctx)
        case .note:
            drawNote(annotation, view, m, ctx)
        }
        ctx.restoreGState()
        activeInk = nil

        if let badge, let anchor = view.first {
            drawBadge(badge, at: CGPoint(x: anchor.x - 13, y: anchor.y + 13), ctx, color: color)
        }
    }

    /// 1.0 = the style's nominal pixel metrics. Zooming the sheet does not
    /// change it unless "跟随图纸" is on, in which case the annotation grows and
    /// shrinks with the drawing but never disappears or becomes billboard-sized.
    private static func geometryScale(transform: ViewTransform) -> CGFloat {
        guard scalesWithDrawing else { return 1 }
        return min(max(transform.scale / 0.6, 0.55), 2.6)
    }

    // MARK: Aligned

    /// 对齐标注按连续标注的画法：尺寸线就压在被量的那条线上，数值破在线的
    /// 中间，两端各一个 45° 斜线/箭头。没有默认的偏移和两根引出线——那条
    /// 线本来就画在墙上，再甩出去 16px 只是把图占满。
    ///
    /// 只有用户把标签拖开时才把整条尺寸线沿法向挪走，并补上引出线：那时候
    /// 偏移是用户的意图，不是默认样式。
    private static func drawAligned(_ a: Annotation, _ p: [CGPoint],
                                    _ m: AnnotationMetrics, _ ctx: CGContext) {
        guard p.count >= 2 else { return }
        let start = p[0], end = p[1]
        var dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return }
        dx /= length; dy /= length
        let nx = -dy, ny = dx

        // 沿线方向的分量对一条压在墙上的尺寸线没有意义，只取法向。
        let drag = a.labelOffset.x * nx + a.labelOffset.y * ny
        let offset = abs(drag) < 5 ? 0 : drag
        let a1 = CGPoint(x: start.x + nx * offset, y: start.y + ny * offset)
        let b1 = CGPoint(x: end.x + nx * offset, y: end.y + ny * offset)

        if offset != 0 {
            extensionLine(from: start, toward: a1, m, ctx)
            extensionLine(from: end, toward: b1, m, ctx)
        }
        segmentDimension(a1, b1, m, text: a.displayText, ctx,
                         arrowAtStart: true, arrowAtEnd: true, textScale: 1)
    }

    // MARK: Linear

    /// 线性标注：尺寸线沿水平/竖直方向横跨两个拾取点，位置取两点的中线——
    /// 和连续标注一样贴在被量的几何上，不做默认外偏。
    private static func drawLinear(_ a: Annotation, _ p: [CGPoint],
                                   _ m: AnnotationMetrics, _ ctx: CGContext) {
        guard p.count >= 2 else { return }
        let start = p[0], end = p[1]
        let horizontal = abs(end.x - start.x) >= abs(end.y - start.y)

        var a1 = start, b1 = end
        if horizontal {
            let y = (start.y + end.y) / 2 + a.labelOffset.y
            a1 = CGPoint(x: start.x, y: y)
            b1 = CGPoint(x: end.x, y: y)
        } else {
            let x = (start.x + end.x) / 2 + a.labelOffset.x
            a1 = CGPoint(x: x, y: start.y)
            b1 = CGPoint(x: x, y: end.y)
        }
        // 两个点在同一条水平/竖直线上时，尺寸线本身就是那段几何——再画引出
        // 线只是两根零长度的毛刺；只有把标签拖开（线离开了几何）才补引出线。
        if abs(a.labelOffset.x) + abs(a.labelOffset.y) > 5 {
            extensionLine(from: start, toward: a1, m, ctx)
            extensionLine(from: end, toward: b1, m, ctx)
        }
        segmentDimension(a1, b1, m, text: a.displayText, ctx,
                         arrowAtStart: true, arrowAtEnd: true, textScale: 1)
    }

    // MARK: Continuous

    private static func drawContinuous(_ a: Annotation, _ world: [CGPoint],
                                       _ p: [CGPoint], _ m: AnnotationMetrics,
                                       _ ctx: CGContext, _ document: CadDocument,
                                       _ transform: ViewTransform) {
        guard p.count >= 2 else { return }
        // 圆弧段：尺寸线本身就得跟着弧走，否则量的是弧长、画的却是弦——图上
        // 那根线和墙对不上，读图的人会以为量错了。
        if a.path.count > p.count {
            drawArcChain(a, world, p, m, ctx, document, transform)
            return
        }
        // A chain of chained dimensions: the polyline itself is the dimension
        // line, every node gets a terminator and the segment value sits on the
        // segment, broken into the line exactly like a single dimension.
        for index in 1..<p.count {
            let value = MeasurementMath.distance(world[index - 1], world[index])
            let label = document.formatLength(Double(value), precision: document.precision)
            // Only the first segment owns the start terminator: painting it at
            // both ends of every segment doubled it at each interior node, and
            // two opposed 45° ticks read as an X on the dimension line.
            segmentDimension(p[index - 1], p[index], m, text: label, ctx,
                             arrowAtStart: index == 1, arrowAtEnd: true)
        }
        let dot = nodeDotRadius(m)
        for point in p {
            ctx.fillEllipse(in: CGRect(x: point.x - dot, y: point.y - dot,
                                       width: dot * 2, height: dot * 2))
        }

        // Total length on a leader, placed on the least crowded side.
        let anchor = p[p.count / 2]
        let reach = max(12, 30 * m.textSize / 11.5)
        var bestDirection = CGPoint(x: 0, y: 1)
        var bestClearance: CGFloat = -1
        for k in 0..<8 {
            let angle = Double(k) * .pi / 4
            let normal = CGPoint(x: cos(angle), y: sin(angle))
            let probe = CGPoint(x: anchor.x + normal.x * reach, y: anchor.y + normal.y * reach)
            let foot = nearestPointOnPolyline(probe, p)
            let clearance = hypot(foot.x - probe.x, foot.y - probe.y)
            if clearance > bestClearance { bestClearance = clearance; bestDirection = normal }
        }
        let total = CGPoint(x: anchor.x + bestDirection.x * reach + a.labelOffset.x,
                            y: anchor.y + bestDirection.y * reach + a.labelOffset.y)
        let foot = nearestPointOnPolyline(total, p)
        if hypot(foot.x - total.x, foot.y - total.y) > 6 {
            ctx.saveGState()
            ctx.setLineWidth(max(0.8, m.lineWidth * 0.85))
            ctx.move(to: foot)
            ctx.addLine(to: total)
            ctx.strokePath()
            ctx.restoreGState()
            terminator(at: foot, toward: total, m, ctx)
        }
        text(a.displayText, at: total, angle: 0, size: m.textSize, ctx, halo: true)
    }

    /// 带圆弧的连续尺寸：尺寸线沿弧走，每段标它自己的真实长度（弧段是弧长）。
    private static func drawArcChain(_ a: Annotation, _ world: [CGPoint],
                                     _ p: [CGPoint], _ m: AnnotationMetrics,
                                     _ ctx: CGContext, _ document: CadDocument,
                                     _ transform: ViewTransform) {
        let outline = a.path.map { transform.toView($0) }
        guard outline.count >= 2 else { return }
        ctx.saveGState()
        ctx.setLineWidth(max(0.9, m.lineWidth))
        ctx.move(to: outline[0])
        for point in outline.dropFirst() { ctx.addLine(to: point) }
        ctx.strokePath()
        ctx.restoreGState()

        // 只有一段时，逐段数字和总长是同一个值，画两遍像是在图上重复标注。
        for index in 1..<max(p.count, 2) where p.count > 2 {
            let value = index - 1 < a.segmentLengths.count
                ? a.segmentLengths[index - 1]
                : Double(MeasurementMath.distance(world[index - 1], world[index]))
            let label = document.formatLength(value, precision: document.precision)
            var dx = p[index].x - p[index - 1].x
            var dy = p[index].y - p[index - 1].y
            let length = max(hypot(dx, dy), 0.001)
            dx /= length; dy /= length
            let mid = CGPoint(x: (p[index].x + p[index - 1].x) / 2,
                              y: (p[index].y + p[index - 1].y) / 2)
            let lift = m.textSize * 0.95
            text(label, at: CGPoint(x: mid.x - dy * lift, y: mid.y + dx * lift),
                 angle: 0, size: m.textSize, ctx, halo: true)
            let dot = nodeDotRadius(m)
            ctx.fillEllipse(in: CGRect(x: p[index].x - dot, y: p[index].y - dot,
                                       width: dot * 2, height: dot * 2))
        }
        let dot = nodeDotRadius(m)
        ctx.fillEllipse(in: CGRect(x: p[0].x - dot, y: p[0].y - dot,
                                   width: dot * 2, height: dot * 2))

        // 总长照旧挂在中间节点旁边——弧段一多，逐段数字会把整条线盖满。
        let anchor = p[p.count / 2]
        let total = CGPoint(x: anchor.x + a.labelOffset.x + m.textSize * 1.6,
                            y: anchor.y + a.labelOffset.y - m.textSize * 1.6)
        text(a.displayText, at: total, angle: 0, size: m.textSize, ctx, halo: true)
    }

    // MARK: Rectangle / polygon

    private static func drawRectangle(_ a: Annotation, _ p: [CGPoint],
                                      _ m: AnnotationMetrics, _ ctx: CGContext,
                                      _ document: CadDocument) {
        guard p.count >= 2 else { return }
        // Bounding box over every stored corner, not just the first two. A
        // rectangle is stored as its four corners, so p[0] and p[1] are two
        // *adjacent* corners: taking them as opposite corners collapsed the
        // region into a 20 pt band while the area value kept the full room
        // measurement, and the size callout then printed "1501 × 1177" onto a
        // line 245 pt wide.
        var minX = p[0].x, maxX = p[0].x, minY = p[0].y, maxY = p[0].y
        for point in p {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        ctx.saveGState()
        ctx.setFillColor(fill.cgColor)
        ctx.fill(rect)
        ctx.setLineWidth(max(0.9, m.lineWidth))
        // 实线：虚线在图上会和隐藏线、轴线混在一起，尺寸线必须是实线。
        ctx.stroke(rect)
        ctx.restoreGState()

        // 宽和高各标在各自的测量线上——这是图纸上一个矩形房间的标准标法。
        // 曾经把它们合成 "3600 × 4600" 一行压在顶边，那是产品规格的写法，
        // 不是尺寸标注：读者要自己判断哪个数是宽、哪个是高，而且它盖住了
        // 那条本该承载尺寸的线。面积单独放在区域中间。
        let width = a.secondaryValue > 0 ? a.secondaryValue
            : (a.points.count == 4 ? MeasurementMath.distance(a.points[0], a.points[1]) : 0)
        let height = a.points.count == 4
            ? MeasurementMath.distance(a.points[1], a.points[2]) : 0
        let offset = 32 * m.textSize / 11.5
        if width > 0 {
            let a1 = CGPoint(x: rect.minX, y: rect.minY - offset)
            let b1 = CGPoint(x: rect.maxX, y: rect.minY - offset)
            extensionLine(from: CGPoint(x: rect.minX, y: rect.minY), toward: a1, m, ctx)
            extensionLine(from: CGPoint(x: rect.maxX, y: rect.minY), toward: b1, m, ctx)
            dimensionLine(a1, b1, m, text: lengthLabel(width, document), ctx,
                          bothTerminals: true)
        }
        if height > 0 {
            let a1 = CGPoint(x: rect.maxX + offset, y: rect.minY)
            let b1 = CGPoint(x: rect.maxX + offset, y: rect.maxY)
            extensionLine(from: CGPoint(x: rect.maxX, y: rect.minY), toward: a1, m, ctx)
            extensionLine(from: CGPoint(x: rect.maxX, y: rect.maxY), toward: b1, m, ctx)
            dimensionLine(a1, b1, m, text: lengthLabel(height, document), ctx,
                          bothTerminals: true)
        }
        text(a.displayText, at: CGPoint(x: rect.midX + a.labelOffset.x,
                                        y: rect.midY + a.labelOffset.y),
             angle: 0, size: m.textSize, ctx, halo: true)
    }

    private static func lengthLabel(_ worldLength: CGFloat, _ document: CadDocument) -> String {
        document.formatLength(Double(worldLength), precision: document.precision)
    }

    private static func drawPolygon(_ a: Annotation, _ world: [CGPoint],
                                    _ p: [CGPoint], _ m: AnnotationMetrics,
                                    _ ctx: CGContext, _ document: CadDocument,
                                    _ transform: ViewTransform) {
        guard p.count >= 3 else { return }
        // 有圆弧边时按加密路径画轮廓：房间是弧形的，面积也得按弧形闭合。
        let outline = a.path.count > p.count ? a.path.map { transform.toView($0) } : p
        let path = CGMutablePath()
        path.move(to: outline[0])
        for point in outline.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        ctx.saveGState()
        ctx.setFillColor(fill.cgColor)
        ctx.addPath(path)
        ctx.fillPath(using: .evenOdd)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()

        var cx: CGFloat = 0, cy: CGFloat = 0
        for point in p { cx += point.x; cy += point.y }
        let rawCentroid = CGPoint(x: cx / CGFloat(p.count), y: cy / CGFloat(p.count))

        for index in p.indices {
            let next = (index + 1) % p.count
            let value = index < a.segmentLengths.count
                ? CGFloat(a.segmentLengths[index])
                : MeasurementMath.distance(world[index], world[next])
            // 回到起点收尾时最后一段长度是 0，标一个 "0mm" 出来只是噪声。
            guard value > 0.001 else { continue }
            let label = document.formatLength(Double(value), precision: document.precision)
            let mid = CGPoint(x: (p[index].x + p[next].x) / 2,
                              y: (p[index].y + p[next].y) / 2)
            let angle = atan2(p[next].y - p[index].y, p[next].x - p[index].x)
            // Push the edge value away from the centroid: using the edge normal
            // put half the labels inside the room, on top of the boundary.
            var nx = mid.x - rawCentroid.x, ny = mid.y - rawCentroid.y
            let normalLength = max(hypot(nx, ny), 0.001)
            nx /= normalLength; ny /= normalLength
            let offset = CGPoint(x: mid.x + nx * 13, y: mid.y + ny * 13)
            text(label, at: offset, angle: angle, size: m.textSize * 0.88, ctx, halo: true)
        }

        let centroid = CGPoint(x: rawCentroid.x + a.labelOffset.x,
                               y: rawCentroid.y + a.labelOffset.y)
        text(a.displayText, at: centroid, angle: 0, size: m.textSize, ctx, halo: true)
    }

    // MARK: Circle / radius

    private static func drawCircle(_ a: Annotation, _ world: [CGPoint], _ p: [CGPoint],
                                   _ transform: ViewTransform, _ m: AnnotationMetrics,
                                   _ ctx: CGContext) {
        guard p.count >= 2 else { return }
        let center = p[0]
        let radius = hypot(p[1].x - center.x, p[1].y - center.y)
        guard radius > 1 else { return }

        if a.kind == .radius {
            // R value on the radius line, line broken around the text, arrow at
            // the arc pointing outward.
            let angle = atan2(p[1].y - center.y, p[1].x - center.x)
            let edge = CGPoint(x: center.x + cos(angle) * radius,
                               y: center.y + sin(angle) * radius)
            ctx.saveGState()
            ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                         width: radius * 2, height: radius * 2))
            ctx.restoreGState()
            let dot = nodeDotRadius(m)
            ctx.fillEllipse(in: CGRect(x: center.x - dot, y: center.y - dot,
                                       width: dot * 2, height: dot * 2))

            let label = a.displayText
            if radius * 2 > textWidth(label, size: m.textSize) + m.textGap * 3 {
                let mid = CGPoint(x: (center.x + edge.x) / 2, y: (center.y + edge.y) / 2)
                let half = textWidth(label, size: m.textSize) / 2 + m.textGap
                let before = CGPoint(x: mid.x - cos(angle) * half, y: mid.y - sin(angle) * half)
                let after = CGPoint(x: mid.x + cos(angle) * half, y: mid.y + sin(angle) * half)
                ctx.move(to: center); ctx.addLine(to: before); ctx.strokePath()
                ctx.move(to: after); ctx.addLine(to: edge); ctx.strokePath()
                terminator(at: edge, toward: center, arrowMetrics(m), ctx)
                text(label, at: mid, angle: angle, size: m.textSize, ctx, halo: true)
            } else {
                ctx.move(to: center); ctx.addLine(to: edge); ctx.strokePath()
                terminator(at: edge, toward: center, arrowMetrics(m), ctx)
                let mid = CGPoint(x: (center.x + edge.x) / 2, y: (center.y + edge.y) / 2)
                let nx = -sin(angle), ny = cos(angle)
                let away = CGPoint(x: mid.x + nx * 22 + a.labelOffset.x,
                                   y: mid.y + ny * 22 + a.labelOffset.y)
                ctx.move(to: mid); ctx.addLine(to: away); ctx.strokePath()
                text(label, at: away, angle: 0, size: m.textSize, ctx, halo: true)
            }
            return
        }

        ctx.saveGState()
        ctx.setFillColor(fill.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                   width: radius * 2, height: radius * 2))
        ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                     width: radius * 2, height: radius * 2))
        ctx.restoreGState()
        // 圆心只留一个小十字。原来是 12pt 的圈加 18pt 的十字，而面积文字正好
        // 压在圆心，两样东西叠成一团——圆一小就完全糊掉。
        let arm: CGFloat = 4 * m.textSize / 11.5
        ctx.move(to: CGPoint(x: center.x - arm, y: center.y))
        ctx.addLine(to: CGPoint(x: center.x + arm, y: center.y))
        ctx.move(to: CGPoint(x: center.x, y: center.y - arm))
        ctx.addLine(to: CGPoint(x: center.x, y: center.y + arm))
        ctx.strokePath()

        // 面积值不再摆在圆心。参考项目 drawInlineDimension 的做法是沿一条半
        // 径线把数字破在线上；线短到放不下，就把数字挑到半径线的法向上方，
        // 用一小段引线连过去。两种都不跟圆心标记抢位置。
        let label = a.displayText
        guard !label.isEmpty else { return }
        let angle = atan2(p[1].y - center.y, p[1].x - center.x)
        let edge = CGPoint(x: center.x + cos(angle) * radius,
                           y: center.y + sin(angle) * radius)
        let middle = CGPoint(x: (center.x + edge.x) / 2,
                             y: (center.y + edge.y) / 2)
        let width = textWidth(label, size: m.textSize)
        let gap = m.textGap

        if a.labelOffset != .zero {
            // 用户拖过标签就照他放的画，圆心连一根细引线过去。
            let anchor = CGPoint(x: center.x + a.labelOffset.x,
                                 y: center.y + a.labelOffset.y)
            ctx.saveGState()
            ctx.setLineWidth(max(0.8, m.lineWidth * 0.8))
            ctx.move(to: center)
            ctx.addLine(to: anchor)
            ctx.strokePath()
            ctx.restoreGState()
            text(label, at: anchor, angle: 0, size: m.textSize, ctx, halo: true)
        } else if textLineCount(label) == 1, radius > width + gap * 2 + arm * 2 {
            // 只有一行字才沿半径线破字排布。两行（S 与 C）跟着半径线转 90°
            // 就变成两列侧躺的字，读的人得扭脖子——那种情况改走下面的法向
            // 抬升分支，横着排。
            // 线长是半径（圆心→圆周），不是直径：按直径判会放行明显超宽的
            // 数字，字的两头又会压回圆心十字上。
            let half = width / 2 + gap
            let before = CGPoint(x: middle.x - cos(angle) * half,
                                 y: middle.y - sin(angle) * half)
            let after = CGPoint(x: middle.x + cos(angle) * half,
                                y: middle.y + sin(angle) * half)
            if hypot(before.x - center.x, before.y - center.y) > 0.8 {
                ctx.move(to: center); ctx.addLine(to: before); ctx.strokePath()
            }
            if hypot(edge.x - after.x, edge.y - after.y) > 0.8 {
                ctx.move(to: after); ctx.addLine(to: edge); ctx.strokePath()
            }
            text(label, at: middle, angle: angle, size: m.textSize, ctx, halo: true)
        } else {
            ctx.move(to: center); ctx.addLine(to: edge); ctx.strokePath()
            var nx = -sin(angle), ny = cos(angle)
            if ny < 0 { nx = -nx; ny = -ny }
            let lines = textLineCount(label)
            let lift: CGFloat
            if lines > 1 {
                // 两行（S 与 C）横排。要让矩形字块整个落在半径线的一侧，法向
                // 偏移至少要等于字块在法向上的半宽——半径线竖直时就是半个字
                // 块宽，横排的字块高度再大也躲不开那根线。
                let blockHeight = m.textSize * 1.15 * lines
                lift = (abs(nx) * width + abs(ny) * blockHeight) / 2 + gap * 1.2
            } else {
                // 数字比半径长，就只能挑到线的法向上方。抬多少才不压住圆？锚点
                // 在半径线中点沿法向抬 L，文字下缘到圆心距离要大于半径：
                // √((r/2)² + (L - h/2)²) ≥ r，解出 L ≈ √(3/4)·r + h/2。
                let clear = max(radius * radius - (radius / 2) * (radius / 2), 0).squareRoot()
                lift = max(m.textSize * 1.55 + gap, clear + m.textSize * 0.75)
            }
            let anchor = CGPoint(x: middle.x + nx * lift, y: middle.y + ny * lift)
            let shoulder = CGPoint(x: anchor.x - nx * (m.textSize * 0.72),
                                   y: anchor.y - ny * (m.textSize * 0.72))
            ctx.saveGState()
            ctx.setLineWidth(max(0.8, m.lineWidth * 0.8))
            ctx.move(to: middle); ctx.addLine(to: shoulder); ctx.strokePath()
            ctx.restoreGState()
            text(label, at: anchor, angle: 0, size: m.textSize, ctx, halo: true)
        }
    }

    // MARK: Angle

    private static func drawAngle(_ a: Annotation, _ p: [CGPoint],
                                  _ m: AnnotationMetrics, _ ctx: CGContext) {
        guard p.count >= 3 else { return }
        let first = p[0], vertex = p[1], second = p[2]
        ctx.move(to: vertex); ctx.addLine(to: first); ctx.strokePath()
        ctx.move(to: vertex); ctx.addLine(to: second); ctx.strokePath()

        let startAngle = atan2(first.y - vertex.y, first.x - vertex.x)
        let endAngle = atan2(second.y - vertex.y, second.x - vertex.x)
        var sweep = endAngle - startAngle
        while sweep <= -.pi { sweep += 2 * .pi }
        while sweep > .pi { sweep -= 2 * .pi }
        let radius = max(min(hypot(first.x - vertex.x, first.y - vertex.y),
                             hypot(second.x - vertex.x, second.y - vertex.y)) * 0.62,
                         18 * m.textSize / 11.5)
        let arc = CGMutablePath()
        arc.addArc(center: vertex, radius: radius, startAngle: startAngle,
                   endAngle: startAngle + sweep, clockwise: sweep < 0)
        ctx.addPath(arc)
        ctx.strokePath()

        // GB 11.5.1：角度起止用箭头（位置不够才用圆点）。45° 斜线只属于
        // 线性尺寸，不能跟着建筑样式跑到角度圆弧上。
        let arrows = arrowMetrics(m)
        let startDir: CGPoint
        let endDir: CGPoint
        if sweep >= 0 {
            startDir = CGPoint(x: sin(startAngle), y: -cos(startAngle))
            endDir = CGPoint(x: -sin(endAngle), y: cos(endAngle))
        } else {
            startDir = CGPoint(x: -sin(startAngle), y: cos(startAngle))
            endDir = CGPoint(x: sin(endAngle), y: -cos(endAngle))
        }
        let startPoint = CGPoint(x: vertex.x + cos(startAngle) * radius,
                                 y: vertex.y + sin(startAngle) * radius)
        let endPoint = CGPoint(x: vertex.x + cos(endAngle) * radius,
                               y: vertex.y + sin(endAngle) * radius)
        terminator(at: startPoint,
                   toward: CGPoint(x: startPoint.x - startDir.x * 10,
                                   y: startPoint.y - startDir.y * 10), arrows, ctx)
        terminator(at: endPoint,
                   toward: CGPoint(x: endPoint.x - endDir.x * 10,
                                   y: endPoint.y - endDir.y * 10), arrows, ctx)

        let midAngle = startAngle + sweep / 2
        let tangent = sweep >= 0
            ? CGPoint(x: -sin(midAngle), y: cos(midAngle))
            : CGPoint(x: sin(midAngle), y: -cos(midAngle))
        let labelPoint = CGPoint(x: vertex.x + cos(midAngle) * (radius + 16 * m.textSize / 11.5)
                                    + a.labelOffset.x,
                                 y: vertex.y + sin(midAngle) * (radius + 16 * m.textSize / 11.5)
                                    + a.labelOffset.y)
        text(a.displayText, at: labelPoint,
             angle: atan2(tangent.y, tangent.x), size: m.textSize, ctx, halo: true)
    }

    // MARK: Arc length

    private static func drawArc(_ a: Annotation, _ world: [CGPoint], _ p: [CGPoint],
                                _ transform: ViewTransform, _ m: AnnotationMetrics,
                                _ ctx: CGContext) {
        guard world.count >= 3, p.count >= 3 else { return }
        guard let circle = MeasurementMath.circleThrough(world[0], world[1], world[2]) else {
            drawAligned(a, [p[0], p[2]], m, ctx)
            return
        }
        let center = transform.toView(circle.center)
        let radius = circle.radius * transform.scale
        let start = atan2(p[0].y - center.y, p[0].x - center.x)
        let mid = atan2(p[1].y - center.y, p[1].x - center.x)
        let end = atan2(p[2].y - center.y, p[2].x - center.x)
        var sweep = end - start
        while sweep <= 0 { sweep += 2 * .pi }
        var midSweep = mid - start
        while midSweep <= 0 { midSweep += 2 * .pi }
        if midSweep > sweep { sweep -= 2 * .pi }

        let path = CGMutablePath()
        path.addArc(center: center, radius: radius, startAngle: start,
                    endAngle: start + sweep, clockwise: sweep < 0)
        ctx.addPath(path)
        ctx.strokePath()
        let arcArrows = arrowMetrics(m)
        let endAngle = start + sweep
        let startDir: CGPoint
        let endDir: CGPoint
        if sweep >= 0 {
            startDir = CGPoint(x: sin(start), y: -cos(start))
            endDir = CGPoint(x: -sin(endAngle), y: cos(endAngle))
        } else {
            startDir = CGPoint(x: -sin(start), y: cos(start))
            endDir = CGPoint(x: sin(endAngle), y: -cos(endAngle))
        }
        let startPoint = CGPoint(x: center.x + cos(start) * radius,
                                 y: center.y + sin(start) * radius)
        let endPoint = CGPoint(x: center.x + cos(endAngle) * radius,
                               y: center.y + sin(endAngle) * radius)
        terminator(at: startPoint,
                   toward: CGPoint(x: startPoint.x - startDir.x * 10,
                                   y: startPoint.y - startDir.y * 10),
                   arcArrows, ctx)
        terminator(at: endPoint,
                   toward: CGPoint(x: endPoint.x - endDir.x * 10,
                                   y: endPoint.y - endDir.y * 10),
                   arcArrows, ctx)

        let labelAngle = start + sweep / 2
        let labelPoint = CGPoint(x: center.x + cos(labelAngle) * (radius + 14 * m.textSize / 11.5)
                                    + a.labelOffset.x,
                                 y: center.y + sin(labelAngle) * (radius + 14 * m.textSize / 11.5)
                                    + a.labelOffset.y)
        let tangent = sweep >= 0
            ? CGPoint(x: -sin(labelAngle), y: cos(labelAngle))
            : CGPoint(x: sin(labelAngle), y: -cos(labelAngle))
        text("⌒ " + a.displayText, at: labelPoint,
             angle: atan2(tangent.y, tangent.x), size: m.textSize, ctx, halo: true)
    }

    // MARK: Note

    private static func drawNote(_ a: Annotation, _ p: [CGPoint],
                                 _ m: AnnotationMetrics, _ ctx: CGContext) {
        guard let point = p.first else { return }
        let labelPoint = CGPoint(x: point.x + 18 + a.labelOffset.x,
                                 y: point.y + 22 + a.labelOffset.y)
        ctx.fillEllipse(in: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4))
        ctx.move(to: point)
        ctx.addLine(to: CGPoint(x: labelPoint.x - 4, y: labelPoint.y - 3))
        ctx.strokePath()
        text(a.displayText, at: labelPoint, angle: 0, size: m.textSize, ctx,
             halo: true, anchor: .left)
    }

    // MARK: Dimension primitives

    /// 文字应放在尺寸线的哪一侧：竖直尺寸强制左侧（字头朝左），其他方向
    /// 强制上方，和 GB 11.2.3 的方向规则一致。
    private static func textNormal(_ angle: CGFloat) -> CGPoint {
        var nx = -sin(angle), ny = cos(angle)
        if abs(nx) > abs(ny) {
            if nx > 0 { nx = -nx; ny = -ny }
        } else if ny < 0 {
            nx = -nx; ny = -ny
        }
        return CGPoint(x: nx, y: ny)
    }

    /// A dimension line with terminators and the value broken into it.
    private static func dimensionLine(_ a: CGPoint, _ b: CGPoint,
                                      _ m: AnnotationMetrics, text value: String,
                                      _ ctx: CGContext, bothTerminals: Bool) {
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 0.5 else { return }
        let angle = atan2(b.y - a.y, b.x - a.x)
        let width = textWidth(value, size: m.textSize)
        let gap = m.textGap
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)

        if m.textAboveLine {
            // 建筑图：尺寸线连续，数字在线上方中部（竖直时在线左侧）。
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            terminator(at: a, toward: b, m, ctx)
            if bothTerminals { terminator(at: b, toward: a, m, ctx) }
            let normal = textNormal(angle)
            let lift = m.textSize * (length > width + gap * 2 ? 0.85 : 1.15)
            text(value, at: CGPoint(x: mid.x + normal.x * lift,
                                    y: mid.y + normal.y * lift),
                 angle: angle, size: m.textSize, ctx, halo: true)
            return
        }

        if length > width + gap * 2 {
            // Standard case: the dimension line is broken around the value, the
            // way every CAD dimension sits on the sheet.
            let ux = (b.x - a.x) / length, uy = (b.y - a.y) / length
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let gapStart = CGPoint(x: mid.x - ux * (width / 2 + gap),
                                   y: mid.y - uy * (width / 2 + gap))
            let gapEnd = CGPoint(x: mid.x + ux * (width / 2 + gap),
                                 y: mid.y + uy * (width / 2 + gap))
            if hypot(gapStart.x - a.x, gapStart.y - a.y) > 1 {
                ctx.move(to: a); ctx.addLine(to: gapStart); ctx.strokePath()
            }
            if hypot(b.x - gapEnd.x, b.y - gapEnd.y) > 1 {
                ctx.move(to: gapEnd); ctx.addLine(to: b); ctx.strokePath()
            }
            terminator(at: a, toward: b, m, ctx)
            if bothTerminals { terminator(at: b, toward: a, m, ctx) }
            text(value, at: mid, angle: angle, size: m.textSize, ctx, halo: true)
        } else {
            // Too short to hold the value inline: draw it solid and lead the
            // value out on a shoulder, which is what ISO-25 calls an outside
            // dimension.
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            terminator(at: a, toward: b, m, ctx, outward: true)
            if bothTerminals { terminator(at: b, toward: a, m, ctx, outward: true) }
            let nx = -sin(angle), ny = cos(angle)
            var normal = CGPoint(x: nx, y: ny)
            if normal.y < 0 { normal = CGPoint(x: -nx, y: -ny) }
            let lead = CGPoint(x: b.x + normal.x * 14 + sign(cos(angle)) * 8,
                               y: b.y + normal.y * 14)
            ctx.setLineWidth(max(0.8, m.lineWidth * 0.8))
            ctx.move(to: b); ctx.addLine(to: lead); ctx.strokePath()
            ctx.setLineWidth(max(0.9, m.lineWidth))
            text(value, at: CGPoint(x: lead.x + sign(cos(angle)) * (width / 2 + 2),
                                    y: lead.y + normal.y * 8),
                 angle: angle, size: m.textSize, ctx, halo: true)
        }
    }

    private static func segmentDimension(_ a: CGPoint, _ b: CGPoint,
                                         _ m: AnnotationMetrics, text value: String,
                                         _ ctx: CGContext,
                                         arrowAtStart: Bool, arrowAtEnd: Bool,
                                         textScale: CGFloat = 0.9) {
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 0.5 else { return }
        let angle = atan2(b.y - a.y, b.x - a.x)
        let size = m.textSize * textScale
        let width = textWidth(value, size: size)
        let ux = (b.x - a.x) / length, uy = (b.y - a.y) / length
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)

        if m.textAboveLine {
            // 连续尺寸的每一段也按建筑排法：线不断，数字在线上方。
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            if arrowAtStart { terminator(at: a, toward: b, m, ctx) }
            if arrowAtEnd { terminator(at: b, toward: a, m, ctx) }
            let normal = textNormal(angle)
            let lift = size * (length > width + m.textGap * 2.2 ? 0.85 : 1.1)
            text(value, at: CGPoint(x: mid.x + normal.x * lift,
                                    y: mid.y + normal.y * lift),
                 angle: angle, size: size, ctx, halo: true)
            return
        }

        if length > width + m.textGap * 2.2 {
            let half = width / 2 + m.textGap
            let before = CGPoint(x: mid.x - ux * half, y: mid.y - uy * half)
            let after = CGPoint(x: mid.x + ux * half, y: mid.y + uy * half)
            if hypot(before.x - a.x, before.y - a.y) > 1 {
                ctx.move(to: a); ctx.addLine(to: before); ctx.strokePath()
            }
            if hypot(b.x - after.x, b.y - after.y) > 1 {
                ctx.move(to: after); ctx.addLine(to: b); ctx.strokePath()
            }
            text(value, at: mid, angle: angle, size: size, ctx, halo: true)
        } else {
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            text(value, at: CGPoint(x: mid.x, y: mid.y + size * 0.95),
                 angle: 0, size: size, ctx, halo: true)
        }
        if arrowAtStart { terminator(at: a, toward: b, m, ctx) }
        if arrowAtEnd { terminator(at: b, toward: a, m, ctx) }
    }

    /// Witness/extension line: starts a small gap away from the measured point
    /// and runs past the dimension line by the configured overrun.
    private static func extensionLine(from origin: CGPoint, toward target: CGPoint,
                                      _ m: AnnotationMetrics, _ ctx: CGContext) {
        let dx = target.x - origin.x, dy = target.y - origin.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }
        let ux = dx / length, uy = dy / length
        let startOffset = min(m.extensionOffset, length * 0.35)
        let start = CGPoint(x: origin.x + ux * startOffset, y: origin.y + uy * startOffset)
        let end = CGPoint(x: target.x + ux * m.extensionOverrun,
                          y: target.y + uy * m.extensionOverrun)
        ctx.saveGState()
        ctx.setLineWidth(max(0.8, m.lineWidth * 0.8))
        ctx.move(to: start)
        ctx.addLine(to: end)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// 半径/直径/角度/弧长的标准端符是箭头；建筑样式的 45° 斜线只用于
    /// 线性尺寸，不能通过全局 marker 传到这些类型上。
    private static func arrowMetrics(_ m: AnnotationMetrics) -> AnnotationMetrics {
        var arrows = m
        arrows.marker = .filledArrow
        // 建筑样式的线性端符是短斜线（arrowSize 5.6），但 GB 11.1.4 要求
        // 半径/角度/弧长用箭头；直接用 5.6 会小到看不出来。按 0.72H 取，
        // 3.5mm 字高下约 2.5mm。
        arrows.arrowSize = max(arrows.arrowSize, arrows.textSize * 0.72)
        return arrows
    }

    /// Draws one dimension terminator with its tip at `point`, pointing along
    /// `toward`. `outward == true` flips it through the point, which is what a
    /// very short dimension needs.
    private static func terminator(at point: CGPoint, toward reference: CGPoint,
                                   _ m: AnnotationMetrics, _ ctx: CGContext,
                                   outward: Bool = false) {
        var dx = point.x - reference.x, dy = point.y - reference.y
        let length = hypot(dx, dy)
        guard length > 0.001 else { return }
        dx /= length; dy /= length
        if outward { dx = -dx; dy = -dy }
        // 字缩到 3pt 时斜线不能还是 3pt 长，否则整条标注只剩四个撇。
        let size = max(1.4, m.arrowSize)

        switch m.marker {
        case .architecturalTick:
            // 45° to the dimension line, centred on it — GB/T 50001.
            let tx = (dx - dy) * size * 0.55, ty = (dx + dy) * size * 0.55
            ctx.move(to: CGPoint(x: point.x - tx, y: point.y - ty))
            ctx.addLine(to: CGPoint(x: point.x + tx, y: point.y + ty))
            ctx.strokePath()
        case .dot:
            let radius = max(1.2, size * 0.32)
            ctx.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius,
                                       width: radius * 2, height: radius * 2))
        case .endBar:
            let nx = -dy, ny = dx
            ctx.move(to: CGPoint(x: point.x - nx * size * 0.62, y: point.y - ny * size * 0.62))
            ctx.addLine(to: CGPoint(x: point.x + nx * size * 0.62, y: point.y + ny * size * 0.62))
            ctx.strokePath()
        case .openArrow:
            ctx.saveGState()
            ctx.setLineWidth(max(0.9, m.lineWidth))
            ctx.move(to: CGPoint(x: point.x - dx * size + (-dy) * size * 0.25,
                                 y: point.y - dy * size + dx * size * 0.25))
            ctx.addLine(to: point)
            ctx.addLine(to: CGPoint(x: point.x - dx * size - (-dy) * size * 0.25,
                                    y: point.y - dy * size - dx * size * 0.25))
            ctx.strokePath()
            ctx.restoreGState()
        case .filledArrow, .narrowArrow:
            // GB/ISO 的箭头长宽比约 3:1；原来的 0.34 让箭头接近等边三角形，
            // 看上去像楔子而不是尺寸箭头。
            let widthScale: CGFloat = m.marker == .narrowArrow ? 0.13 : 0.17
            let nx = -dy, ny = dx
            ctx.move(to: point)
            ctx.addLine(to: CGPoint(x: point.x - dx * size + nx * size * widthScale,
                                    y: point.y - dy * size + ny * size * widthScale))
            ctx.addLine(to: CGPoint(x: point.x - dx * size - nx * size * widthScale,
                                    y: point.y - dy * size - ny * size * widthScale))
            ctx.closePath()
            ctx.fillPath()
        }
    }

    // MARK: Text

    /// Value text, optionally with a background halo so it stays readable over
    /// dense line work — the drawn equivalent of a CAD text mask.
    private static func text(_ string: String, at point: CGPoint, angle: CGFloat,
                             size: CGFloat, _ ctx: CGContext, halo: Bool,
                             anchor: TextAnchor = .center) {
        guard !string.isEmpty else { return }
        let attributes = textAttributes(size: size, string: string,
                                        color: activeInk ?? ink, halo: halo)
        let attributed = NSAttributedString(string: string, attributes: attributes)
        let bounds = attributed.boundingRect(with: NSSize(width: 400, height: 600),
                                            options: [.usesLineFragmentOrigin])
        var rotation = angle
        while rotation > .pi / 2 { rotation -= .pi }
        while rotation < -.pi / 2 { rotation += .pi }
        // -90° 的竖直尺寸也统一成字头朝左，不随尺寸线方向翻转。
        if abs(rotation + .pi / 2) < 1e-6 { rotation = .pi / 2 }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ctx.saveGState()
        ctx.translateBy(x: point.x, y: point.y)
        ctx.rotate(by: rotation)
        let origin: CGPoint
        switch anchor {
        case .center:
            origin = CGPoint(x: -bounds.width / 2, y: -bounds.height / 2)
        case .left:
            origin = CGPoint(x: 0, y: -bounds.height / 2)
        }
        // "S = ..." 与 "C = ..." 是两行：用 draw(at:) 在定宽矩形里排版，
        // 段落样式负责居中和行距，两行才会整齐地叠在锚点上下。
        attributed.draw(with: CGRect(x: origin.x, y: origin.y,
                                     width: max(bounds.width, 1),
                                     height: max(bounds.height, 1)),
                        options: [.usesLineFragmentOrigin])
        ctx.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 标注文字用与图纸同一套 CAD 工程字体（gbenor/osifont + CJK），并按
    /// 字冠高归一化：CAD 的“字高”是可见字冠高，不是 em 大小。直接拿
    /// NSFont(pointSize: H) 画出来会矮约 25%，在布局里和原图尺寸文字对不齐。
    private static func annotationFont(size: CGFloat, string: String) -> NSFont {
        let probe = string.components(separatedBy: "\n")
            .max(by: { $0.count < $1.count }) ?? string
        return CadFont.fitted(size: size, text: probe)
    }

    private static func textAttributes(size: CGFloat, string: String, color: NSColor,
                                       halo: Bool) -> [NSAttributedString.Key: Any] {
        // Negative strokeWidth strokes *and* fills; the stroke colour is the
        // canvas colour, which gives the value a clean outline against the
        // drawing without drawing a filled plate behind it.
        // A negative strokeWidth fills *and* strokes, and the stroke is
        // centred on the glyph outline — at -14 the background-coloured stroke
        // ate most of the letterform and the dimension text read as grey mush.
        // -4 gives a 1 px halo at these sizes: enough to separate the value
        // from dense line work, not enough to close the counters.
        let font = annotationFont(size: size, string: string)
        let paragraph = NSMutableParagraphStyle()
        // 多行标注（面积 + 周长、备注）左对齐：居中的两行会把 "C = ..." 顶到
        // 左边、"S = ..." 缩在右边，读起来像两个不相干的数字。左对齐后两行
        // 的符号列在一条竖线上，一眼能分开。整块文字仍以锚点居中。
        paragraph.alignment = .left
        paragraph.lineSpacing = max(1, size * 0.12)
        if halo {
            return [.font: font,
                    .paragraphStyle: paragraph,
                    .foregroundColor: color,
                    .strokeColor: Theme.canvasBackground,
                    .strokeWidth: -2.0]
        }
        return [.font: font, .paragraphStyle: paragraph, .foregroundColor: color]
    }

    private enum TextAnchor { case center, left }

    /// 多行标注的宽度按最长那行算——"S = 1.23m² / C = 4.56m" 占的横向位置
    /// 由 S 那行决定，用整串宽度会把引线算得过长。
    private static func textWidth(_ string: String, size: CGFloat) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        var widest: CGFloat = 0
        for line in string.components(separatedBy: "\n") {
            let attributes: [NSAttributedString.Key: Any] =
                [.font: annotationFont(size: size, string: line)]
            widest = max(widest, (line as NSString).size(withAttributes: attributes).width)
        }
        return widest
    }

    /// 连续尺寸节点上的小圆点。跟着字号走，否则小字标注上是一排大黑点。
    private static func nodeDotRadius(_ m: AnnotationMetrics) -> CGFloat {
        max(0.9, 1.6 * m.textSize / 11.5)
    }

    private static func textLineCount(_ string: String) -> CGFloat {
        CGFloat(max(1, string.split(separator: "\n", omittingEmptySubsequences: false).count))
    }

    private static func sign(_ value: CGFloat) -> CGFloat { value < 0 ? -1 : 1 }

    // MARK: Badge

    /// Index pin tying the geometry to its row in the annotation panel. Quiet:
    /// a small ring with the number, not a filled pill over the drawing.
    private static func drawBadge(_ number: Int, at point: CGPoint,
                                  _ ctx: CGContext, color: NSColor) {
        let radius: CGFloat = 7.5
        let rect = CGRect(x: point.x - radius, y: point.y - radius,
                          width: radius * 2, height: radius * 2)
        ctx.saveGState()
        ctx.setFillColor(Theme.canvasBackground.withAlphaComponent(0.82).cgColor)
        ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(color.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: rect)
        ctx.restoreGState()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold),
            .foregroundColor: color,
        ]
        let string = "\(number)" as NSString
        let size = string.size(withAttributes: attributes)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        string.draw(at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2),
                    withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Live preview

    /// Live preview uses the same primitives as the finished dimension, so what
    /// is dragged into place on screen is exactly what gets committed.
    static func previewDistance(tool: MeasureKind, viewPoints: [CGPoint],
                               in ctx: CGContext) {
        guard viewPoints.count >= 2 else { return }
        let a = viewPoints[0], b = viewPoints[1]
        let m = metrics
        activeInk = nil
        ctx.saveGState()
        ctx.setStrokeColor(ink.withAlphaComponent(0.85).cgColor)
        ctx.setFillColor(ink.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(m.lineWidth)
        ctx.setLineCap(.butt)
        ctx.setLineJoin(.miter)
        switch tool {
        case .aligned, .batch:
            // 与成图完全同一种画法：尺寸线压在两点连线上，两端斜线，
            // 中间留出数字的位置（数字由跟随指针的读数牌显示）。
            let dx = b.x - a.x, dy = b.y - a.y
            let length = max(hypot(dx, dy), 1)
            let ux = dx / length, uy = dy / length
            let half = m.textGap * 1.6
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            if length > half * 2 + 4 {
                ctx.move(to: a)
                ctx.addLine(to: CGPoint(x: mid.x - ux * half, y: mid.y - uy * half))
                ctx.strokePath()
                ctx.move(to: CGPoint(x: mid.x + ux * half, y: mid.y + uy * half))
                ctx.addLine(to: b)
                ctx.strokePath()
            } else {
                ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            }
            terminator(at: a, toward: b, m, ctx)
            terminator(at: b, toward: a, m, ctx)
        case .linear:
            let horizontal = abs(b.x - a.x) >= abs(b.y - a.y)
            let a1: CGPoint, b1: CGPoint
            if horizontal {
                let y = (a.y + b.y) / 2
                a1 = CGPoint(x: a.x, y: y); b1 = CGPoint(x: b.x, y: y)
            } else {
                let x = (a.x + b.x) / 2
                a1 = CGPoint(x: x, y: a.y); b1 = CGPoint(x: x, y: b.y)
            }
            let length = max(hypot(b1.x - a1.x, b1.y - a1.y), 1)
            let ux = (b1.x - a1.x) / length, uy = (b1.y - a1.y) / length
            let half = m.textGap * 1.6
            let mid = CGPoint(x: (a1.x + b1.x) / 2, y: (a1.y + b1.y) / 2)
            if length > half * 2 + 4 {
                ctx.move(to: a1)
                ctx.addLine(to: CGPoint(x: mid.x - ux * half, y: mid.y - uy * half))
                ctx.strokePath()
                ctx.move(to: CGPoint(x: mid.x + ux * half, y: mid.y + uy * half))
                ctx.addLine(to: b1)
                ctx.strokePath()
            } else {
                ctx.move(to: a1); ctx.addLine(to: b1); ctx.strokePath()
            }
            terminator(at: a1, toward: b1, m, ctx)
            terminator(at: b1, toward: a1, m, ctx)
        default:
            let path = CGMutablePath()
            path.move(to: a)
            for point in viewPoints.dropFirst() { path.addLine(to: point) }
            ctx.saveGState()
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    /// Legacy chip, still used by the transient read-out that follows the
    /// pointer while a tool is armed. Kept deliberately plain: it is a cursor
    /// accessory, not an annotation.
    static func drawChip(_ text: String, at point: CGPoint, _ ctx: CGContext) {
        guard !text.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let rect = CGRect(x: point.x + 12, y: point.y + 10,
                          width: size.width + 12, height: size.height + 6).integral
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (text as NSString).draw(at: CGPoint(x: rect.minX + 6, y: rect.minY + 3),
                                withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Geometry helpers

    private static func nearestPointOnPolyline(_ p: CGPoint, _ points: [CGPoint]) -> CGPoint {
        guard points.count >= 2 else { return points.first ?? p }
        var best = points[0]
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let abx = b.x - a.x, aby = b.y - a.y
            let lengthSquared = abx * abx + aby * aby
            var t: CGFloat = lengthSquared > 1e-9
                ? ((p.x - a.x) * abx + (p.y - a.y) * aby) / lengthSquared : 0
            t = max(0, min(1, t))
            let candidate = CGPoint(x: a.x + abx * t, y: a.y + aby * t)
            let distance = hypot(candidate.x - p.x, candidate.y - p.y)
            if distance < bestDistance { bestDistance = distance; best = candidate }
        }
        return best
    }
}

extension NSColor {
    /// `#RRGGBB` for persistence. sRGB conversion first: a catalogue colour
    /// (system green, for instance) has no RGB components and would otherwise
    /// serialise as zeros.
    var hexString: String {
        guard let srgb = usingColorSpace(.sRGB) else { return "#37D67A" }
        return String(format: "#%02X%02X%02X",
                      Int((srgb.redComponent * 255).rounded()),
                      Int((srgb.greenComponent * 255).rounded()),
                      Int((srgb.blueComponent * 255).rounded()))
    }

    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }
}
