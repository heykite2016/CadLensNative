import AppKit

// MARK: - Tool button

/// One cell of the CAD toolbars: glyph on top, label underneath, hover and
/// active states drawn by hand. Not an `NSButton`: the bezel styles AppKit
/// offers are all macOS control idioms, and none of them produce the flat,
/// tight, text-under-icon cells a drafting application is expected to show.
final class CADToolButton: NSView, ThemeAware {
    private let glyph: CADGlyph
    private let title: String
    private let iconSide: CGFloat
    private let font: NSFont

    var isActive = false { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { needsDisplay = true } }
    /// A menu attached to the right-hand chevron zone, the way a split tool
    /// button works in AutoCAD (print ▾ / erase ▾).
    var popupMenu: NSMenu?
    var onClick: (() -> Void)?

    private var hovering = false { didSet { needsDisplay = true } }

    init(glyph: CADGlyph, title: String, width: CGFloat = 46,
         iconSide: CGFloat = 17, font: NSFont? = nil) {
        self.glyph = glyph
        self.title = title
        self.iconSide = iconSide
        self.font = font ?? NSFont.systemFont(ofSize: 9.5, weight: .medium)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 44))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: 44).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 46, height: 44) }

    /// 选中/悬停的底色。
    ///
    /// 这里必须自己画，不能交给 `FadeBackdrop` 那种子 layer：子 layer 永远
    /// 压在视图内容之上，浅色下选中态是一块近白的圆角，图标和文字被整块
    /// 盖掉，看起来就像按钮空了。画在 `draw` 里才有正确的层序。
    private var stateTint: NSColor? {
        if isActive {
            // 选中给一层薄品牌蓝 + 蓝字：五颗都染实心蓝会连成一条蓝带，
            // 反而看不出当前是哪一件工具。
            return Theme.accent.withAlphaComponent(Glass.isDark ? 0.30 : 0.16)
        }
        return hovering && isEnabled ? Glass.hover : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if let tint = stateTint {
            tint.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                         xRadius: Glass.Radius.control,
                         yRadius: Glass.Radius.control).fill()
        }
        // 选中时图标与文字都取品牌蓝：底色只加了 16% 蓝，光靠底色认不出
        // 哪个是当前工具，必须让字跟着变色。
        let tint = !isEnabled ? Glass.tertiaryText
            : (isActive ? Theme.accent : Glass.secondaryText)
        let iconRect = CGRect(x: (bounds.width - iconSide) / 2,
                              y: popupMenu == nil ? 6 : 5,
                              width: iconSide, height: iconSide)
        glyph.draw(in: ctx, rect: iconRect, color: tint, lineWidth: 1.55)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: isEnabled ? tint : Glass.tertiaryText,
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        let maxWidth = bounds.width - (popupMenu == nil ? 2 : 9)
        let textWidth = min(size.width, maxWidth)
        let textRect = CGRect(x: (bounds.width - textWidth) / 2,
                              y: bounds.maxY - 15,
                              width: textWidth, height: 11)
        (title as NSString).draw(in: textRect, withAttributes: attributes)

        if popupMenu != nil {
            // Split-button affordance beside the caption, not under it: the
            // chevron used to land on top of the last character.
            let chevronRect = CGRect(x: textRect.maxX + 1, y: bounds.maxY - 13,
                                     width: 7, height: 7)
            CADGlyph.chevronDown.draw(in: ctx, rect: chevronRect,
                                      color: tint.withAlphaComponent(0.65),
                                      lineWidth: 1.5)
        }
        if isActive {
            // 选中块的内高光：和玻璃面板同一套语言，亮面在上沿。
            ctx.setFillColor(NSColor(white: 1, alpha: Glass.isDark ? 0.28 : 0.9).cgColor)
            ctx.fill(CGRect(x: 5, y: 1, width: bounds.width - 10, height: 1))
        }
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
        guard isEnabled else { NSSound.beep(); return }
        let point = convert(event.locationInWindow, from: nil)
        if let popupMenu, point.x > bounds.maxX - 16 {
            popupMenu.popUp(positioning: popupMenu.items.first,
                            at: NSPoint(x: 0, y: bounds.maxY), in: self)
            return
        }
        guard let onClick else { return }
        // 按下即反馈，不等松手——反馈和动作同时发生，手感才是"跟手"的。
        setPressed(true)
        onClick()
    }

    override func mouseUp(with event: NSEvent) {
        setPressed(false)
    }

    /// 按下时整格缩到 0.96 再弹回。自绘控件没有系统 bezel，少这一下会觉得
    /// "点了没反应"。
    private func setPressed(_ pressed: Bool) {
        wantsLayer = true
        CATransaction.begin()
        CATransaction.setAnimationDuration(Theme.Motion.press)
        CATransaction.setAnimationTimingFunction(Theme.Motion.easeOutCurve)
        layer?.transform = pressed ? CATransform3DMakeScale(0.96, 0.96, 1)
                                    : CATransform3DIdentity
        CATransaction.commit()
    }

    func themeDidChange() {
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let popupMenu else { return }
        popupMenu.popUp(positioning: popupMenu.items.first,
                        at: NSPoint(x: 0, y: bounds.maxY), in: self)
    }
}

// MARK: - Toolbar

/// 顶部玻璃工具岛：文件命令、撤销、视图、面板开关，右侧留给图纸页签。
///
/// 从"通栏工具栏"改成浮岛，是为了让图纸从窗口最上沿就开始铺——那条 60pt 的
/// 实心横栏一直是这个窗口里最厚的一刀。命令顺序没变：a drafter 的手不会因为
/// 换了皮就找不到按钮。
final class CADToolbar: CADGlassSurface {
    struct Command: RawRepresentable, Hashable {
        let rawValue: String
        init(rawValue: String) { self.rawValue = rawValue }
        static let open = Command(rawValue: "open")
        static let print = Command(rawValue: "print")
        static let printFrames = Command(rawValue: "printFrames")
        static let undo = Command(rawValue: "undo")
        static let redo = Command(rawValue: "redo")
        static let erase = Command(rawValue: "erase")
        static let select = Command(rawValue: "select")
        static let fit = Command(rawValue: "fit")
        static let zoomWindow = Command(rawValue: "zoomWindow")
        static let pan = Command(rawValue: "pan")
        static let zoomIn = Command(rawValue: "zoomIn")
        static let zoomOut = Command(rawValue: "zoomOut")
        static let layers = Command(rawValue: "layers")
        static let annotations = Command(rawValue: "annotations")
        static let export = Command(rawValue: "export")
        static let settings = Command(rawValue: "settings")
        static let help = Command(rawValue: "help")
    }

    var onCommand: ((Command) -> Void)?
    private var buttons: [Command: CADToolButton] = [:]
    private let stack = NSStackView()
    /// 图纸页签从外面装进来：页签的数据属于窗口，工具岛只负责留位置。
    private(set) var tabSlot = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 56).isActive = true
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
        for button in buttons.values { button.needsDisplay = true }
    }

    private func build() {
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        add(to: stack, .open, .open, "打开")
        let printMenu = NSMenu()
        let printItem = NSMenuItem(title: "选区打印…", action: #selector(doPrint), keyEquivalent: "")
        printItem.target = self
        let framesItem = NSMenuItem(title: "打印图纸（布局图框）…", action: #selector(doPrintFrames),
                                    keyEquivalent: "")
        framesItem.target = self
        printMenu.addItem(printItem)
        printMenu.addItem(framesItem)
        add(to: stack, .print, .print, "打印", menu: printMenu)
        stack.addArrangedSubview(separator())

        add(to: stack, .undo, .undo, "撤销")
        add(to: stack, .redo, .redo, "重做")
        add(to: stack, .erase, .trash, "删除")
        stack.addArrangedSubview(separator())

        add(to: stack, .select, .select, "选择")
        // 「平移」不再是一件工具：在图纸上按住左键拖动就是平移，多一个模式
        // 只会让人多点一次。视图命令里保留窗口缩放和显示全图。
        add(to: stack, .zoomWindow, .zoomWindow, "窗口")
        add(to: stack, .fit, .zoomFit, "全图")
        stack.addArrangedSubview(separator())

        add(to: stack, .layers, .layers, "图层")
        add(to: stack, .annotations, .panel, "标注")
        stack.addArrangedSubview(separator())

        add(to: stack, .settings, .settings, "设置")
        stack.addArrangedSubview(separator())

        // 图纸页签居中展开：多开几张图时它是这一条里最需要空间的元素，所以
        // 由它吃掉剩余宽度（上限在 MainWindow 里设），帮助按钮钉在最右。
        tabSlot.translatesAutoresizingMaskIntoConstraints = false
        tabSlot.setContentHuggingPriority(.init(1), for: .horizontal)
        stack.addArrangedSubview(tabSlot)

        add(to: stack, .help, .note, "帮助")
    }

    /// 把页签栏装进工具岛。约束由调用方给（页签的宽度上限属于窗口）。
    func install(tabs: NSView) {
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabSlot.addSubview(tabs)
        // 只钉左右和竖直居中：页签自己定高 32，硬拉到 44 会和它的高度
        // 约束打架（Auto Layout 会随机破掉一条，页签就飘了）。
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: tabSlot.leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: tabSlot.trailingAnchor),
            tabs.centerYAnchor.constraint(equalTo: tabSlot.centerYAnchor),
        ])
    }

    private func add(to stack: NSStackView, _ command: Command, _ glyph: CADGlyph,
                     _ title: String, menu: NSMenu? = nil) {
        let button = CADToolButton(glyph: glyph, title: title)
        button.popupMenu = menu
        button.onClick = { [weak self] in self?.onCommand?(command) }
        buttons[command] = button
        stack.addArrangedSubview(button)
    }

    private func separator() -> NSView {
        let view = GlassSeparator()
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 1),
            view.heightAnchor.constraint(equalToConstant: 24),
        ])
        return view
    }

    /// 图纸身份挂在工具岛的悬停提示上：页签已经写着文件名，这里补上"多少个
    /// 图元、多少个图层"，不占一条常驻文字。
    func setDocumentCaption(_ text: String) {
        toolTip = text
    }

    func setActive(_ command: Command, _ active: Bool) {
        buttons[command]?.isActive = active
    }

    func setEnabled(_ command: Command, _ enabled: Bool) {
        buttons[command]?.isEnabled = enabled
    }

    @objc private func doPrint() { onCommand?(.print) }
    @objc private func doPrintFrames() { onCommand?(.printFrames) }
}

/// Small drafting mark: a sheet corner with a dimension line across it.
final class BrandMark: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let accent = Theme.accent
        let rect = bounds.insetBy(dx: 1, dy: 1)
        ctx.saveGState()
        let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(accent.withAlphaComponent(0.16).cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(accent.withAlphaComponent(0.5).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        ctx.restoreGState()
        CADGlyph.aligned.draw(in: ctx, rect: rect.insetBy(dx: 5, dy: 5),
                              color: accent, lineWidth: 1.6)
    }
}

// MARK: - Status bar

/// 底部状态行：左边是绘图辅助开关，右边是坐标与比例读数，全部做成玻璃胶囊。
///
/// 原来这是一条 28pt 的实心横栏，压着画布下沿。改成浮层后，图纸可以一直画到
/// 窗口底边；每个开关各自是一颗胶囊，按下去只点亮自己那一颗。
final class CADStatusBar: CADGlassSurface {
    var onToggleSnap: ((Bool) -> Void)?
    var onToggleGrid: ((Bool) -> Void)?
    var onToggleOrtho: ((Bool) -> Void)?
    var onToggleLineweight: ((Bool) -> Void)?
    var onToggleAnnotations: ((Bool) -> Void)?
    /// Right-click on 捕捉 opens the target list, the way the reference app's
    /// status-bar snap button does. Built lazily so the checkmarks always match
    /// the settings that are live right now.
    var snapMenuProvider: (() -> NSMenu?)?

    private let coordinate = NSTextField(labelWithString: "X —      Y —")
    private let scaleLabel = NSTextField(labelWithString: "1:100")
    private let zoomLabel = NSTextField(labelWithString: "")
    private var snapButton: CADStatusToggle!
    private var gridButton: CADStatusToggle!
    private var orthoButton: CADStatusToggle!
    private var lineweightButton: CADStatusToggle!
    private var annotationsButton: CADStatusToggle!
    /// 读数胶囊的矩形。三块标签各自有约束，胶囊是它们的并集，所以放在
    /// layout 里算一次，draw 时直接用。
    private var readoutRect = CGRect.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard readoutRect.width > 8 else { return }
        Glass.draw(in: readoutRect, radius: Glass.Radius.pill, flipped: isFlipped)
    }

    override func layout() {
        super.layout()
        readoutRect = NSRect(x: coordinate.frame.minX - 11,
                             y: (bounds.height - 26) / 2,
                             width: max(zoomLabel.frame.maxX - coordinate.frame.minX + 22, 0),
                             height: 26)
        needsDisplay = true
    }

    private func build() {
        coordinate.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        coordinate.textColor = Glass.secondaryText
        coordinate.translatesAutoresizingMaskIntoConstraints = false

        scaleLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        scaleLabel.textColor = Glass.secondaryText
        scaleLabel.alignment = .right
        scaleLabel.translatesAutoresizingMaskIntoConstraints = false
        zoomLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        zoomLabel.textColor = Glass.tertiaryText
        zoomLabel.alignment = .right
        zoomLabel.translatesAutoresizingMaskIntoConstraints = false

        snapButton = CADStatusToggle(title: "捕捉", tooltip: "对象捕捉 (F3) · 右键设置捕捉点") { [weak self] on in
            self?.onToggleSnap?(on)
        }
        snapButton.menuProvider = { [weak self] in self?.snapMenuProvider?() }
        gridButton = CADStatusToggle(title: "栅格", tooltip: "栅格显示 (F7)") { [weak self] on in
            self?.onToggleGrid?(on)
        }
        orthoButton = CADStatusToggle(title: "正交", tooltip: "正交约束 (F8)") { [weak self] on in
            self?.onToggleOrtho?(on)
        }
        lineweightButton = CADStatusToggle(title: "线宽", tooltip: "显示 CAD 线宽") { [weak self] on in
            self?.onToggleLineweight?(on)
        }
        annotationsButton = CADStatusToggle(title: "标注", tooltip: "显示或隐藏标注 (⌘⇧A)") { [weak self] on in
            self?.onToggleAnnotations?(on)
        }

        let toggles = NSStackView(views: [snapButton, gridButton, orthoButton,
                                          lineweightButton, annotationsButton])
        toggles.orientation = .horizontal
        toggles.spacing = 6
        toggles.translatesAutoresizingMaskIntoConstraints = false

        addSubview(toggles)
        addSubview(coordinate)
        addSubview(scaleLabel)
        addSubview(zoomLabel)

        NSLayoutConstraint.activate([
            toggles.leadingAnchor.constraint(equalTo: leadingAnchor),
            toggles.centerYAnchor.constraint(equalTo: centerYAnchor),

            zoomLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            zoomLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            scaleLabel.trailingAnchor.constraint(equalTo: zoomLabel.leadingAnchor, constant: -10),
            scaleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            coordinate.trailingAnchor.constraint(equalTo: scaleLabel.leadingAnchor, constant: -12),
            coordinate.centerYAnchor.constraint(equalTo: centerYAnchor),
            coordinate.leadingAnchor.constraint(greaterThanOrEqualTo: toggles.trailingAnchor,
                                                constant: 12),
        ])
    }

    func updateSettings(_ settings: CadSettings, annotationsVisible: Bool) {
        snapButton.isOn = settings.objectSnap
        gridButton.isOn = settings.showGrid
        orthoButton.isOn = settings.orthoMode
        lineweightButton.isOn = settings.showLineweights
        annotationsButton.isOn = annotationsVisible
    }

    func updateCoordinate(_ text: String) { coordinate.stringValue = text }

    func updateZoom(_ scale: CGFloat) {
        zoomLabel.stringValue = String(format: "%.3g×", scale)
    }

    /// Ratio between drawing units and paper, stated the way a title block
    /// states it (1:100), because that is the number a site engineer checks.
    func updateScale(_ text: String) {
        scaleLabel.stringValue = text
    }
}

final class CADStatusToggle: NSView, ThemeAware {
    private let title: String
    /// Right-click / control-click menu, built on demand.
    var menuProvider: (() -> NSMenu?)?
    var isOn = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    private let onChange: (Bool) -> Void

    init(title: String, tooltip: String, onChange: @escaping (Bool) -> Void) {
        self.title = title
        self.onChange = onChange
        super.init(frame: .zero)
        toolTip = tooltip
        translatesAutoresizingMaskIntoConstraints = false
        // 按压回弹写在 layer 上，必须自己开 backing layer。
        wantsLayer = true
        let width = (title as NSString).size(withAttributes:
            [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium)]).width + 18
        widthAnchor.constraint(equalToConstant: ceil(width)).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // 关着的胶囊是凹的，开着的是亮的：靠"凹/凸"比靠颜色深浅更容易一眼
        // 扫出哪几个开关是开的。
        Glass.draw(in: bounds, radius: Glass.Radius.pill,
                   tone: isOn ? .regular : .sunken, flipped: isFlipped)
        if isOn {
            // 开着的开关点亮一层薄蓝 + 蓝字：五颗全实心蓝会连成一条蓝带，
            // 那就看不出哪颗是关键状态了。
            Theme.accent.withAlphaComponent(Glass.isDark ? 0.22 : 0.16).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                         xRadius: Glass.Radius.pill, yRadius: Glass.Radius.pill).fill()
        }
        if hovering && !isOn {
            Glass.hover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                         xRadius: Glass.Radius.pill, yRadius: Glass.Radius.pill).fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: isOn ? .semibold : .medium),
            .foregroundColor: isOn ? Theme.accent
                : (hovering ? Glass.primaryText : Glass.secondaryText),
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                             y: (bounds.height - size.height) / 2),
                                 withAttributes: attributes)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow,
                                                 .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        // 胶囊的按压反馈：整颗缩到 0.96 再弹回。自绘控件没有系统 bezel，
        // 少这一下会觉得"点了没反应"。
        CATransaction.begin()
        CATransaction.setAnimationDuration(Theme.Motion.press)
        layer?.transform = CATransform3DMakeScale(0.96, 0.96, 1)
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        CATransaction.setCompletionBlock { [weak self] in
            self?.layer?.transform = CATransform3DIdentity
        }
        CATransaction.commit()
        onChange(isOn)
    }

    func themeDidChange() { needsDisplay = true }
}

// MARK: - Command line

/// 命令行的候选条目：中文名 + 可直接输入的别名 + 一句话说明。
struct CommandSuggestion {
    let title: String
    let alias: String
    let detail: String
    var token: String { alias.isEmpty ? title : alias }
    var chipTitle: String { alias.isEmpty ? title : "\(title)  \(alias)" }
}

/// 命令行下方的候选浮层：输入框外面，一行一条，最多八行。
///
/// 之前候选是横着排在输入框右边的小胶囊，命令一多就挤成一条被截断的长条——
/// 用户既看不清有哪几个命令，也看不出哪个是当前选中的。参考项目用的是输入框
/// 上方的多行列表，一屏能把候选连同说明一起列完。
final class CADCommandSuggestionsPanel: NSView {
    static let rowHeight: CGFloat = 26
    private var candidates: [CommandSuggestion] = []
    private var tracking: [CGRect] = []
    var onPick: ((Int) -> Void)?

    var highlighted = 0 { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -4)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func show(_ candidates: [CommandSuggestion], highlighted: Int) {
        self.candidates = candidates
        self.highlighted = highlighted
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !candidates.isEmpty else { return }
        Glass.draw(in: bounds, radius: Glass.Radius.group, flipped: isFlipped)

        tracking.removeAll()
        for (index, candidate) in candidates.enumerated() {
            let row = CGRect(x: 5, y: 5 + CGFloat(index) * Self.rowHeight,
                             width: bounds.width - 10, height: Self.rowHeight)
            tracking.append(row)
            if index == highlighted {
                NSColor(white: 1, alpha: Glass.isDark ? 0.14 : 0.5).setFill()
                NSBezierPath(roundedRect: row.insetBy(dx: 0, dy: 1),
                             xRadius: Glass.Radius.pill, yRadius: Glass.Radius.pill).fill()
            }
            let aliasAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: Theme.accent,
            ]
            let detailAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5,
                                         weight: index == highlighted ? .semibold : .regular),
                .foregroundColor: NSColor.labelColor,
            ]
            let detailSize = (candidate.detail as NSString).size(withAttributes: detailAttrs)
            (candidate.token as NSString).draw(
                at: NSPoint(x: row.minX + 12, y: row.minY + (row.height - 14) / 2),
                withAttributes: aliasAttrs)
            (candidate.title as NSString).draw(
                at: NSPoint(x: row.minX + 62, y: row.minY + (row.height - 15) / 2),
                withAttributes: titleAttrs)
            if row.width > 240 {
                (candidate.detail as NSString).draw(
                    at: NSPoint(x: row.maxX - 12 - detailSize.width,
                                y: row.minY + (row.height - 14) / 2),
                    withAttributes: detailAttrs)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for (index, row) in tracking.enumerated() where row.contains(point) {
            onPick?(index)
            return
        }
    }

}

/// Single-line command input under the canvas. A drafting application without
/// a command line feels like a viewer; typing an alias is the fastest way to
/// switch tools once the twelve buttons are no longer new.
///
/// 提示文字紧跟在输入内容后面（输入框宽度跟着字走），候选另起一层浮在输入框
/// 上方——参考项目的命令行就是这么排的：手不停，眼睛不用在窗口里来回找。
final class CADCommandBar: CADGlassSurface, NSTextFieldDelegate {
    var onSubmit: ((String) -> Void)?
    /// Answers "what could they mean by this prefix?", ordered best first.
    var suggestionsProvider: ((String) -> [CommandSuggestion])?
    private let input = NSTextField()
    private let prompt = NSTextField(labelWithString: "")
    private let panel = CADCommandSuggestionsPanel()
    private var candidates: [CommandSuggestion] = []
    private var highlighted = 0
    private var inputWidth: NSLayoutConstraint!
    private var panelHeight: NSLayoutConstraint?
    private var inputField: NSTextField? { input }
    /// 输入框最窄也留 190pt：太窄连 "命令:" 都对不齐，提示会紧贴着脸。
    private static let minInputWidth: CGFloat = 250
    private static let maxInputWidth: CGFloat = 430

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 38).isActive = true
        wantsLayer = true
        installGlassShadow(radius: Glass.Radius.group)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Glass.draw(in: bounds, radius: Glass.Radius.group, flipped: isFlipped)

        // 输入井：一块凹槽，明确"字打在这里"。它不跟着输入框宽度走，而是
        // 占住输入框 + 提示区的前半段，免得提示文字飘在玻璃上找不到归属。
        let well = CGRect(x: 5, y: 5, width: max(input.frame.maxX + 8, 210),
                          height: bounds.height - 10)
        Glass.draw(in: well, radius: Glass.Radius.pill, tone: .sunken, flipped: isFlipped)
    }

    private func build() {
        let prefix = NSTextField(labelWithString: "命令:")
        prefix.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        prefix.textColor = Theme.accent
        prefix.translatesAutoresizingMaskIntoConstraints = false

        input.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.placeholderString = "AL · DLI · AA · Z"
        input.delegate = self
        input.target = self
        input.action = #selector(submit)
        input.translatesAutoresizingMaskIntoConstraints = false
        input.setContentHuggingPriority(.init(1), for: .horizontal)

        prompt.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        prompt.textColor = .secondaryLabelColor
        // 提示靠右贴边：左边输入井已经把"字打在这里"说清了，右边空出一大片
        // 玻璃只会显得命令行没画完。CAD 的老习惯也是提示靠窗口右下。
        prompt.alignment = .right
        prompt.lineBreakMode = .byTruncatingHead
        prompt.translatesAutoresizingMaskIntoConstraints = false
        prompt.setContentCompressionResistancePriority(.init(250), for: .horizontal)

        addSubview(prefix)
        addSubview(input)
        addSubview(prompt)

        inputWidth = input.widthAnchor.constraint(equalToConstant: Self.minInputWidth)
        NSLayoutConstraint.activate([
            // 14pt 是输入井的左内边距（井从 5 开始，圆角 9）。
            prefix.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            prefix.centerYAnchor.constraint(equalTo: centerYAnchor),
            input.leadingAnchor.constraint(equalTo: prefix.trailingAnchor, constant: 6),
            input.centerYAnchor.constraint(equalTo: centerYAnchor),
            inputWidth,
            // 提示靠右齐平，跨过输入井之后的整段空白。
            prompt.leadingAnchor.constraint(greaterThanOrEqualTo: input.trailingAnchor,
                                            constant: 12),
            prompt.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            prompt.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func setPrompt(_ text: String) {
        prompt.stringValue = text
        prompt.textColor = .secondaryLabelColor
        prompt.toolTip = nil
    }

    /// A load-time warning (missing xrefs, skipped objects) belongs in the
    /// status area but not in the hint slot: drawn in hint grey it read as
    /// "the command you should type next", and it vanished the moment the user
    /// picked a tool. Amber text plus the full list in the tooltip keeps the
    /// information without competing with the live prompt.
    func setNotice(_ short: String, detail: String) {
        prompt.stringValue = short
        prompt.textColor = NSColor(srgbRed: 0.98, green: 0.70, blue: 0.28, alpha: 1)
        prompt.toolTip = detail
    }

    func focus() {
        window?.makeFirstResponder(input)
    }

    /// 把一段文字塞进输入框（自测脚本用）：走的是和手打一样的路径，候选
    /// 浮层、提示跟随都要跟着动。
    func typeIntoInput(_ text: String) {
        focus()
        input.stringValue = text
        sanitize()
        resizeInput()
        refreshCandidates()
    }

    func clear() {
        input.stringValue = ""
        refreshCandidates()
        resizeInput()
    }

    @objc private func submit() {
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        input.stringValue = ""
        refreshCandidates()
        resizeInput()
        guard !text.isEmpty else { return }
        onSubmit?(text)
    }

    // MARK: Candidates

    private func refreshCandidates() {
        let text = input.stringValue.trimmingCharacters(in: .whitespaces)
        candidates = text.isEmpty ? [] : Array((suggestionsProvider?(text) ?? []).prefix(8))
        highlighted = 0
        syncPanel()
    }

    private func syncPanel() {
        guard !candidates.isEmpty, let host = superview else {
            panel.removeFromSuperview()
            panelHeight = nil
            return
        }
        panel.show(candidates, highlighted: highlighted)
        panel.onPick = { [weak self] index in self?.complete(index) }
        let height = CGFloat(candidates.count) * CADCommandSuggestionsPanel.rowHeight + 10
        if panel.superview !== host {
            panel.removeFromSuperview()
            panel.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(panel)
            // 用约束把候选钉在"命令栏的正上方"，比手算 frame 稳：坐标系的翻转
            // 方向不同（root 可能是 flipped 也可能不是），右下角的锚点却只有
            // 一个含义。
            NSLayoutConstraint.activate([
                panel.leadingAnchor.constraint(equalTo: input.leadingAnchor, constant: -10),
                panel.bottomAnchor.constraint(equalTo: topAnchor, constant: -6),
                panel.widthAnchor.constraint(equalToConstant: 420),
            ])
            // 浮层不要凭空出现：120ms 淡入，和面板里 hover 的节奏一致。
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Theme.Motion.hover
                context.timingFunction = Theme.Motion.easeOutCurve
                panel.animator().alphaValue = 1
            }
        }
        if let constraint = panelHeight {
            constraint.constant = height
        } else {
            panelHeight = panel.heightAnchor.constraint(equalToConstant: height)
            panelHeight?.isActive = true
        }
    }

    override func layout() {
        super.layout()
        refreshGlassShadow(radius: Glass.Radius.group)
        if panel.superview != nil { syncPanel() }
    }

    /// 输入框宽度跟着文字走，提示才会贴在字后面而不是隔着一大片空白。
    private func resizeInput() {
        let text = input.stringValue
        let width = (text as NSString).size(withAttributes:
            [.font: input.font ?? NSFont.systemFont(ofSize: 11)]).width
        let target = min(max(width + 30, Self.minInputWidth), Self.maxInputWidth)
        guard abs(target - inputWidth.constant) > 0.5 else { return }
        inputWidth.constant = target
        needsDisplay = true
    }

    /// 只填进输入框，不执行——Tab 是"补全"，回车才是"执行"。
    private func complete(_ index: Int) {
        guard index >= 0, index < candidates.count else { return }
        input.stringValue = candidates[index].token
        highlight(0)
        refreshCandidates()
        resizeInput()
        window?.makeFirstResponder(input)
    }

    private func highlight(_ index: Int) {
        guard !candidates.isEmpty else { return }
        highlighted = max(0, min(index, candidates.count - 1))
        panel.highlighted = highlighted
    }

    private func moveHighlight(_ delta: Int) {
        guard !candidates.isEmpty else { return }
        highlight((highlighted + delta + candidates.count) % candidates.count)
    }

    // MARK: Input

    /// 命令行只认 ASCII。参考项目用 ImhLatinOnly + 正则校验器做到了这一点：
    /// 用户不用先切输入法，中文法里敲出来的字根本进不去。AppKit 这边把字段
    /// 编辑器的输入源限制到拉丁系，再在每次变化后剔掉非 ASCII 字符兜底。
    private func sanitize() {
        let raw = input.stringValue
        let cleaned = String(raw.unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 })
        if cleaned != raw {
            input.stringValue = cleaned
            NSSound.beep()
        }
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        if let editor = notification.object as? NSTextView {
            editor.allowedInputSourceLocales = ["NSAllRomanInputSources"]
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        sanitize()
        resizeInput()
        refreshCandidates()
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            input.stringValue = ""
            refreshCandidates()
            resizeInput()
            window?.makeFirstResponder(nil)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveHighlight(-1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveHighlight(1)
            return true
        case #selector(NSResponder.insertTab(_:)):
            guard !candidates.isEmpty else { return false }
            complete(highlighted)
            return true
        default:
            return false
        }
    }
}

// MARK: - Layout tabs

/// 模型 / 布局 tabs, bottom-left, exactly where every CAD package puts them.
///
/// 一块玻璃凹槽里排一排胶囊：当前空间是那块被点亮的蓝。布局名字长、
/// 布局多的时候按比例压缩（上限 `maxStripWidth`），把宽度留给状态读数。
final class CADLayoutTabs: CADGlassSurface {
    /// 标签栏最多占这么多宽度，剩下的必须留给状态栏。什邡那种十几个布局
    /// 且名字很长的图纸，之前按全名累加 intrinsic width，直接把状态栏挤出。
    static let maxStripWidth: CGFloat = 420

    var onSelect: ((Int) -> Void)?
    private var tabs: [String] = []
    private var selected = 0
    private var tracking: [CGRect] = []
    private var hovered: Int?

    /// 「模型」之后的标签可以横向滚动。布局多到一栏装不下时，宁可滚动也不
    /// 把名字压成「…」——布局名是唯一能认出这是哪张图的信息，压掉就没用了。
    private var scroll: CGFloat = 0
    private var pendingReveal = true
    /// 上一次排版时的宽度。窗口拉伸后要重新把当前布局滚回可视区。
    private var lastWidth: CGFloat = 0

    private let leadingPad: CGFloat = 4
    private let interTab: CGFloat = 2
    private let maxTabWidth: CGFloat = 156
    /// 「模型」和当前布局不套 156 的上限：这两个必须读全。
    private let maxPinnedTabWidth: CGFloat = 260
    private let textPad: CGFloat = 22
    private let barHeight: CGFloat = 28
    private let fadeWidth: CGFloat = 18

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: barHeight).isActive = true
        // 空间不够时让标签栏先压缩，状态栏保持可读。
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// 自然宽度按内容给，但封顶在 `maxStripWidth`——这是"长布局名不撑满
    /// 状态栏"的关键。装不下的部分靠横向滚动，而不是压缩标签。
    override var intrinsicContentSize: NSSize {
        NSSize(width: naturalWidth, height: barHeight)
    }

    private func idealWidth(_ index: Int) -> CGFloat {
        let text = tabs[index]
        // 选中态是 semibold，量宽度就得用 semibold，否则字尾被切。
        let font = NSFont.systemFont(ofSize: 11, weight: index == selected ? .semibold : .regular)
        let size = (text as NSString).size(withAttributes: [.font: font])
        // +2 是取整余量：量出来 44.4、画的时候按 44 算，末尾那个字就被
        // 截成省略号了（"节点详图" 就是这么变成 "节点详…" 的）。
        return max(size.width + textPad + 2, 54)
    }

    private var naturalWidth: CGFloat {
        guard !tabs.isEmpty else { return 60 }
        let sum = tabs.indices.reduce(CGFloat(0)) { $0 + idealWidth($1) }
            + interTab * CGFloat(tabs.count - 1) + leadingPad * 2
        return max(60, min(sum, Self.maxStripWidth))
    }

    /// 一条标签栏的几何：每个标签的宽度、可滚动区域、滚动内容的宽度。
    /// `draw` / `reveal` / `scrollWheel` 共用同一份，免得三处算错一处。
    private struct Metrics {
        var widths: [CGFloat]
        var viewport: CGRect
        var content: CGFloat
    }

    private func metrics() -> Metrics {
        let widths = tabs.indices.map { index -> CGFloat in
            let pinned = index == 0 || index == selected
            return min(idealWidth(index), pinned ? maxPinnedTabWidth : maxTabWidth)
        }
        let modelEnd = leadingPad + (widths.first ?? 0)
        let left = modelEnd + (tabs.count > 1 ? interTab : 0)
        let right = max(bounds.width - leadingPad, left)
        let content = tabs.count > 1
            ? widths.dropFirst().reduce(0, +) + interTab * CGFloat(tabs.count - 2)
            : 0
        return Metrics(widths: widths,
                       viewport: CGRect(x: left, y: 0,
                                        width: right - left, height: bounds.height),
                       content: content)
    }

    /// 按可用宽度把长标题截成带省略号的短串，保证标签收缩后文字不溢出。
    private func truncated(_ title: String, font: NSFont, maxWidth: CGFloat) -> String {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        if (title as NSString).size(withAttributes: attrs).width <= maxWidth { return title }
        let ellipsis = "…"
        let ellipsisWidth = (ellipsis as NSString).size(withAttributes: attrs).width
        let budget = maxWidth - ellipsisWidth
        var result = ""
        for ch in title {
            let candidate = result + String(ch)
            if (candidate as NSString).size(withAttributes: attrs).width > budget { break }
            result = candidate
        }
        return result + ellipsis
    }

    override func draw(_ dirtyRect: NSRect) {
        // 凹槽：这颗胶囊告诉眼睛"这几个是互斥的页"，而不是三个独立按钮。
        Glass.draw(in: bounds, radius: Glass.Radius.pill,
                   tone: .sunken, flipped: isFlipped)
        tracking.removeAll()
        guard !tabs.isEmpty else { return }

        // 第一次绘制时 Auto Layout 可能还没给出宽度，按 0 宽算出来的
        // "可见区"会把 scroll 顶到底（当前布局反被顶出屏幕）。宽度没
        // 定下来就先不揭幕，等真有宽度再滚。
        if bounds.width > 0.5, abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            pendingReveal = true
        }
        let m = metrics()
        let limit = max(m.content - m.viewport.width, 0)
        if pendingReveal, m.viewport.width > 1 {
            pendingReveal = false
            scroll = revealed(scroll, in: m)
        }
        scroll = min(max(scroll, 0), limit)

        // 「模型」钉在最左边，不参与滚动：无论图里有多少布局、滚到多远，
        // 回模型的路总在原地。
        let model = CGRect(x: leadingPad, y: 3,
                           width: m.widths[0], height: bounds.height - 6)
        tracking.append(model)
        drawTab(0, in: model)

        guard tabs.count > 1, m.viewport.width > 1 else { return }

        let ctx = NSGraphicsContext.current?.cgContext
        let shift = m.viewport.minX - scroll
        ctx?.saveGState()
        ctx?.clip(to: m.viewport)
        ctx?.translateBy(x: shift, y: 0)
        var x: CGFloat = 0
        for index in 1..<tabs.count {
            let local = CGRect(x: x, y: 3, width: m.widths[index], height: bounds.height - 6)
            // 命中区裁到可视区：滚出去的半颗标签不能还在"模型"那块地方
            // 抢点击。
            tracking.append(local.offsetBy(dx: shift, dy: 0).intersection(m.viewport))
            drawTab(index, in: local)
            x += m.widths[index] + interTab
        }
        ctx?.restoreGState()

        // 两头还有没露出来的标签：压一道渐隐，提示"这里还能滚"。
        let band = CGRect(x: m.viewport.minX, y: 2,
                          width: fadeWidth, height: bounds.height - 4)
        if scroll > 0.5 {
            drawFade(band, base: true)
        }
        if scroll < limit - 0.5 {
            drawFade(CGRect(x: m.viewport.maxX - fadeWidth, y: band.minY,
                            width: fadeWidth, height: band.height), base: false)
        }
    }

    private func drawTab(_ index: Int, in rect: CGRect) {
        let active = index == selected
        let font = NSFont.systemFont(ofSize: 11, weight: active ? .semibold : .regular)
        if active {
            Glass.draw(in: rect, radius: Glass.Radius.pill,
                       tone: .accent, flipped: isFlipped)
        } else if hovered == index {
            Glass.hover.setFill()
            NSBezierPath(roundedRect: rect, xRadius: Glass.Radius.pill,
                         yRadius: Glass.Radius.pill).fill()
        }
        let color = active ? NSColor.white
            : (hovered == index ? Glass.primaryText : Glass.secondaryText)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        // 现在只有"名字比 260 还长"或者窗口被拖到极窄时才会截断。
        let shown = truncated(tabs[index], font: font, maxWidth: max(rect.width - textPad, 8))
        let size = (shown as NSString).size(withAttributes: attributes)
        (shown as NSString).draw(at: NSPoint(x: rect.minX + (rect.width - size.width) / 2,
                                             y: (bounds.height - size.height) / 2),
                                 withAttributes: attributes)
    }

    /// 渐隐用的暗色：它不是"模糊"，只是一层遮罩，让边缘的标签读起来是
    /// 被页签栏裁掉的，而不是画错了。
    private func drawFade(_ rect: CGRect, base: Bool) {
        guard rect.width > 0 else { return }
        let shade = NSColor.black.withAlphaComponent(Glass.isDark ? 0.34 : 0.12)
        let clear = shade.withAlphaComponent(0)
        NSGradient(starting: base ? shade : clear,
                   ending: base ? clear : shade)?.draw(in: rect, angle: 0)
    }

    /// 让当前布局完整露出来：切布局、换图纸之后，选中那颗不能被裁在边上。
    private func revealed(_ current: CGFloat, in m: Metrics) -> CGFloat {
        guard selected > 0, selected < m.widths.count else { return 0 }
        var start: CGFloat = 0
        for index in 1..<selected { start += m.widths[index] + interTab }
        let end = start + m.widths[selected]
        var result = current
        if start < current {
            result = start
        } else if end > current + m.viewport.width {
            result = end - m.viewport.width
        }
        return min(max(result, 0), max(m.content - m.viewport.width, 0))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .mouseMoved,
                                                 .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = tracking.firstIndex { $0.contains(point) }
        guard index != hovered else { return }
        hovered = index
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    /// 鼠标停在页签上滚动＝翻页签。这颗条不在画布的响应链上，滚轮不会
    /// 掉进画布去缩放图纸。
    override func scrollWheel(with event: NSEvent) {
        let m = metrics()
        let limit = max(m.content - m.viewport.width, 0)
        guard limit > 0 else { return super.scrollWheel(with: event) }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX : event.scrollingDeltaY
        scroll = min(max(scroll - delta, 0), limit)
        needsDisplay = true
    }

    func configure(_ names: [String], selected: Int) {
        let incoming = names.isEmpty ? ["模型"] : names
        if incoming != tabs {
            tabs = incoming
            scroll = 0
        }
        self.selected = selected
        pendingReveal = true
        invalidateIntrinsicContentSize()
        needsDisplay = true
        // 名字仍然可能被 260 这个上限截断时，提示里放全名兜底。
        toolTip = tabs.count > 1
            ? "模型与布局（滚轮可翻页签）：\n" + tabs.enumerated()
                .map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            : tabs.first
    }

    /// 自测用：哪些标签会被截成省略号。模型和当前布局不该出现在里面。
    func debugTruncatedNames() -> [String] {
        let m = metrics()
        return tabs.indices.compactMap { index in
            let font = NSFont.systemFont(ofSize: 11, weight: index == selected ? .semibold : .regular)
            let shown = truncated(tabs[index], font: font, maxWidth: m.widths[index] - textPad)
            return shown == tabs[index] ? nil : tabs[index]
        }
    }

    func select(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }
        if selected != index { pendingReveal = true }
        selected = index
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for (index, rect) in tracking.enumerated() where rect.contains(point) {
            selected = index
            needsDisplay = true
            onSelect?(index)
            return
        }
    }
}

// MARK: - Sidebar tabs

/// 侧栏顶部的两段式切换（图层 / 标注）。
///
/// 不用 `NSSegmentedControl` 的原因：在深色材质上系统控件把两段都画成凸起的
/// 胶囊，选中态只亮一点点，一眼看不出当前在哪一页——截图里"图层"和"标注"看着
/// 像两个都被选中。自绘一个：凹槽容器 + 一块会滑动的白色药丸，选中/未选中是
/// 两种明确的形态，切换时用 `Motion.standard` 的弹簧曲线滑过去。
final class CADSidebarTabs: NSView, ThemeAware {

    var onSelect: ((Int) -> Void)?
    private(set) var selectedIndex = 0

    private var titles: [String] = []
    private var labels: [NSTextField] = []
    private var hover: Int?
    private var trackingArea: NSTrackingArea?
    private let pill = NSView()
    private var lastSize: NSSize = .zero

    private let inset: CGFloat = 3
    private let gap: CGFloat = 2

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true

        pill.wantsLayer = true
        pill.layer?.cornerRadius = Glass.Radius.pill
        pill.layer?.cornerCurve = .continuous
        // 浅色下选中的是"一张更白的纸"，深色下是"一块被点亮的面板"。
        pill.layer?.backgroundColor = (Theme.isDark ? NSColor(white: 1, alpha: 0.20)
            : NSColor(white: 1, alpha: 0.96)).cgColor
        pill.layer?.shadowColor = NSColor.black.cgColor
        pill.layer?.shadowOpacity = Theme.isDark ? 0.28 : 0.10
        pill.layer?.shadowRadius = 2
        pill.layer?.shadowOffset = CGSize(width: 0, height: -1)
        addSubview(pill)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: 200, height: 30) }

    override func layout() {
        super.layout()
        for (index, label) in labels.enumerated() {
            let rect = segmentRect(index)
            label.frame = CGRect(x: rect.minX, y: (bounds.height - 16) / 2,
                                 width: rect.width, height: 16)
        }
        // 只在尺寸真的变了时对齐药丸，否则会把正在滑动的动画拽回原位。
        if bounds.size != lastSize {
            lastSize = bounds.size
            pill.frame = segmentRect(selectedIndex)
        }
    }

    private func segmentRect(_ index: Int) -> CGRect {
        guard !titles.isEmpty else { return .zero }
        let total = bounds.width - inset * 2 - gap * CGFloat(titles.count - 1)
        let width = total / CGFloat(titles.count)
        let x = inset + CGFloat(index) * (width + gap)
        return CGRect(x: x, y: inset, width: width, height: bounds.height - inset * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        Glass.draw(in: bounds, radius: Glass.Radius.control,
                   tone: .sunken, flipped: isFlipped)

        // hover 只给未选中的那一格，选中的已经有一块药丸了。
        if let hover, hover != selectedIndex {
            Glass.hover.setFill()
            NSBezierPath(roundedRect: segmentRect(hover).insetBy(dx: 1, dy: 1),
                         xRadius: Glass.Radius.pill, yRadius: Glass.Radius.pill).fill()
        }
    }

    // MARK: API

    func configure(_ titles: [String], selected: Int) {
        if self.titles != titles {
            self.titles = titles
            labels.forEach { $0.removeFromSuperview() }
            labels = titles.map { title in
                let label = NSTextField(labelWithString: title)
                label.alignment = .center
                label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
                label.isSelectable = false   // 点击交给容器处理
                addSubview(label)
                return label
            }
            needsLayout = true
        }
        select(selected, animated: false)
    }

    func setTitle(_ title: String, for index: Int) {
        guard index >= 0, index < titles.count, titles[index] != title else { return }
        titles[index] = title
        labels[index].stringValue = title
    }

    func select(_ index: Int, animated: Bool = true) {
        guard index >= 0, index < labels.count else { return }
        let moved = index != selectedIndex
        selectedIndex = index
        for (offset, label) in labels.enumerated() {
            let active = offset == index
            label.textColor = active ? .labelColor : .secondaryLabelColor
            label.font = NSFont.systemFont(ofSize: 12, weight: active ? .semibold : .medium)
        }
        if moved { movePill(animated: animated) }
        needsDisplay = true
    }

    /// 选中药丸的颜色是缓存进 layer 的，换主题必须重取一次。
    func themeDidChange() {
        pill.layer?.backgroundColor = (Theme.isDark ? NSColor(white: 1, alpha: 0.20)
            : NSColor(white: 1, alpha: 0.96)).cgColor
        pill.layer?.shadowOpacity = Theme.isDark ? 0.28 : 0.10
        needsDisplay = true
    }

    private func movePill(animated: Bool) {
        let target = segmentRect(selectedIndex)
        guard animated, window != nil else {
            pill.frame = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Motion.standard
            context.timingFunction = Theme.Motion.springCurve
            context.allowsImplicitAnimation = true
            pill.animator().frame = target
        }
    }

    // MARK: Input

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .mouseMoved,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = (0..<titles.count).first { segmentRect($0).contains(point) }
        if index != hover {
            hover = index
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = (0..<titles.count).first(where: { segmentRect($0).contains(point) }),
              index != selectedIndex else { return }
        select(index)
        onSelect?(index)
    }
}

// MARK: - Document tabs

/// 图纸页签：一行装下所有打开的图纸，点击切换，× 关闭，末尾 + 再开一张。
///
/// 多图纸是这个应用的常态（平面、立面、旧版参照同时开着），所以页签不是装饰：
/// 它要在 56pt 的工具岛里活下去。空间不够时不硬挤——能放几张放几张，剩下的
/// 收进右侧的图纸清单（带条数），当前这张永远在可见范围里。
final class CADDocumentTabs: NSView {

    struct Item {
        let title: String
        let tooltip: String
        /// 标注条数，画在名字后面当提示：切过去就知道那张图上有没有东西。
        let badge: Int
    }

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?

    private var items: [Item] = []
    private var active = 0
    private var tabRects: [(index: Int, rect: CGRect)] = []
    private var closeRects: [Int: CGRect] = [:]
    private var newRect = CGRect.zero
    private var listRect = CGRect.zero
    private var hoverIndex: Int?
    private var hoverCloseIndex: Int?
    private var hoverNew = false
    private var hoverList = false
    private var tracking: NSTrackingArea?
    private let barHeight: CGFloat = 32

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: barHeight).isActive = true
        // 工具岛已经是玻璃了，页签自己不再铺底：两层半透明叠在一起会发灰。
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    private var font: NSFont { NSFont.systemFont(ofSize: 11, weight: .medium) }

    func configure(_ items: [Item], active: Int) {
        self.items = items
        self.active = max(0, min(active, max(items.count - 1, 0)))
        needsDisplay = true
        layoutTabs()
        hoverIndex = nil
        removeAllToolTips()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = tabRects.first { $0.rect.contains(point) }?.index
        let overClose = closeRects.first { $0.value.contains(point) }?.key
        let overNew = newRect.contains(point)
        let overList = listRect.contains(point)
        if overClose != hoverCloseIndex || index != hoverIndex
            || overNew != hoverNew || overList != hoverList {
            hoverCloseIndex = overClose
            hoverIndex = index
            hoverNew = overNew
            hoverList = overList
            // tooltip 跟着鼠标走：整条标签栏共用一个，指向谁就显示谁的路径。
            removeAllToolTips()
            toolTip = index.flatMap { $0 < items.count ? items[$0].tooltip : nil }
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverCloseIndex = nil
        hoverIndex = nil
        hoverNew = false
        hoverList = false
        removeAllToolTips()
        toolTip = nil
        needsDisplay = true
    }

    // MARK: Layout

    /// 可见页签 + 每个的宽度。窗口越窄，页签越少；当前页签始终留在可见段里。
    private func layoutTabs() {
        tabRects = []
        closeRects = [:]
        let closeWidth: CGFloat = 18
        let padding: CGFloat = 11
        let plusWidth: CGFloat = 24
        let listWidth: CGFloat = items.count > 1 ? 30 : 0
        let minWidth: CGFloat = 92
        let available = max(bounds.width - plusWidth - listWidth - 6, minWidth)

        newRect = CGRect(x: bounds.width - plusWidth, y: (barHeight - 24) / 2,
                         width: plusWidth, height: 24)
        listRect = listWidth > 0
            ? CGRect(x: newRect.minX - listWidth, y: (barHeight - 24) / 2,
                     width: listWidth - 2, height: 24)
            : .zero

        guard !items.isEmpty else { return }
        let capacity = max(1, Int(available / (minWidth + 2)))
        let start: Int
        if items.count <= capacity {
            start = 0
        } else {
            // 当前这张必须看得见：可见窗口以它为准往左推。
            start = min(max(0, active - capacity + 1), max(items.count - capacity, 0))
        }
        let end = min(items.count, start + capacity)

        var widths: [CGFloat] = (start..<end).map { index in
            let item = items[index]
            let text = (item.title as NSString).size(withAttributes: [.font: font]).width
            let badge: CGFloat = item.badge > 0 ? 20 : 0
            return min(max(text + padding * 2 + closeWidth + badge, minWidth), 208)
        }
        var total = widths.reduce(0, +)
        if total > available {
            let scale = available / total
            widths = widths.map { max(72, $0 * scale) }
            total = widths.reduce(0, +)
            var guardCount = 0
            while total > available, guardCount < 200,
                  widths.contains(where: { $0 > 64 }) {
                for index in widths.indices where widths[index] > 64 {
                    widths[index] -= 2
                    total -= 2
                    if total <= available { break }
                }
                guardCount += 1
            }
        }

        // 靠右排：页签紧挨着「+」和图纸清单，读起来是"这窗口里开着哪几张"，
        // 而不是漂在工具岛中间的一颗孤岛。
        var x: CGFloat = max(bounds.width - listWidth - plusWidth - 6
                             - (total + CGFloat(max(widths.count - 1, 0)) * 2), 0)
        for (offset, width) in widths.enumerated() {
            let rect = CGRect(x: x, y: 2, width: width, height: barHeight - 4)
            tabRects.append((start + offset, rect))
            // 收得很窄时把 × 去掉，保住文件名。
            if width >= 84 {
                closeRects[start + offset] = CGRect(x: rect.maxX - 18, y: rect.midY - 7,
                                                    width: 14, height: 14)
            }
            x += width + 2
        }
    }

    override func layout() {
        super.layout()
        layoutTabs()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        layoutTabs()

        for entry in tabRects {
            let index = entry.index
            let rect = entry.rect
            guard index < items.count else { continue }
            let item = items[index]
            let isActive = index == active
            let isHover = index == hoverIndex

            if isActive {
                Glass.draw(in: rect, radius: Glass.Radius.pill,
                           tone: .regular, flipped: isFlipped)
                NSColor(white: 1, alpha: Glass.isDark ? 0.12 : 0.55).setFill()
                NSBezierPath(roundedRect: rect, xRadius: Glass.Radius.pill,
                             yRadius: Glass.Radius.pill).fill()
            } else if isHover {
                NSColor(white: 1, alpha: Glass.isDark ? 0.09 : 0.42).setFill()
                NSBezierPath(roundedRect: rect, xRadius: Glass.Radius.pill,
                             yRadius: Glass.Radius.pill).fill()
            }

            let textRect = rect.insetBy(dx: 11, dy: 0)
            let badgeWidth: CGFloat = item.badge > 0 ? 20 : 0
            let closeWidth: CGFloat = closeRects[index] != nil ? 16 : 0
            let titleWidth = textRect.width - badgeWidth - closeWidth
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: isActive ? Glass.primaryText : Glass.secondaryText,
            ]
            let title = elide(item.title, width: max(titleWidth, 24))
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(at: NSPoint(x: textRect.minX,
                                                 y: rect.midY - size.height / 2),
                                     withAttributes: attributes)

            if item.badge > 0 {
                let text = "\(item.badge)"
                let badgeFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
                let badgeSize = (text as NSString).size(withAttributes: [.font: badgeFont])
                let chip = CGRect(x: textRect.maxX - badgeWidth - closeWidth + 3,
                                  y: rect.midY - 6.5,
                                  width: badgeSize.width + 8, height: 13)
                (isActive ? Theme.accent : Glass.secondaryText)
                    .withAlphaComponent(0.20).setFill()
                NSBezierPath(roundedRect: chip, xRadius: 6.5, yRadius: 6.5).fill()
                (text as NSString).draw(
                    at: NSPoint(x: chip.midX - badgeSize.width / 2,
                                y: chip.midY - badgeSize.height / 2),
                    withAttributes: [.font: badgeFont,
                                     .foregroundColor: isActive
                                        ? Glass.primaryText : Glass.secondaryText])
            }

            // × 只在当前标签或鼠标所在标签上出现：一排五个 × 会让整条标签栏
            // 看着像"随时会被关掉"，而真正要关的时候它就在手边。
            if let close = closeRects[index], isActive || isHover {
                if hoverCloseIndex == index {
                    NSColor(white: 1, alpha: Glass.isDark ? 0.18 : 0.7).setFill()
                    NSBezierPath(ovalIn: close.insetBy(dx: -2, dy: -2)).fill()
                    drawClose(at: close, color: Glass.primaryText)
                } else {
                    drawClose(at: close, color: isActive ? Glass.secondaryText
                                                         : Glass.tertiaryText)
                }
            }
        }

        // 图纸清单：多到装不下时，这里是"还有哪几张"的出口。
        if listRect.width > 0 {
            if hoverList {
                NSColor(white: 1, alpha: Glass.isDark ? 0.12 : 0.45).setFill()
                NSBezierPath(roundedRect: listRect, xRadius: Glass.Radius.pill,
                             yRadius: Glass.Radius.pill).fill()
            }
            drawChevron(at: listRect, color: hoverList ? Glass.primaryText : Glass.secondaryText)
        }

        // 末尾的“再开一张”。
        if hoverNew {
            NSColor(white: 1, alpha: Glass.isDark ? 0.12 : 0.45).setFill()
            NSBezierPath(roundedRect: newRect, xRadius: Glass.Radius.pill,
                         yRadius: Glass.Radius.pill).fill()
        }
        drawPlus(at: newRect, color: hoverNew ? Glass.primaryText : Glass.secondaryText)
    }

    private func drawPlus(at rect: CGRect, color: NSColor) {
        color.setStroke()
        let line = NSBezierPath()
        line.lineWidth = 1.4
        line.lineCapStyle = .round
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        line.move(to: CGPoint(x: centre.x - 5, y: centre.y))
        line.line(to: CGPoint(x: centre.x + 5, y: centre.y))
        line.move(to: CGPoint(x: centre.x, y: centre.y - 5))
        line.line(to: CGPoint(x: centre.x, y: centre.y + 5))
        line.stroke()
    }

    private func drawChevron(at rect: CGRect, color: NSColor) {
        color.setStroke()
        let line = NSBezierPath()
        line.lineWidth = 1.5
        line.lineCapStyle = .round
        line.lineJoinStyle = .round
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        line.move(to: CGPoint(x: centre.x - 4.5, y: centre.y - 2))
        line.line(to: CGPoint(x: centre.x, y: centre.y + 2.5))
        line.line(to: CGPoint(x: centre.x + 4.5, y: centre.y - 2))
        line.stroke()
    }

    private func drawClose(at rect: CGRect, color: NSColor) {
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.3
        path.lineCapStyle = .round
        let inset: CGFloat = 4.0
        path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY + inset))
        path.line(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        path.move(to: CGPoint(x: rect.maxX - inset, y: rect.minY + inset))
        path.line(to: CGPoint(x: rect.minX + inset, y: rect.maxY - inset))
        path.stroke()
    }

    private func elide(_ text: String, width: CGFloat) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        if (text as NSString).size(withAttributes: attributes).width <= width { return text }
        var head = text
        var tail = ""
        while head.count > 1 {
            let removed = head.removeLast()
            tail = String(removed) + tail
            if tail.count > 8 { tail.removeFirst() }
            let candidate = head + "…" + tail
            if (candidate as NSString).size(withAttributes: attributes).width <= width {
                return candidate
            }
        }
        return "…"
    }

    // MARK: Interaction

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if newRect.contains(point) { onNew?(); return }
        if listRect.width > 0, listRect.contains(point) {
            showAllDocuments(at: point)
            return
        }
        for (index, close) in closeRects where close.contains(point) {
            onClose?(index)
            return
        }
        if let entry = tabRects.first(where: { $0.rect.contains(point) }) {
            if entry.index != active { active = entry.index; needsDisplay = true }
            onSelect?(entry.index)
        }
    }

    /// 多图纸时的总览：菜单里列全，当前那张打勾。页签装不下的那几张，
    /// 以及"我刚才是不是关了另一张"的确认，都从这里走。
    private func showAllDocuments(at point: CGPoint) {
        guard !items.isEmpty else { return }
        let menu = NSMenu()
        for (index, item) in items.enumerated() {
            let entry = NSMenuItem(title: item.title, action: #selector(pickDocument(_:)),
                                   keyEquivalent: "")
            entry.target = self
            entry.tag = index
            entry.state = index == active ? .on : .off
            entry.toolTip = item.tooltip
            menu.addItem(entry)
        }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: point.x, y: point.y + 4), in: self)
    }

    @objc private func pickDocument(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < items.count else { return }
        active = sender.tag
        needsDisplay = true
        onSelect?(sender.tag)
    }

    /// 中键关闭：浏览器和编辑器里都是这个手势，看图的人按一下就少一张。
    override func otherMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let entry = tabRects.first(where: { $0.rect.contains(point) }) {
            onClose?(entry.index)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let entry = tabRects.first(where: { $0.rect.contains(point) }) else { return }
        let index = entry.index
        let menu = NSMenu()
        let close = NSMenuItem(title: "关闭 \(items[index].title)",
                               action: #selector(menuClose(_:)), keyEquivalent: "")
        close.target = self
        close.tag = index
        menu.addItem(close)
        let others = NSMenuItem(title: "关闭其他图纸",
                                action: #selector(menuCloseOthers(_:)), keyEquivalent: "")
        others.target = self
        others.tag = index
        others.isEnabled = items.count > 1
        menu.addItem(others)
        let reveal = NSMenuItem(title: "在访达中显示",
                                action: #selector(menuReveal(_:)), keyEquivalent: "")
        reveal.target = self
        reveal.tag = index
        menu.addItem(reveal)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func menuClose(_ sender: NSMenuItem) { onClose?(sender.tag) }

    @objc private func menuCloseOthers(_ sender: NSMenuItem) {
        let keep = sender.tag
        for index in stride(from: items.count - 1, through: 0, by: -1) where index != keep {
            onClose?(index)
        }
    }

    @objc private func menuReveal(_ sender: NSMenuItem) {
        guard let url = delegateURL?(sender.tag) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 由主窗口提供，供右键"在访达中显示"用。
    var delegateURL: ((Int) -> URL?)?
}
