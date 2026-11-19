import AppKit

/// 左侧工具竖排：测量工具按"长度 / 面积 / 角度与弧长 / 注释"分组，图标 + 名称。
///
/// 浮在图纸上的一块玻璃板，不再是钉在窗口边缘的一条实心柱子。名称必须留着：
/// 十四个近似的图标里，"圆面积"和"半径"只有靠字才分得清。为了不再吃掉图纸的
/// 宽度，板子压窄到 118pt，行高压到 30pt。
final class ToolPalette: CADGlassSurface, ThemeAware {

    var onToolSelected: ((MeasureKind?) -> Void)?
    var onToggleSnap: ((Bool) -> Void)?
    var onToggleOrtho: ((Bool) -> Void)?
    var onCalibrate: (() -> Void)?
    var onToggleErase: (() -> Void)?

    private(set) var activeTool: MeasureKind?
    private var buttons: [MeasureKind: PaletteRow] = [:]
    private var eraseRow: PaletteRow!
    private let stack = NSStackView()
    private weak var lastGroupRow: NSView?
    /// 分组标题的字色是显式取的（不是系统动态色），系统外观变化时必须自己
    /// 刷一遍，否则深/浅切换后会留下一排发白的字。
    private var groupLabels: [NSTextField] = []

    static let width: CGFloat = 118

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        wantsLayer = true
        installGlassShadow(radius: Glass.Radius.panel)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Glass.draw(in: bounds, radius: Glass.Radius.panel, flipped: isFlipped)
    }

    override func layout() {
        super.layout()
        refreshGlassShadow(radius: Glass.Radius.panel)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        Theme.refreshAppearance()
        needsDisplay = true
        for row in stack.arrangedSubviews { row.needsDisplay = true }
    }

    // MARK: Construction

    private func build() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 7, bottom: 9, right: 7)
        // 工具列要能滚动：窗口矮的时候（13 行 + 分组标题放不下）宁可滚，
        // 也不能让"删除标注 / 校准比例"掉到面板外面去。
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -6),
        ])

        group("长度", [.aligned, .linear, .continuous, .batch])
        group("面积", [.rectangle, .polygon, .circleArea, .hatchArea, .sideArea])
        group("角度与弧长", [.radius, .angle, .arcLength])
        group("注释", [.note])

        // 尺寸删除工具：和测量工具排在同一个分组列里，因为它清理的就是同一批
        // 对象。只放在顶部工具栏时用户找不到它——这已经是第二次问了。
        if let previous = lastGroupRow { stack.setCustomSpacing(8, after: previous) }
        eraseRow = PaletteRow(glyph: .trash, title: "删除标注")
        eraseRow.toolTip = "点击标注删单条，拖框删掉完全框选的标注（E2）· Esc 退出"
        eraseRow.onClick = { [weak self] in self?.onToggleErase?() }
        stack.addArrangedSubview(eraseRow)

        // A separator, then the calibration tool: it is a one-off setup step,
        // not a measurement the user keeps clicking.
        let rule = GlassSeparator(vertical: false)
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        rule.widthAnchor.constraint(equalToConstant: Self.width - 22).isActive = true
        stack.addArrangedSubview(rule)
        stack.setCustomSpacing(6, after: rule)

        let calibrate = PaletteRow(glyph: .calibrate, title: "校准比例")
        calibrate.toolTip = "两点 + 实际长度，反算图纸比例"
        calibrate.onClick = { [weak self] in self?.onCalibrate?() }
        stack.addArrangedSubview(calibrate)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        stack.addArrangedSubview(spacer)

        let hint = NSTextField(labelWithString: "Esc 取消 · 右键结束")
        hint.font = NSFont.systemFont(ofSize: 8.5)
        hint.textColor = Glass.tertiaryText
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(hint)
        NSLayoutConstraint.activate([
            hint.widthAnchor.constraint(equalToConstant: Self.width - 16),
        ])
    }

    private func group(_ title: String, _ kinds: [MeasureKind]) {
        // Air between groups is what makes the column scannable; the heading
        // sits closer to its own rows than to the group above it.
        if let previous = lastGroupRow {
            stack.setCustomSpacing(10, after: previous)
        }
        let label = NSTextField(labelWithString: title)
        // 9.5pt 是玻璃上的分组标题：再大就会和工具名抢注意力，再小在 1× 屏
        // 上会糊成一条灰线。
        label.font = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
        label.textColor = Theme.groupTitle
        groupLabels.append(label)
        label.alignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(label)
        stack.setCustomSpacing(3, after: label)
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: Self.width - 22),
            label.heightAnchor.constraint(equalToConstant: 13),
        ])

        for kind in kinds {
            let row = PaletteRow(glyph: kind.glyph, title: kind.shortTitle)
            row.toolTip = "\(kind.title) · \(kind.purpose)"
            row.onClick = { [weak self] in self?.select(kind) }
            buttons[kind] = row
            stack.addArrangedSubview(row)
            lastGroupRow = row
        }
    }

    // MARK: State

    func setActiveTool(_ kind: MeasureKind?) {
        activeTool = kind
        for (candidate, row) in buttons {
            row.isActive = candidate == kind
        }
        // 选测量工具就退出了删除模式，那一行的高亮要跟着灭。
        if kind != nil { eraseRow.isActive = false }
    }

    func setEraseActive(_ active: Bool) {
        eraseRow.isActive = active
        if active { setActiveTool(nil) }
    }

    private func select(_ kind: MeasureKind) {
        let next: MeasureKind? = activeTool == kind ? nil : kind
        setActiveTool(next)
        onToolSelected?(next)
    }

    func themeDidChange() {
        for label in groupLabels { label.textColor = Theme.groupTitle }
        for row in stack.arrangedSubviews { row.needsDisplay = true }
        needsDisplay = true
    }

    /// 捕捉/正交的开关只在状态栏：这里是测量工具列，重复摆一份同样的开关
    /// 只会让人猜"哪个才算数"。
    func apply(settings: CadSettings) {}

    /// Retained for the canvas callbacks that still announce view modes.
    func setPanActive(_ active: Bool) {}
    func setZoomWindow(_ active: Bool) {}
}

// MARK: - Row

/// 一行工具：图标 + 名称。选中是"一颗被点亮的蓝胶囊"，悬停只是一层薄光。
final class PaletteRow: NSView, ThemeAware {
    private let glyph: CADGlyph
    private let title: String
    private let isToggle: Bool

    var isActive = false { didSet { needsDisplay = true } }
    var isOn = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressReset: DispatchWorkItem?

    init(glyph: CADGlyph, title: String, isToggle: Bool = false) {
        self.glyph = glyph
        self.title = title
        self.isToggle = isToggle
        super.init(frame: NSRect(x: 0, y: 0, width: ToolPalette.width - 14, height: 30))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: ToolPalette.width - 14),
            heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    private var highlighted: Bool { isActive || (isToggle && isOn) }

    override func draw(_ dirtyRect: NSRect) {
        let accent = Theme.accent
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if highlighted {
            Glass.draw(in: bounds, radius: Glass.Radius.pill,
                       tone: .accent, flipped: isFlipped)
        } else if hovering {
            Glass.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: Glass.Radius.pill,
                         yRadius: Glass.Radius.pill).fill()
        }

        let tint = highlighted ? NSColor.white
            : (hovering ? Glass.primaryText : Glass.secondaryText)
        let iconRect = CGRect(x: 8, y: (bounds.height - 16) / 2, width: 16, height: 16)
        glyph.draw(in: ctx, rect: iconRect, color: tint, lineWidth: 1.6)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: highlighted ? .semibold : .regular),
            .foregroundColor: tint,
        ]
        (title as NSString).draw(at: NSPoint(x: 31, y: (bounds.height - 13) / 2),
                                 withAttributes: attributes)
        _ = accent
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow,
                                                 .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        // 按压回弹：整行缩到 0.97 再弹回。鼠标可能在别的控件上松开，
        // 所以由定时兜底复位，不能只等 mouseUp。
        CATransaction.begin()
        CATransaction.setAnimationDuration(Theme.Motion.press)
        layer?.transform = CATransform3DMakeScale(0.97, 0.97, 1)
        CATransaction.commit()
        pressReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.14)
            self?.layer?.transform = CATransform3DIdentity
            CATransaction.commit()
        }
        pressReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: reset)
        onClick?()
    }

    func themeDidChange() { needsDisplay = true }
}
