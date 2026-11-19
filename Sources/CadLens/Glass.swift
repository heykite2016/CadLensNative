import AppKit

// MARK: - 材质令牌

/// Liquid Glass 的材质：一层很薄的雾 + 一道亮边 + 一条顶部内高光。
///
/// 为什么不用 `NSVisualEffectView`：本应用的画布是 `CAMetalLayer`，窗口内的
/// 毛玻璃取的是窗口后备存储，取不到 Metal 表面——套上去只会得到一块灰色。
/// 玻璃的观感其实由三样东西决定（半透明填充、1pt 亮边、顶部高光），模糊只是
/// 让底下的线条更服帖；这三样都能直接画，而且不会随画布内容漂移。
///
/// 所有面板共用这一套数值，改一处全窗口一致。
enum Glass {

    // MARK: 圆角

    enum Radius {
        /// 主窗口的浮动面板。
        static let window: CGFloat = 22
        /// 工具岛、侧栏、命令行。
        static let panel: CGFloat = 18
        /// 卡片、分组。
        static let group: CGFloat = 14
        /// 按钮、输入井。
        static let control: CGFloat = 11
        /// 状态胶囊。
        static let pill: CGFloat = 9
    }

    static var isDark: Bool { Theme.isDark }

    // MARK: 填充

    /// 浮层的填充是**不透明**的：岛只在圆角之外透明，面内是实的。
    ///
    /// 这里原本是半透明白（深 15.5%→5.5%、浅 88%→64%），想让图纸从玻璃底下
    /// 透出来；实际是图元直接"浮"在面板上——侧栏清单里能看见图纸的 "9764"，
    /// 图标和数字糊在一起。读图比通透重要，玻璃的味道交给亮边、内高光和投影。
    static var fillTop: NSColor {
        isDark ? NSColor(srgbRed: 0.149, green: 0.165, blue: 0.196, alpha: 1)
               : NSColor(white: 1, alpha: 1)
    }

    static var fillBottom: NSColor {
        isDark ? NSColor(srgbRed: 0.106, green: 0.118, blue: 0.145, alpha: 1)
               : NSColor(srgbRed: 0.957, green: 0.961, blue: 0.969, alpha: 1)
    }

    /// 凹槽：输入井、分段控件的底。
    static var sunken: NSColor {
        isDark ? NSColor(white: 0, alpha: 0.22) : NSColor(white: 0, alpha: 0.055)
    }

    /// 亮边。浅色面板本身接近白，白边等于没有轮廓，改成一道极淡的灰线；
    /// 深色面板继续用白边当"玻璃的倒角高光"。
    static var border: NSColor {
        isDark ? NSColor(white: 1, alpha: 0.17) : NSColor(white: 0, alpha: 0.07)
    }

    static var innerHighlight: NSColor {
        isDark ? NSColor(white: 1, alpha: 0.40) : NSColor(white: 1, alpha: 0.95)
    }

    static var innerShade: NSColor {
        isDark ? NSColor(white: 0, alpha: 0.18) : NSColor(white: 0, alpha: 0.06)
    }

    /// 玻璃上的分隔线：比画布上的 hairline 亮一档，压在雾面才看得见。
    static var separator: NSColor {
        isDark ? NSColor(white: 1, alpha: 0.13) : NSColor(white: 0, alpha: 0.08)
    }

    static var hover: NSColor {
        isDark ? NSColor(white: 1, alpha: 0.11) : NSColor(white: 0, alpha: 0.055)
    }

    /// 选中态的实心蓝：固定的 #2F6BFF，而不是会随外观变浅的系统强调色。
    /// 深色下系统强调色是浅蓝，白字压上去几乎读不出来。
    static var accentFill: NSColor {
        NSColor(srgbRed: 0.184, green: 0.42, blue: 1.0, alpha: isDark ? 0.90 : 1.0)
    }

    static var shadowOpacity: Float { isDark ? 0.40 : 0.22 }

    static var shadowRadius: CGFloat { isDark ? 22 : 20 }

    // MARK: 文字

    /// 玻璃上的三档文字。外观已由 `Theme.canvasTone` 钉成深/浅两套系统颜色，
    /// 所以这里直接走 label 系列，不必再手写一套"玻璃专用白"。
    static var primaryText: NSColor { .labelColor }
    static var secondaryText: NSColor { .secondaryLabelColor }
    static var tertiaryText: NSColor { .tertiaryLabelColor }

    // MARK: 绘制

    enum Tone {
        case regular
        /// 凹槽：比周围沉一档，用来放输入框和分段控件。
        case sunken
        /// 选中：品牌蓝实心。
        case accent
    }

    /// 在一块矩形里画玻璃。
    ///
    /// - Parameters:
    ///   - flipped: 视图是否翻转坐标（自上而下）。内高光要画在"视觉上的上沿"，
    ///     翻转视图里那是 `minY`。
    static func draw(in rect: NSRect, radius: CGFloat,
                     tone: Tone = .regular, flipped: Bool = true,
                     context: CGContext? = nil) {
        guard let ctx = context ?? NSGraphicsContext.current?.cgContext else { return }
        let r = rect.insetBy(dx: 0.5, dy: 0.5)
        guard r.width > 2, r.height > 2 else { return }
        let corner = min(radius, min(r.width, r.height) / 2)
        let path = CGPath(roundedRect: r, cornerWidth: corner, cornerHeight: corner,
                          transform: nil)
        let topY = flipped ? r.minY : r.maxY
        let bottomY = flipped ? r.maxY : r.minY

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()

        switch tone {
        case .regular:
            gradient(ctx, from: fillTop, to: fillBottom,
                     start: CGPoint(x: r.midX, y: topY),
                     end: CGPoint(x: r.midX, y: bottomY))
            // 左上角一道斜光，模拟玻璃的厚度；没有它，面板只是一块纯色蒙版。
            sheen(ctx, rect: r, topY: topY)
        case .sunken:
            ctx.setFillColor(sunken.cgColor)
            ctx.fill(r)
            // 凹槽的阴影在上面：光从上面来，槽底靠上沿落影。
            gradient(ctx, from: NSColor(white: 0, alpha: isDark ? 0.18 : 0.05),
                     to: NSColor(white: 0, alpha: 0),
                     start: CGPoint(x: r.midX, y: topY),
                     end: CGPoint(x: r.midX, y: topY + r.height * 0.45))
        case .accent:
            gradient(ctx, from: accentFill,
                     to: NSColor(srgbRed: 0.13, green: 0.34, blue: 0.92,
                                 alpha: isDark ? 0.86 : 1.0),
                     start: CGPoint(x: r.midX, y: topY),
                     end: CGPoint(x: r.midX, y: bottomY))
            sheen(ctx, rect: r, topY: topY, strength: 0.22)
        }
        ctx.restoreGState()

        // 亮边：玻璃的轮廓靠这道边，不靠阴影。
        ctx.addPath(path)
        ctx.setStrokeColor(tone == .accent
            ? NSColor(white: 1, alpha: 0.34).cgColor
            : border.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()

        // 顶部内高光 + 底部内暗边，一上一下才有"一块玻璃"的厚度。
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 1, dy: 1),
                           cornerWidth: max(corner - 1, 2), cornerHeight: max(corner - 1, 2),
                           transform: nil))
        ctx.clip()
        ctx.setFillColor((tone == .accent
            ? NSColor(white: 1, alpha: 0.30) : innerHighlight).cgColor)
        ctx.fill(CGRect(x: r.minX + 1, y: topY, width: r.width - 2, height: 1))
        ctx.setFillColor((tone == .accent
            ? NSColor(white: 0, alpha: 0.10) : innerShade).cgColor)
        ctx.fill(CGRect(x: r.minX + 1, y: bottomY - 1, width: r.width - 2, height: 1))
        ctx.restoreGState()
    }

    private static func gradient(_ ctx: CGContext, from: NSColor, to: NSColor,
                                 start: CGPoint, end: CGPoint) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: space,
                                        colors: [from.cgColor, to.cgColor] as CFArray,
                                        locations: [0, 1]) else { return }
        ctx.drawLinearGradient(gradient, start: start, end: end,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func sheen(_ ctx: CGContext, rect: NSRect, topY: CGFloat,
                              strength: CGFloat = 0.14) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: space,
                                        colors: [NSColor(white: 1, alpha: strength).cgColor,
                                                 NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                                        locations: [0, 1]) else { return }
        let centre = CGPoint(x: rect.minX + rect.width * 0.14, y: topY)
        ctx.drawRadialGradient(gradient, startCenter: centre, startRadius: 0,
                               endCenter: centre, endRadius: max(rect.width * 0.85, 60),
                               options: [])
    }
}

// MARK: - 玻璃面板

/// 浮在画布上的界面层。
///
/// 画布是铺满整窗的，它的光标矩形也铺满整窗（十字或那个"隐形光标"）。所以
/// 任何压在上面的浮层都得自己声明"这里是箭头"，否则鼠标走到工具岛上还顶着
/// 十字光标——那是图纸上的取点光标，不是点按钮的光标。
///
/// 顺带把"鼠标进没进浮层"广播出去：自绘十字是画在画布上的全屏长线，不通知
/// 画布收起来，两条线会从玻璃底下穿过去。
class CADGlassSurface: NSView {

    /// 指针进入/离开这块玻璃。主窗口拿它去让画布收起十字。
    var onPointerInsideChanged: ((Bool) -> Void)?
    private var hoverTracking: NSTrackingArea?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .cursorUpdate,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.arrow.set()
        onPointerInsideChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onPointerInsideChanged?(false)
    }
}

/// 一块会自己画玻璃的容器：圆角、亮边、内高光、投影。
///
/// 用它替换原来的"不透明底色 + 材质层"：浮层必须让图纸透出来，否则窗口又被
/// 切回一条条实心横栏。
final class GlassPanel: CADGlassSurface, ThemeAware {

    var cornerRadius: CGFloat = Glass.Radius.panel {
        didSet { needsDisplay = true; needsLayout = true }
    }
    var tone: Glass.Tone = .regular {
        didSet { needsDisplay = true }
    }
    /// 浮在画布上的面板要投影；嵌在面板里的容器不投。
    var elevated: Bool = true {
        didSet { updateShadow() }
    }

    init(radius: CGFloat = Glass.Radius.panel,
         tone: Glass.Tone = .regular,
         elevated: Bool = true) {
        self.cornerRadius = radius
        self.tone = tone
        self.elevated = elevated
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = false
        updateShadow()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        Glass.draw(in: bounds, radius: cornerRadius, tone: tone, flipped: isFlipped)
    }

    override func layout() {
        super.layout()
        updateShadow()
    }

    private func updateShadow() {
        guard let layer else { return }
        if elevated {
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = Glass.shadowOpacity
            layer.shadowRadius = Glass.shadowRadius
            layer.shadowOffset = CGSize(width: 0, height: -8)
            layer.shadowPath = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                      cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                                      transform: nil)
        } else {
            layer.shadowOpacity = 0
            layer.shadowPath = nil
        }
    }

    func themeDidChange() {
        needsDisplay = true
        updateShadow()
    }
}

// MARK: - 红绿灯

/// 自绘的红绿灯。
///
/// 系统的三个按钮住在标题栏里，而标题栏在 `fullSizeContentView` 下仍会吞掉
/// 它那一条上的鼠标事件——玻璃工具岛的上半截会点不动。所以把系统按钮藏掉，
/// 自己在玻璃胶囊里画三个，位置、颜色、间距和系统一致，点击行为照旧。
final class TrafficLights: NSView {

    private let diameter: CGFloat = 11
    private let gap: CGFloat = 8
    private var hovering = false { didSet { needsDisplay = true } }
    private var hoveredIndex: Int? { didSet { needsDisplay = true } }
    private var optionsPopover: NSPopover?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter * 3 + gap * 2),
            heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var dotRects: [CGRect] {
        (0..<3).map { index in
            CGRect(x: CGFloat(index) * (diameter + gap),
                   y: (bounds.height - diameter) / 2,
                   width: diameter, height: diameter)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors: [NSColor] = [
            NSColor(srgbRed: 1.00, green: 0.37, blue: 0.34, alpha: 1),
            NSColor(srgbRed: 1.00, green: 0.74, blue: 0.18, alpha: 1),
            NSColor(srgbRed: 0.16, green: 0.78, blue: 0.25, alpha: 1),
        ]
        for (index, rect) in dotRects.enumerated() {
            let active = hovering && (hoveredIndex == nil || hoveredIndex == index)
            let fill = colors[index].withAlphaComponent(hovering ? 1 : 0.94)
            fill.setFill()
            NSBezierPath(ovalIn: rect).fill()
            if active {
                // 悬停时露符号：× / − / ＋，和系统按钮一致。
                let glyph = NSBezierPath()
                glyph.lineWidth = 1.1
                glyph.lineCapStyle = .round
                NSColor(white: 0, alpha: 0.55).setStroke()
                let inset: CGFloat = 3.4
                if index == 0 {
                    glyph.move(to: CGPoint(x: rect.minX + inset, y: rect.minY + inset))
                    glyph.line(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset))
                    glyph.move(to: CGPoint(x: rect.maxX - inset, y: rect.minY + inset))
                    glyph.line(to: CGPoint(x: rect.minX + inset, y: rect.maxY - inset))
                } else if index == 1 {
                    glyph.move(to: CGPoint(x: rect.minX + inset, y: rect.midY))
                    glyph.line(to: CGPoint(x: rect.maxX - inset, y: rect.midY))
                } else {
                    // 与系统绿灯一致：全屏图标是两条对角箭头，不是加号。
                    let centre = CGPoint(x: rect.midX, y: rect.midY)
                    let arm: CGFloat = 2.8
                    for sign in [-1.0, 1.0] as [CGFloat] {
                        let tip = CGPoint(x: centre.x + sign * arm,
                                          y: centre.y + sign * arm)
                        glyph.move(to: centre)
                        glyph.line(to: tip)
                        glyph.move(to: CGPoint(x: tip.x - sign * 1.7, y: tip.y))
                        glyph.line(to: tip)
                        glyph.line(to: CGPoint(x: tip.x, y: tip.y - sign * 1.7))
                    }
                }
                glyph.stroke()
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .mouseMoved,
                                                 .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        hoveredIndex = nil
        // 指针从绿灯移到弹出菜单上时，菜单不能立刻收起；给 0.25 s 让
        // 指针进入 popover，再判断一次。
        guard optionsPopover != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.pointerInsideOptions() else { return }
            self.closeOptions()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoveredIndex = dotRects.firstIndex { $0.insetBy(dx: -3, dy: -3).contains(point) }
        if hoveredIndex == 2 {
            if optionsPopover == nil { showOptions() }
        } else if optionsPopover != nil {
            closeOptions()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = dotRects.firstIndex(where: { $0.insetBy(dx: -3, dy: -3).contains(point) }),
              let window else { return }
        switch index {
        case 0: window.performClose(nil)
        case 1: window.performMiniaturize(nil)
        default:
            // 默认点击绿灯就是进入/退出全屏；左右停靠仍从悬停菜单选。
            // 不要因为悬停菜单已经弹出就把点击吞掉——用户点绿灯的预期
            // 始终是“切全屏”，不是“再开一次菜单”。
            closeOptions()
            window.toggleFullScreen(nil)
        }
    }

    // MARK: 绿灯菜单

    private func showOptions() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        closeOptions()
        let controller = TrafficOptionsViewController()
        controller.isFullScreen = window.styleMask.contains(.fullScreen)
        controller.onAction = { [weak self] action in
            guard let self, let window = self.window else { return }
            self.closeOptions()
            switch action {
            case .fullScreen:
                window.toggleFullScreen(nil)
            case .left:
                self.tile(window: window, on: screen, left: true)
            case .right:
                self.tile(window: window, on: screen, left: false)
            case .zoom:
                window.performZoom(nil)
            }
        }
        let popover = NSPopover()
        popover.contentViewController = controller
        _ = controller.view
        popover.contentSize = controller.preferredContentSize
        popover.behavior = .transient
        popover.animates = true
        popover.show(relativeTo: dotRects[2], of: self, preferredEdge: .maxY)
        optionsPopover = popover
    }

    private func closeOptions() {
        optionsPopover?.close()
        optionsPopover = nil
    }

    private func pointerInsideOptions() -> Bool {
        guard let window = optionsPopover?.contentViewController?.view.window else {
            return false
        }
        return window.frame.contains(NSEvent.mouseLocation)
    }

    private func tile(window: NSWindow, on screen: NSScreen, left: Bool) {
        let visible = screen.visibleFrame
        let half = floor(visible.width / 2)
        var frame = CGRect(x: left ? visible.minX : visible.maxX - half,
                           y: visible.minY,
                           width: half,
                           height: visible.height)
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                window.setFrame(frame, display: true, animate: true)
            }
        } else {
            frame = frame.integral
            window.setFrame(frame, display: true, animate: true)
        }
    }
}

/// 绿灯悬停菜单：进入/退出全屏、左右停靠、缩放。
final class TrafficOptionsViewController: NSViewController {
    enum Action: Int { case fullScreen, left, right, zoom }

    var isFullScreen = false
    var onAction: ((Action) -> Void)?

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "窗口")
        title.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(4, after: title)

        addRow(stack, action: .fullScreen,
               title: isFullScreen ? "退出全屏幕" : "进入全屏幕",
               symbol: "arrow.up.left.and.arrow.down.right")
        addRow(stack, action: .left, title: "向左停靠",
               symbol: "rectangle.lefthalf.inset.filled")
        addRow(stack, action: .right, title: "向右停靠",
               symbol: "rectangle.righthalf.inset.filled")
        stack.addArrangedSubview(NSBox.separator())
        addRow(stack, action: .zoom, title: "缩放", symbol: "arrow.up.left.and.arrow.down.right")

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 196),
            root.heightAnchor.constraint(equalToConstant: 154),
        ])
        view = root
        preferredContentSize = NSSize(width: 196, height: 154)
    }

    private func addRow(_ stack: NSStackView, action: Action,
                        title: String, symbol: String) {
        let button = NSButton(title: title, target: self, action: #selector(choose(_:)))
        button.tag = action.rawValue
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: 12.5)
        button.alignment = .left
        button.imagePosition = .imageLeading
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.contentTintColor = .labelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        button.widthAnchor.constraint(equalToConstant: 180).isActive = true
        stack.addArrangedSubview(button)
    }

    @objc private func choose(_ sender: NSButton) {
        guard let action = Action(rawValue: sender.tag) else { return }
        onAction?(action)
    }
}

extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        box.widthAnchor.constraint(equalToConstant: 180).isActive = true
        return box
    }
}

// MARK: - 小工具

/// 玻璃上的分隔线：竖直 1pt，压在两块按钮组之间。
final class GlassSeparator: NSView {
    private let vertical: Bool

    init(vertical: Bool = true) {
        self.vertical = vertical
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        Glass.separator.setFill()
        if vertical {
            NSRect(x: 0, y: 4, width: 1, height: max(bounds.height - 8, 1)).fill()
        } else {
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        }
    }
}

extension NSView {
    /// 给自绘视图补一层浮层投影（只给浮在画布上的面板用）。
    func installGlassShadow(radius: CGFloat) {
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = Glass.shadowOpacity
        layer?.shadowRadius = Glass.shadowRadius
        layer?.shadowOffset = CGSize(width: 0, height: -8)
        layer?.shadowPath = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                   cornerWidth: radius, cornerHeight: radius,
                                   transform: nil)
    }

    /// 布局变化后重设投影路径（Path 不会跟着 bounds 走）。
    func refreshGlassShadow(radius: CGFloat) {
        layer?.shadowPath = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                   cornerWidth: radius, cornerHeight: radius,
                                   transform: nil)
    }
}
