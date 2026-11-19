import AppKit

/// 使用说明窗口。
///
/// 写成窗口而不是弹一个 NSAlert：说明有八节，塞进一个居中的提示框里既读不完
/// 也记不住。窗口可以一直开着对照操作。形态是一张玻璃卡片：左栏八节，右侧
/// 正文——原来那种滚动大白页在深色画布旁边像一块广告牌。
final class HelpWindowController: NSWindowController {

    static let shared = HelpWindowController()

    private struct Section {
        let title: String
        let rows: [(String, String)]
        let tools: Bool
        init(_ title: String, _ rows: [(String, String)], tools: Bool = false) {
            self.title = title
            self.rows = rows
            self.tools = tools
        }
    }

    private let card = GlassPanel(radius: Glass.Radius.panel)
    private let nav = NSStackView()
    private let scroll = NSScrollView()
    private let docView = FlippedView()
    private let stack = NSStackView()
    private var navButtons: [HelpNavButton] = []
    private var current = 0

    private static let sections: [Section] = [
        Section("快速开始", [
            ("⌘O / 拖入", "打开 DWG 或 DXF。同目录的外部参照会自动合并；缺失的参照在命令行提示。"),
            ("多张图纸", "顶部玻璃岛里每个页签是一份图纸，各自带相机、选中项和标注；⌘W 关闭当前，⌃⇥ 换下一张，页签右侧的 ⌄ 是全部图纸清单。"),
            ("模型与布局", "底部左侧的胶囊切换模型空间与各布局。切布局等于换一张显示列表，标注按空间分别保存。"),
            ("缩放平移", "滚轮缩放、按住拖动平移、⌘0 全图、Z 窗口缩放（两点框选）。"),
        ]),
        Section("测量长度与面积", [
            ("启动工具", "左侧工具竖排或命令行都能启动；多点工具（连续、多边形、侧面积）用右键或回车结束，Esc 取消。"),
            ("对齐 / 线性", "点两点后再移动光标定尺寸线位置，点击放置；回车用默认位置。和 CAD 的 DIMALIGNED / DIMLINEAR 一致。"),
            ("快速标注 QDIM", "框选线段、圆弧或圆，先预览这批尺寸；点击或回车放置，Esc 取消。"),
            ("画完即退出", "一条标注落定后工具自动退出；直接按回车/空格可重复上一个测量工具，不用回工具条。"),
            ("面积", "矩形、多边形、圆面积、填充都标两行：S = 面积，C = 周长；多行左对齐。"),
            ("侧面积", "多点量一段折线当墙长，再输入高度，得到 S侧 = 长 × 高。"),
        ]),
        Section("对象捕捉", [
            ("F3 总开关", "状态栏「捕捉」胶囊或视图 ▸ 对象捕捉；右键那颗胶囊可以逐项勾选。"),
            ("捕捉点", "端点、中点、圆心、交点、垂足、切点、最近点。图纸自带的标注墨迹（斜线端点、定义点）不参与捕捉。"),
            ("Tab 切换", "密集图里几个捕捉点重叠时，按 Tab 在候选之间循环；命令行会显示当前捕捉类型。"),
            ("正交", "F8 只走水平与竖直；栅格 F7。"),
        ]),
        Section("标注样式", [
            ("样式", "右侧面板「标注」页签顶部选样式：建筑斜线、标准箭头、机械窄箭头等；旁边的色块改墨色。"),
            ("尺寸线端符", "设置 ▸ 标注 ▸ 尺寸线端符：箭头或建筑 45° 短斜线，独立于样式。"),
            ("字号", "标注文字高度跟随图纸自带的尺寸文字，在图上和原标注一样大。"),
            ("编辑", "拖动文字移动位置；双击改文字（留空恢复实测值）；Delete 删除；删除工具可以拖框批量删。"),
            ("合计", "标注页签底部统计长度合计与面积合计，只算显示中的标注。"),
        ]),
        Section("图层", [
            ("图层面板", "右侧「图层」页签：勾选控制显示，关掉的图层不参与捕捉。"),
            ("全部显示 / 隐藏", "面板底部两颗按钮一次切换整张图。"),
        ]),
        Section("打印与导出", [
            ("选区打印 ⌘P", "点两个对角点框出一块范围，随即打开预览：纸张自动挑能容下的规格，可改方向、比例、颜色、分辨率、份数。"),
            ("打印图纸 ⌥⌘P", "把布局里的每个视口按图框逐页排进预览，一页一张。"),
            ("输出", "预览底部「打印」到打印机，或「打印到 PDF」存文件。"),
        ]),
        Section("比例校准", [
            ("CAL", "图上没有可靠尺寸时：点两个点，输入这段的实际长度，之后所有测量按新比例换算。"),
        ]),
        Section("快捷键", [
            ("命令", "AL 对齐 · DLI 线性 · DCO 连续 · QDIM 快速标注 · REC 矩形 · AA 多边形 · CA 圆面积 · HA 填充 · DRA 半径 · DAN 角度 · DAR 弧长 · T 注释"),
            ("视图", "Z 窗口缩放 · E 全图 · P 平移 · LA 图层 · U 撤销"),
            ("按键", "⌘Z 撤销 · ⇧⌘Z 重做 · ⌘0 全图 · ⌘L 线宽 · F3 捕捉 · F7 栅格 · F8 正交 · ⌘P 打印 · ⌘, 设置 · Esc 取消"),
        ]),
        Section("支持作者", [
            ("完全免费", "速看CAD 是 GPL-3.0 开源软件：没有广告、没有功能锁、没有“捐赠版”。"),
            ("为什么放二维码", "维护、适配新图纸格式和修 bug 需要时间；如果它帮你省了时间，可以自愿请作者喝杯咖啡。"),
            ("不影响功能", "不打赏也永远可以使用全部功能；这个页面只是留一个自愿支持的入口。"),
        ]),
    ]

    private init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                            styleMask: [.titled, .closable, .resizable],
                            backing: .buffered, defer: false)
        panel.title = "使用说明 · 速看CAD"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 680, height: 440)
        super.init(window: panel)
        build()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged),
            name: .cadLensThemeChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(section: Int? = nil) {
        // 每次打开都回到 820×560：上一次被拉成什么样，说明窗口不该记住它。
        window?.setContentSize(NSSize(width: 820, height: 560))
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if let section { select(section) }
    }

    @objc private func themeChanged() {
        window?.contentView?.applyThemeRecursively()
        for button in navButtons { button.needsDisplay = true }
    }

    // MARK: 内容

    private func build() {
        guard let window else { return }
        // 不要把 root 设成 `window.contentView`：换成 autolayout 内容视图后，
        // 窗口会按 `fittingSize` 反推自己的尺寸。右栏是滚动视图（fitting 宽度
        // 为 0），整窗会被压成 171pt 宽的一条，只剩左栏——截图 390×1120 就是
        // 这么来的。作为子视图铺满既有 contentView，窗口尺寸就由建窗时决定。
        let root = NSView(frame: window.contentView?.bounds
            ?? NSRect(x: 0, y: 0, width: 820, height: 560))
        root.autoresizingMask = [.width, .height]
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.chromeSunken.cgColor
        root.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            card.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            // 最小尺寸必须是硬约束：`NSWindow` 会把内容视图的 `fittingSize`
            // 当成自己的尺寸，而右栏是滚动视图（宽度 fitting 为 0），整窗
            // 会被压成 171pt 宽——只剩左边八节导航，正文一个字都看不到。
            // 给一个下限而不是定值，窗口仍然可以往大拉。
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 796),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 536),
        ])

        // 左栏：八节
        let rail = NSView()
        rail.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(rail)

        let heading = NSTextField(labelWithString: "使用说明")
        heading.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        heading.textColor = Glass.primaryText
        heading.translatesAutoresizingMaskIntoConstraints = false
        rail.addSubview(heading)

        nav.orientation = .vertical
        nav.alignment = .leading
        nav.spacing = 2
        nav.translatesAutoresizingMaskIntoConstraints = false
        rail.addSubview(nav)
        for (index, section) in Self.sections.enumerated() {
            let button = HelpNavButton(title: section.title)
            button.onSelect = { [weak self] in self?.select(index) }
            navButtons.append(button)
            nav.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: 146).isActive = true
        }

        let rule = GlassSeparator()
        card.addSubview(rule)

        // 右侧正文
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(scroll)
        scroll.documentView = docView
        // 文档视图必须交给自动布局：默认 translates=true 时 NSScrollView 按
        // 它的 frame 摆放，而新建的 frame 是 0×0——正文整块被压成零高度，
        // 右栏看起来就是一片空白。高度由内容（stack）撑出来，不钉到 clip view
        // 的底边，否则永远滚不动。
        docView.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(stack)

        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            rail.topAnchor.constraint(equalTo: card.topAnchor),
            rail.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            rail.widthAnchor.constraint(equalToConstant: 170),

            heading.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: 18),
            heading.topAnchor.constraint(equalTo: rail.topAnchor, constant: 16),
            nav.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: 10),
            nav.trailingAnchor.constraint(equalTo: rail.trailingAnchor, constant: -10),
            nav.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),

            rule.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            rule.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            rule.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            rule.widthAnchor.constraint(equalToConstant: 1),

            scroll.leadingAnchor.constraint(equalTo: rule.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: card.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            docView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            docView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            docView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),

            stack.leadingAnchor.constraint(equalTo: docView.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: docView.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: docView.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: docView.bottomAnchor, constant: -18),
        ])
        // 正文也别被压成逐字折行：给它一个期望宽度（同样低优先级）。
        let preferredWidth = stack.widthAnchor.constraint(equalToConstant: 581)
        preferredWidth.priority = .defaultLow
        preferredWidth.isActive = true

        // 走 contentViewController：窗口尺寸取 `preferredContentSize`，不再
        // 每次排版都按 `fittingSize` 反推（那条路会把整窗压成一条）。
        let host = NSViewController()
        host.view = root
        host.preferredContentSize = NSSize(width: 820, height: 560)
        window.contentViewController = host
        window.setContentSize(NSSize(width: 820, height: 560))
        window.center()
        if ProcessInfo.processInfo.environment["CADLENS_HELP_LOG"] != nil {
            print("[help] 建窗后 window=\(window.frame) content=\(window.contentView?.frame ?? .zero) root=\(root.frame)")
        }
        select(0)
    }

    private func select(_ index: Int) {
        guard index >= 0, index < Self.sections.count else { return }
        current = index
        for (offset, button) in navButtons.enumerated() {
            button.isActive = offset == index
        }
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let section = Self.sections[index]

        let title = NSTextField(labelWithString: section.title)
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        title.textColor = Glass.primaryText
        stack.addArrangedSubview(title)

        if section.tools {
            stack.addArrangedSubview(toolTable())
        }
        for (key, detail) in section.rows {
            stack.addArrangedSubview(row(key, detail))
        }
        if section.title == "支持作者" {
            stack.addArrangedSubview(supportCard())
        }
        stack.superview?.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// 赞赏码：只在“支持作者”页出现，启动/工具栏/画布都不弹。
    /// 整张图保留白色静区，缩放到 300 pt 仍然可以扫；文字另写在下方，
    /// 避免小窗口里二维码自带的小字看不清。
    private func supportCard() -> NSView {
        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .centerX
        box.spacing = 8

        if let url = Bundle.main.url(forResource: "wechat-reward", withExtension: "jpg",
                                     subdirectory: "Donate"),
           let image = NSImage(contentsOf: url) {
            let view = NSImageView()
            view.image = image
            view.imageScaling = .scaleProportionallyUpOrDown
            view.wantsLayer = true
            view.layer?.cornerRadius = 14
            view.layer?.masksToBounds = true
            view.layer?.borderWidth = 1
            view.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 300).isActive = true
            view.heightAnchor.constraint(equalToConstant: 300).isActive = true
            box.addArrangedSubview(view)
        }

        let title = NSTextField(labelWithString: "微信扫码 · 请作者喝杯咖啡")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Glass.primaryText
        title.alignment = .center
        box.addArrangedSubview(title)

        let note = NSTextField(wrappingLabelWithString: "完全自愿，不打赏也永远可以用全部功能。")
        note.font = NSFont.systemFont(ofSize: 11.5)
        note.textColor = Glass.secondaryText
        note.alignment = .center
        note.maximumNumberOfLines = 0
        note.preferredMaxLayoutWidth = 360
        box.addArrangedSubview(note)
        return box
    }

    /// 工具表：名称、别名、用途、需要几个点，全部从 `MeasureKind` 现取，
    /// 工具改了说明跟着改，不会停留在上一版的描述上。
    private func toolTable() -> NSView {
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 4
        grid.addArrangedSubview(line(["工具", "命令", "用途", "操作"], emphasis: true))
        for kind in MeasureKind.allCases {
            let points: String
            switch kind.requiredPoints {
            case 1: points = "点 1 处"
            case 2: points = "点 2 点"
            case 3: points = "点 3 点"
            default: points = "多点，右键结束"
            }
            grid.addArrangedSubview(line([kind.title,
                                          kind.aliases.first?.uppercased() ?? "—",
                                          kind.purpose, points]))
        }
        return grid
    }

    private func line(_ cells: [String], emphasis: Bool = false) -> NSView {
        let widths: [CGFloat] = [70, 62, 300, 130]
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        for (index, text) in cells.enumerated() {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = index == 0
                ? NSFont.systemFont(ofSize: 11.5, weight: emphasis ? .bold : .semibold)
                : NSFont.systemFont(ofSize: 11.5, weight: emphasis ? .bold : .regular)
            label.textColor = index == 1 ? Theme.accent
                : (emphasis ? Glass.secondaryText : Glass.primaryText)
            if index == 1 {
                label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
            }
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: widths[index]).isActive = true
            row.addArrangedSubview(label)
        }
        return row
    }

    /// 键 + 说明两栏：键用等宽字并对齐，说明可以折行。
    private func row(_ key: String, _ detail: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 14

        let keyLabel = NSTextField(wrappingLabelWithString: key)
        keyLabel.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)
        keyLabel.textColor = Theme.accent
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        keyLabel.widthAnchor.constraint(equalToConstant: 110).isActive = true

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = NSFont.systemFont(ofSize: 12)
        detailLabel.textColor = Glass.primaryText
        detailLabel.maximumNumberOfLines = 0
        detailLabel.preferredMaxLayoutWidth = 520

        row.addArrangedSubview(keyLabel)
        row.addArrangedSubview(detailLabel)
        return row
    }
}

private final class HelpNavButton: NSView {
    var onSelect: (() -> Void)?
    var isActive = false { didSet { needsDisplay = true } }
    private let title: String
    private var hovering = false { didSet { needsDisplay = true } }

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if isActive {
            Glass.draw(in: bounds, radius: Glass.Radius.pill,
                       tone: .accent, flipped: isFlipped)
        } else if hovering {
            Glass.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: Glass.Radius.pill,
                         yRadius: Glass.Radius.pill).fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: isActive ? .semibold : .regular),
            .foregroundColor: isActive ? NSColor.white : Glass.primaryText,
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: 10, y: (bounds.height - size.height) / 2),
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

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onSelect?() }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
