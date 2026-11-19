import AppKit

/// 打印设置。按制图的标准做法收集：纸张、方向、比例、着色、内容范围。
///
/// 关键是"比例"这一项。看图软件的习惯是"铺满纸张"，而图纸的习惯是
/// "1:100"——同一份文件在 A3 和 A4 上打出来，量出来的尺寸必须一致，否则
/// 拿尺子在纸上复核就没有意义。所以这里默认给固定比例，`适合纸张` 只是
/// 一个可选项。
struct PrintSetup {

    enum Paper: String, CaseIterable {
        case a4, a3, a2, a1, a0

        var title: String { rawValue.uppercased() }

        /// 毫米，纵向。
        var sizeMM: CGSize {
            switch self {
            case .a4: return CGSize(width: 210, height: 297)
            case .a3: return CGSize(width: 297, height: 420)
            case .a2: return CGSize(width: 420, height: 594)
            case .a1: return CGSize(width: 594, height: 841)
            case .a0: return CGSize(width: 841, height: 1189)
            }
        }
    }

    enum Orientation: String, CaseIterable {
        case auto, portrait, landscape

        var title: String {
            switch self {
            case .auto: return "自动"
            case .portrait: return "纵向"
            case .landscape: return "横向"
            }
        }
    }

    enum Ink: String, CaseIterable {
        case mono, gray, color

        var title: String {
            switch self {
            case .mono: return "黑白"
            case .gray: return "灰度"
            case .color: return "彩色"
            }
        }
    }

    enum Content: String, CaseIterable {
        case view, extents

        var title: String {
            switch self {
            case .view: return "当前视图"
            case .extents: return "整张图纸"
            }
        }
    }

    var paper: Paper = .a3
    var orientation: Orientation = .auto
    /// 0 表示"适合纸张"；否则是 1:N 里的 N。
    var scaleDenominator: Int = 100
    var ink: Ink = .mono
    var content: Content = .view
    var showLineweights = true
    /// 一个图纸单位等于多少毫米。DXF 的 $INSUNITS 五花八门（米、毫米、
    /// 英寸都有），不把它算进来，"1:100" 打出来的就是一张错的纸——米制图上
    /// 会小成一条线。由画布在打开打印面板时填入。
    var unitMillimetres: CGFloat = 1

    static let scaleChoices: [Int] = [0, 1, 2, 5, 10, 20, 30, 50, 100, 150, 200, 500, 1000]

    /// 按内容尺寸挑一张最合适的纸：容得下就用最小的那张，容不下给 A0。
    /// 按图框打印时用它，A1 图框不用手动去选纸。
    static func paperFitting(contentMM: CGSize) -> Paper {
        let width = max(contentMM.width, contentMM.height)
        let height = min(contentMM.width, contentMM.height)
        for paper in [Paper.a4, .a3, .a2, .a1, .a0] {
            let mm = paper.sizeMM
            if width <= max(mm.width, mm.height) + 1
                && height <= min(mm.width, mm.height) + 1 {
                return paper
            }
        }
        return .a0
    }

    var scaleTitle: String {
        scaleDenominator == 1 ? "1:1" : "1:\(scaleDenominator)"
    }

    /// 纸张在屏幕上的点尺寸（72 dpi 的 1:1 对应关系）。
    static let pointsPerMillimetre: CGFloat = 72.0 / 25.4

    func paperSizePoints(content worldRect: CGRect) -> CGSize {
        let mm = paper.sizeMM
        let shouldRotate: Bool
        switch orientation {
        case .portrait: shouldRotate = false
        case .landscape: shouldRotate = true
        case .auto:
            // 跟着图走：宽大于高就横过来，否则竖着。
            let wide = worldRect.width > worldRect.height
            let tallPage = mm.height > mm.width
            shouldRotate = wide != !tallPage
        }
        let size = shouldRotate ? CGSize(width: mm.height, height: mm.width) : mm
        return CGSize(width: size.width * Self.pointsPerMillimetre,
                      height: size.height * Self.pointsPerMillimetre)
    }

    /// 世界单位到纸上点数的换算。
    ///
    /// 固定比例时是 `图纸单位 → mm → 比例 → 点`；适合纸张时才去比窗口。前者
    /// 与窗口大小无关，同一份图纸在哪台机器上打都是一样大——这正是图纸要的。
    func pointsPerWorldUnit(fitting worldRect: CGRect, in printable: CGSize) -> CGFloat {
        if scaleDenominator > 0 {
            return unitMillimetres / CGFloat(scaleDenominator)
                * Self.pointsPerMillimetre
        }
        guard worldRect.width > 0, worldRect.height > 0 else { return 1 }
        return min(printable.width / worldRect.width,
                   printable.height / worldRect.height)
    }

    /// 写入一个 `NSPrintInfo`，让系统打印面板的纸张也与设置一致。
    func apply(to info: NSPrintInfo, worldRect: CGRect) {
        let size = paperSizePoints(content: worldRect)
        info.paperSize = size
        info.orientation = size.width > size.height ? .landscape : .portrait
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        // 10mm 安全边距：多数打印机到不了纸边，留小了会被裁掉。
        let margin = 10 * Self.pointsPerMillimetre
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
    }
}

enum PrintRenderer {

    /// 把一页渲染成位图。屏幕预览与真正的打印走同一条管线，比例才不会
    /// 出现"预览是这样、打出来是那样"。
    static func image(setup: PrintSetup, canvas: CanvasView, space: Int32 = 0,
                      worldRect: CGRect, paperSize: CGSize,
                      pixelsPerPoint: CGFloat) -> CGImage? {
        let width = Int(paperSize.width * pixelsPerPoint)
        let height = Int(paperSize.height * pixelsPerPoint)
        guard width > 8, height > 8,
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ??
                                      CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: pixelsPerPoint, y: pixelsPerPoint)
        _ = draw(ctx: ctx, setup: setup, canvas: canvas, space: space,
                 worldRect: worldRect, paperSize: paperSize)
        return ctx.makeImage()
    }

    /// 画一页到给定上下文（PDF、打印机、屏幕预览共用）。返回内容实际占的矩形。
    @discardableResult
    static func draw(ctx: CGContext, setup: PrintSetup, canvas: CanvasView, space: Int32,
                     worldRect: CGRect, paperSize: CGSize) -> CGRect? {
        guard let document = canvas.document else { return nil }
        let margin = 10 * PrintSetup.pointsPerMillimetre
        let printable = CGRect(x: margin, y: margin,
                               width: paperSize.width - margin * 2,
                               height: paperSize.height - margin * 2)
        let perUnit = setup.pointsPerWorldUnit(fitting: worldRect, in: printable.size)
        let contentWidth = worldRect.width * perUnit
        let contentHeight = worldRect.height * perUnit
        let scale = min(1, min(printable.width / max(contentWidth, 1e-6),
                               printable.height / max(contentHeight, 1e-6)))
        let target = CGRect(x: printable.midX - contentWidth * scale / 2,
                            y: printable.midY - contentHeight * scale / 2,
                            width: contentWidth * scale,
                            height: contentHeight * scale)
        document.withDisplaySpace(space) {
            Theme.PrintAppearance.with(monochrome: setup.ink == .mono,
                                       grayscale: setup.ink == .gray) {
                canvas.drawWorld(in: ctx, worldRect: worldRect, to: target,
                                 pointsPerWorldUnit: perUnit * scale,
                                 showLineweights: setup.showLineweights,
                                 space: space)
            }
        }
        return target
    }

    /// 打印标尺：纸张边缘的毫米刻度，便于在纸上核对尺寸。
    static func drawRuler(ctx: CGContext, paper: CGRect, content: CGRect) {
        let perMM = PrintSetup.pointsPerMillimetre
        ctx.saveGState()
        ctx.setStrokeColor(NSColor(white: 0.45, alpha: 0.55).cgColor)
        ctx.setFillColor(NSColor(white: 0.35, alpha: 0.75).cgColor)
        ctx.setLineWidth(0.4)
        let top = paper.maxY - 6
        let left = paper.minX + 6
        var mm = 0
        while CGFloat(mm) * perMM < paper.width - 6 {
            let x = paper.minX + CGFloat(mm) * perMM
            let length: CGFloat = mm % 10 == 0 ? 6 : 3
            ctx.move(to: CGPoint(x: x, y: top))
            ctx.addLine(to: CGPoint(x: x, y: top - length))
            mm += 5
        }
        ctx.strokePath()
        mm = 0
        while CGFloat(mm) * perMM < paper.height - 6 {
            let y = paper.minY + CGFloat(mm) * perMM
            let length: CGFloat = mm % 10 == 0 ? 6 : 3
            ctx.move(to: CGPoint(x: left, y: y))
            ctx.addLine(to: CGPoint(x: left + length, y: y))
            mm += 5
        }
        ctx.strokePath()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 5, weight: .regular),
            .foregroundColor: NSColor(white: 0.35, alpha: 0.85),
        ]
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        ("\(Int(paper.width / perMM))mm" as NSString)
            .draw(at: CGPoint(x: paper.minX + 8, y: paper.minY + 8), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }
}
