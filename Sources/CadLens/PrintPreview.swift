import AppKit

/// 一页打印内容：在哪个空间里、打哪块矩形。
///
/// 选区打印给一页（当前空间 + 框选的世界矩形），按图框打印给多页（每个布局
/// 视口一页）。两种入口最后都进同一个预览窗口、同一套设置。
struct PrintPage {
    var space: Int32
    /// 世界/纸面坐标下要打印的范围。
    var rect: CGRect
    var title: String
}

final class PrintSession {
    var pages: [PrintPage] = []
    var setup = PrintSetup()
    var copies = 1
    /// 打印分辨率（DPI），只影响位图预览与"打印到图片"的清晰度；矢量打印不受限。
    var resolution = 600
    var ruler = false
    var currentPage = 0
    var documentName = ""
}

/// 打印预览窗口。
///
/// 左边是连续页面预览（滚轮翻页、⌘+滚轮缩放、可拖拽平移），右边是设置。
/// 与参考项目一致：一页就是一张纸，页与页之间留白+投影，像摊在桌面上的
/// 一叠图——先确认"打出来是什么样"，再决定用哪台打印机。
final class PrintWindowController: NSWindowController {

    private let canvas: CanvasView
    private let session: PrintSession
    private let pagesView = PrintPagesView()
    private let scrollView = NSScrollView()

    private let pagePopup = NSPopUpButton()
    private let removePageButton = NSButton()
    private let addPageButton = NSButton()
    private let addFramesButton = NSButton()
    private let printerPopup = NSPopUpButton()
    private let paperPopup = NSPopUpButton()
    private let orientationPopup = NSPopUpButton()
    private let scalePopup = NSPopUpButton()
    private let inkPopup = NSPopUpButton()
    private let resolutionPopup = NSPopUpButton()
    private let copiesField = NSTextField()
    private let rulerSwitch = NSSwitch()
    private let infoLabel = NSTextField(labelWithString: "")
    private let pageStatusLabel = NSTextField(labelWithString: "")

    private var onAddPage: (() -> Void)?

    init(canvas: CanvasView, pages: [PrintPage], title: String,
         setup: PrintSetup? = nil) {
        self.canvas = canvas
        let session = PrintSession()
        session.pages = pages
        session.documentName = canvas.document?.fileName ?? ""
        session.setup = setup ?? PrintSetup()
        session.setup.unitMillimetres = CGFloat(canvas.document?.unitMeters ?? 0.001) * 1000
        // 框选/图框都是"这块内容要占一张纸"，默认适合纸张；需要固定 1:N 时再选。
        session.setup.scaleDenominator = 0
        session.setup.content = .view
        if setup == nil, let first = pages.first {
            // 按图框打印时，纸直接挑能容下这张图框的最小规格，省一次手选。
            let unit = session.setup.unitMillimetres
            session.setup.paper = PrintSetup.paperFitting(
                contentMM: CGSize(width: first.rect.width * unit,
                                  height: first.rect.height * unit))
        }
        self.session = session

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = title
        window.minSize = NSSize(width: 980, height: 680)
        super.init(window: window)
        buildUI()
        applySetup()
        reloadPages()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: UI

    private func buildUI() {
        guard let window else { return }
        let root = NSView()
        root.wantsLayer = true
        // 工作台底色：预览是"纸张放在桌面上"，桌面比纸沉一档。
        root.layer?.backgroundColor = Theme.chromeSunken.cgColor

        // ---- 左：连续页面预览 ----
        pagesView.canvas = canvas
        pagesView.session = session
        pagesView.onSelectPage = { [weak self] index in
            guard let self else { return }
            self.session.currentPage = index
            self.pagePopup.selectItem(at: index)
            self.updateStatus()
        }

        scrollView.documentView = pagesView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollDidMove),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)
        // 预览卡片宽度变了（窗口拉伸、设置面板展开），页面要重新贴合宽度，
        // 否则纸会一直按旧宽度缩放，左右两边被裁掉。
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipFrameChanged),
            name: NSView.frameDidChangeNotification,
            object: scrollView.contentView)

        let previewCard = GlassPanel(radius: Glass.Radius.panel)
        previewCard.addSubview(scrollView)

        let headerTitle = NSTextField(labelWithString: "打印预览")
        headerTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        pageStatusLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        pageStatusLabel.textColor = .secondaryLabelColor
        let hint = NSTextField(labelWithString: "滚轮翻页 · ⌘+滚轮缩放 · 拖拽平移")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let header = NSStackView(views: [headerTitle, pageStatusLabel, NSView(), hint])
        header.orientation = .horizontal
        header.spacing = 10
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false
        previewCard.addSubview(header)

        // ---- 右：设置 ----
        let panel = GlassPanel(radius: Glass.Radius.panel)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)

        stack.addArrangedSubview(section("页面"))
        pagePopup.target = self
        pagePopup.action = #selector(pageChanged)
        pagePopup.font = NSFont.systemFont(ofSize: 12)
        stack.addArrangedSubview(pagePopup)
        pagePopup.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        configure(removePageButton, title: "删除本页", action: #selector(removePage))
        configure(addPageButton, title: "＋ 框选添加一页", action: #selector(addPage))
        configure(addFramesButton, title: "⧉ 一键添加布局图框", action: #selector(addLayoutPages))
        let pageButtons = NSStackView(views: [removePageButton, addPageButton])
        pageButtons.orientation = .horizontal
        pageButtons.spacing = 8
        pageButtons.distribution = .fillEqually
        stack.addArrangedSubview(pageButtons)
        pageButtons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(addFramesButton)
        addFramesButton.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.addArrangedSubview(section("输出"))
        printerPopup.font = NSFont.systemFont(ofSize: 12)
        let defaultPrinter = NSPrintInfo.shared.printer
        let printerName = defaultPrinter.name ?? "系统默认打印机"
        printerPopup.addItem(withTitle: printerName)
        stack.addArrangedSubview(labeled("打印机", printerPopup))

        for popup in [paperPopup, orientationPopup, scalePopup, inkPopup, resolutionPopup] {
            popup.font = NSFont.systemFont(ofSize: 12)
            popup.target = self
            popup.action = #selector(changed)
        }
        paperPopup.addItems(withTitles: PrintSetup.Paper.allCases.map(\.title))
        orientationPopup.addItems(withTitles: PrintSetup.Orientation.allCases.map(\.title))
        scalePopup.addItems(withTitles: PrintSetup.scaleChoices.map {
            $0 == 0 ? "适合纸张" : "1:\($0)"
        })
        inkPopup.addItems(withTitles: ["黑白（所有元素为黑色）", "灰度", "彩色"])
        resolutionPopup.addItems(withTitles: ["低（600 DPI）", "中（1200 DPI）", "高（2400 DPI）"])

        stack.addArrangedSubview(labeled("纸张", paperPopup))
        stack.addArrangedSubview(labeled("方向", orientationPopup))
        stack.addArrangedSubview(labeled("比例", scalePopup))
        stack.addArrangedSubview(labeled("输出颜色", inkPopup))
        stack.addArrangedSubview(labeled("分辨率", resolutionPopup))

        copiesField.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        copiesField.alignment = .right
        copiesField.stringValue = "1"
        let copiesBox = NSBox()
        copiesBox.boxType = .custom
        copiesBox.borderWidth = 0
        copiesBox.fillColor = .clear
        copiesBox.translatesAutoresizingMaskIntoConstraints = false
        copiesBox.addSubview(copiesField)
        copiesField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            copiesField.leadingAnchor.constraint(equalTo: copiesBox.leadingAnchor),
            copiesField.trailingAnchor.constraint(equalTo: copiesBox.trailingAnchor),
            copiesField.topAnchor.constraint(equalTo: copiesBox.topAnchor),
            copiesField.bottomAnchor.constraint(equalTo: copiesBox.bottomAnchor),
            copiesField.heightAnchor.constraint(equalToConstant: 20),
        ])
        stack.addArrangedSubview(labeled("份数", copiesBox, width: 70))

        let rulerRow = NSStackView(views: [rulerSwitch, caption("显示打印标尺")])
        rulerRow.orientation = .horizontal
        rulerRow.spacing = 8
        rulerSwitch.target = self
        rulerSwitch.action = #selector(changed)
        stack.addArrangedSubview(rulerRow)

        infoLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byWordWrapping
        infoLabel.maximumNumberOfLines = 3
        stack.addArrangedSubview(infoLabel)
        infoLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // ---- 底部按钮 ----
        let pdfButton = NSButton(title: "打印到 PDF", target: self, action: #selector(printToPDF))
        pdfButton.bezelStyle = .rounded
        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closePanel))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        let printButton = NSButton(title: "打印", target: self, action: #selector(printNow))
        printButton.bezelStyle = .rounded
        printButton.keyEquivalent = "\r"

        let footer = NSStackView(views: [pdfButton, NSView(), closeButton, printButton])
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false

        for view in [previewCard, panel, footer] { root.addSubview(view) }

        NSLayoutConstraint.activate([
            previewCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            previewCard.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            previewCard.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            previewCard.trailingAnchor.constraint(equalTo: panel.leadingAnchor, constant: -14),

            header.leadingAnchor.constraint(equalTo: previewCard.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: previewCard.trailingAnchor, constant: -14),
            header.topAnchor.constraint(equalTo: previewCard.topAnchor, constant: 10),

            scrollView.leadingAnchor.constraint(equalTo: previewCard.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: previewCard.trailingAnchor, constant: -6),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: previewCard.bottomAnchor, constant: -6),

            panel.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            panel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            panel.widthAnchor.constraint(equalToConstant: 316),
            panel.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),

            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 16),

            footer.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            footer.heightAnchor.constraint(equalToConstant: 30),
        ])

        window.contentView = root
    }

    private func configure(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.font = NSFont.systemFont(ofSize: 11.5)
        button.target = self
        button.action = action
    }

    private func section(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func caption(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12)
        return label
    }

    private func labeled(_ title: String, _ control: NSView, width: CGFloat? = nil) -> NSView {
        let label = caption(title)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 62).isActive = true
        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        if let width {
            control.widthAnchor.constraint(equalToConstant: width).isActive = true
        } else {
            control.widthAnchor.constraint(equalToConstant: 180).isActive = true
        }
        return stack
    }

    // MARK: 页面

    private func applySetup() {
        paperPopup.selectItem(at: PrintSetup.Paper.allCases.firstIndex(of: session.setup.paper) ?? 1)
        orientationPopup.selectItem(at: PrintSetup.Orientation.allCases
            .firstIndex(of: session.setup.orientation) ?? 0)
        scalePopup.selectItem(at: PrintSetup.scaleChoices
            .firstIndex(of: session.setup.scaleDenominator) ?? 0)
        inkPopup.selectItem(at: PrintSetup.Ink.allCases.firstIndex(of: session.setup.ink) ?? 0)
        let resolutionIndex = session.resolution <= 600 ? 0 : (session.resolution <= 1200 ? 1 : 2)
        resolutionPopup.selectItem(at: resolutionIndex)
    }

    private func reloadPages() {
        pagePopup.removeAllItems()
        for (index, page) in session.pages.enumerated() {
            pagePopup.addItem(withTitle: "第 \(index + 1) 页 · \(page.title)")
        }
        let count = session.pages.count
        session.currentPage = min(max(0, session.currentPage), max(0, count - 1))
        if count > 0 { pagePopup.selectItem(at: session.currentPage) }
        removePageButton.isEnabled = count > 1
        addFramesButton.isEnabled = true
        pagesView.reload()
        updateStatus()
        pagesView.scrollToPage(session.currentPage)
    }

    /// 窗口刚上屏时滚动视图才有真实宽度，这时再贴合一次宽度，第一次打开
    /// 看到的就是整张纸，而不是被裁掉两边的纸。
    func refreshFit() {
        pagesView.contentSizeChanged()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func updateStatus() {
        let count = session.pages.count
        pageStatusLabel.stringValue = count > 0
            ? "第 \(session.currentPage + 1) / \(count) 页"
            : "没有页面"
        guard count > 0 else {
            infoLabel.stringValue = "还没有任何页面。用「框选添加一页」选一块要打印的范围。"
            return
        }
        let page = session.pages[min(session.currentPage, count - 1)]
        let world = page.rect
        let paper = session.setup.paperSizePoints(content: world)
        let printable = CGSize(
            width: paper.width - 20 * PrintSetup.pointsPerMillimetre,
            height: paper.height - 20 * PrintSetup.pointsPerMillimetre)
        let perUnit = session.setup.pointsPerWorldUnit(fitting: world, in: printable)
        let mm = session.setup.unitMillimetres
        let contentMM = CGSize(width: world.width * mm, height: world.height * mm)
        let paperMM = CGSize(
            width: paper.width / PrintSetup.pointsPerMillimetre,
            height: paper.height / PrintSetup.pointsPerMillimetre)
        let ratio = session.setup.unitMillimetres
            / max(perUnit / PrintSetup.pointsPerMillimetre, 1e-9)
        let scaleText = session.setup.scaleDenominator > 0
            ? session.setup.scaleTitle : String(format: "约 1:%.0f", ratio)
        infoLabel.stringValue = String(
            format: "%@ %@ · %@\n内容 %.0f × %.0fmm\n纸面 %.0f × %.0fmm",
            session.setup.paper.title, session.setup.orientation.title, scaleText,
            contentMM.width, contentMM.height, paperMM.width, paperMM.height)
    }

    @objc private func pageChanged() {
        session.currentPage = max(0, pagePopup.indexOfSelectedItem)
        pagesView.scrollToPage(session.currentPage)
        updateStatus()
    }

    @objc private func removePage() {
        guard session.pages.count > 1 else { return }
        session.pages.remove(at: min(session.currentPage, session.pages.count - 1))
        session.currentPage = min(session.currentPage, session.pages.count - 1)
        reloadPages()
    }

    @objc private func addPage() {
        // 回到主窗口框选：预览窗先收起来，选完再回来。
        let handler = onAddPage
        window?.orderOut(nil)
        handler?()
    }

    /// 由主窗口在框选完成后调用：追加一页再回到预览。
    func appendPage(_ page: PrintPage) {
        session.pages.append(page)
        session.currentPage = session.pages.count - 1
        window?.makeKeyAndOrderFront(nil)
        reloadPages()
    }

    func setAddPageHandler(_ handler: @escaping () -> Void) {
        onAddPage = handler
    }

    @objc private func addLayoutPages() {
        let pages = PrintPreviewBuilder.layoutPages(for: canvas)
        guard !pages.isEmpty else {
            NSSound.beep()
            infoLabel.stringValue = "这张图纸的布局里没有找到视口或图框。"
            return
        }
        session.pages.append(contentsOf: pages)
        session.currentPage = session.pages.count - pages.count
        reloadPages()
    }

    @objc private func changed() {
        session.setup.paper = PrintSetup.Paper.allCases[paperPopup.indexOfSelectedItem]
        session.setup.orientation =
            PrintSetup.Orientation.allCases[orientationPopup.indexOfSelectedItem]
        session.setup.scaleDenominator = PrintSetup.scaleChoices[scalePopup.indexOfSelectedItem]
        let inks = PrintSetup.Ink.allCases
        session.setup.ink = inks[min(inkPopup.indexOfSelectedItem, inks.count - 1)]
        session.resolution = [600, 1200, 2400][max(0, resolutionPopup.indexOfSelectedItem)]
        session.ruler = rulerSwitch.state == .on
        session.copies = max(1, min(99, Int(copiesField.stringValue) ?? 1))
        pagesView.reload()
        updateStatus()
    }

    @objc private func clipFrameChanged() {
        pagesView.contentSizeChanged()
    }

    @objc private func scrollDidMove() {
        let visible = pagesView.visiblePageIndex()
        guard visible >= 0, visible != session.currentPage else { return }
        session.currentPage = visible
        pagePopup.selectItem(at: visible)
        updateStatus()
    }

    // MARK: 输出

    @objc private func printNow() {
        guard let window, !session.pages.isEmpty else { return }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        session.setup.apply(to: info, worldRect: session.pages[0].rect)
        info.dictionary()[NSPrintInfo.AttributeKey.copies] = session.copies

        let printView = PrintVectorView(canvas: canvas, session: session)
        printView.frame = NSRect(
            x: 0, y: 0,
            width: max(info.paperSize.width - info.leftMargin - info.rightMargin, 1),
            height: max(info.paperSize.height - info.topMargin - info.bottomMargin, 1))
        let operation = NSPrintOperation(view: printView, printInfo: info)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    @objc private func printToPDF() {
        guard let window, !session.pages.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (session.documentName as NSString)
            .deletingPathExtension + ".pdf"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            PrintPreviewBuilder.writePDF(session: self.session, canvas: self.canvas, to: url)
        }
    }

    @objc private func closePanel() {
        window?.close()
    }
}

// MARK: - 预览画布

/// 连续页面：一页一张白纸，页间留白，纸下压一层淡影。
final class PrintPagesView: NSView {
    weak var canvas: CanvasView?
    var session: PrintSession?
    var onSelectPage: ((Int) -> Void)?

    private var images: [Int: CGImage] = [:]
    private var pageRects: [CGRect] = []
    /// 屏幕上 1 个纸面点对应多少视图点。纸张按 72dpi 的点算，A1 有 2384 点
    /// 宽，所以这个值通常只有零点几。
    private var zoom: CGFloat = 0.28
    private var didUserZoom = false
    /// 鼠标停在哪一页上。悬停时给一条细边＋抬起一点阴影，让人知道这一页
    /// 是可以点选的，而不是一张不能碰的图。
    private var hoveredPage: Int?

    override var isFlipped: Bool { true }

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
        let index = pageRects.firstIndex { $0.contains(point) }
        if index != hoveredPage {
            hoveredPage = index
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredPage != nil {
            hoveredPage = nil
            needsDisplay = true
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for rect in pageRects {
            addCursorRect(rect, cursor: .pointingHand)
        }
    }

    /// 纸张两侧各留的空白（视图点）。页面宽度 + 两倍余量正好等于可视宽度，
    /// 才不会因为多出这几像素而冒出横向滚动条、把纸的左右两边切掉。
    static let sideInset: CGFloat = 14

    func reload() {
        images.removeAll()
        if !didUserZoom { zoom = fitZoom() ?? zoom }
        buildLayout()
    }

    /// 让最宽的一页刚好填满可视宽度——打开预览先看到整张纸，再决定要不要放大。
    func fitWidth() {
        if let value = fitZoom() { zoom = value }
    }

    /// 可视宽度所允许的缩放。拿不到滚动视图（还没上屏）时返回 nil，此时保持
    /// 原缩放，等 layout 里再来一次。
    private func fitZoom() -> CGFloat? {
        guard let session, !session.pages.isEmpty else { return nil }
        let width = enclosingScrollView?.contentSize.width ?? bounds.width
        let available = width - Self.sideInset * 2
        let widest = session.pages.reduce(CGFloat(0)) { value, page in
            max(value, session.setup.paperSizePoints(content: page.rect).width)
        }
        guard widest > 1, available > 40 else { return nil }
        return min(max(available / widest, 0.06), 1.4)
    }

    /// 预览卡片或窗口尺寸变了，就重新贴合宽度。用户自己按过 ⌘+滚轮之后
    /// 不再插手——他放大到某处是有目的的，不能被一次窗口缩放打断。
    func contentSizeChanged() {
        guard !didUserZoom, let value = fitZoom(), abs(value - zoom) > 0.002 else { return }
        zoom = value
        buildLayout()
    }

    override func layout() {
        super.layout()
        contentSizeChanged()
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        didUserZoom = true
        let step = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY * 0.004 : event.scrollingDeltaY * 0.04
        setZoom(zoom * (1 + step))
    }

    private func buildLayout() {
        guard let session else { return }
        let gap: CGFloat = 26
        pageRects.removeAll()
        var y: CGFloat = gap
        var maxWidth: CGFloat = 0
        for page in session.pages {
            let paper = session.setup.paperSizePoints(content: page.rect)
            let size = CGSize(width: paper.width * zoom, height: paper.height * zoom)
            pageRects.append(CGRect(x: 0, y: y, width: size.width, height: size.height))
            maxWidth = max(maxWidth, size.width)
            y += size.height + gap
        }
        // 居中：页宽一致时正好居中；宽度不一时统一左边线对齐更稳。
        let width = max(maxWidth + Self.sideInset * 2, 200)
        for index in pageRects.indices {
            pageRects[index].origin.x = (width - pageRects[index].width) / 2
        }
        frame = CGRect(x: 0, y: 0, width: width, height: max(y, 200))
        if ProcessInfo.processInfo.environment["CADLENS_PRINT_LOG"] != nil {
            print(String(format: "[printview] zoom=%.3f pages=%d frame=%.0fx%.0f first=%@",
                         zoom, pageRects.count, width, frame.height,
                         String(describing: pageRects.first ?? .zero)))
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    func setZoom(_ value: CGFloat) {
        let clamped = min(max(value, 0.18), 2.4)
        guard abs(clamped - zoom) > 0.001 else { return }
        zoom = clamped
        buildLayout()
    }

    func scrollToPage(_ index: Int) {
        guard pageRects.indices.contains(index) else { return }
        scroll(CGPoint(x: 0, y: max(0, pageRects[index].minY - 20)))
    }

    func visiblePageIndex() -> Int {
        guard let clip = enclosingScrollView?.contentView.bounds else { return 0 }
        var best = 0
        var bestOverlap: CGFloat = 0
        for (index, rect) in pageRects.enumerated() {
            let overlap = rect.intersection(clip)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestOverlap { bestOverlap = area; best = index }
        }
        return best
    }

    private func image(for index: Int) -> CGImage? {
        if let cached = images[index] { return cached }
        guard let session, let canvas, session.pages.indices.contains(index) else { return nil }
        let page = session.pages[index]
        let paper = session.setup.paperSizePoints(content: page.rect)
        // 预览按 1.1 px/pt 渲染：A1 也就 1300×920，够看清线也不卡。
        guard let image = PrintRenderer.image(
            setup: session.setup, canvas: canvas, space: page.space,
            worldRect: page.rect, paperSize: paper, pixelsPerPoint: 1.1) else { return nil }
        images[index] = image
        return image
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for (index, rect) in pageRects.enumerated() {
            guard rect.intersects(dirtyRect) else { continue }
            let selected = index == (session?.currentPage ?? 0)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 12,
                          color: NSColor.black.withAlphaComponent(0.22).cgColor)
            NSColor.white.setFill()
            let paper = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            paper.fill()
            ctx.restoreGState()
            if let image = image(for: index) {
                ctx.saveGState()
                ctx.interpolationQuality = .high
                // 图像是自上而下的位图，而这里是翻转坐标，先摆正。
                ctx.translateBy(x: rect.minX, y: rect.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
                ctx.restoreGState()
            }
            if selected {
                ctx.saveGState()
                ctx.setStrokeColor(Theme.accent.withAlphaComponent(0.85).cgColor)
                ctx.setLineWidth(1.5)
                ctx.stroke(rect.insetBy(dx: -1.5, dy: -1.5))
                ctx.restoreGState()
            } else if index == hoveredPage {
                // 悬停只给一条 1pt 的淡强调色边，不加位移：纸页本身不动，
                // 动的是"这一页可以点"的信号。
                ctx.saveGState()
                ctx.setStrokeColor(Theme.accent.withAlphaComponent(0.45).cgColor)
                ctx.setLineWidth(1)
                ctx.stroke(rect.insetBy(dx: -1, dy: -1))
                ctx.restoreGState()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for (index, rect) in pageRects.enumerated() where rect.contains(point) {
            onSelectPage?(index)
            break
        }
    }
}

// MARK: - 矢量打印视图

/// 真正送去打印机的视图：一页一张纸，矢量出图，分辨率由打印机决定。
final class PrintVectorView: NSView {
    private let canvas: CanvasView
    private let session: PrintSession
    private var drawingPage = 0

    init(canvas: CanvasView, session: PrintSession) {
        self.canvas = canvas
        self.session = session
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: max(1, session.pages.count))
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        drawingPage = max(0, min(page - 1, session.pages.count - 1))
        return bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              session.pages.indices.contains(drawingPage) else { return }
        let page = session.pages[drawingPage]
        guard let rect = PrintRenderer.draw(
            ctx: ctx, setup: session.setup, canvas: canvas, space: page.space,
            worldRect: page.rect, paperSize: bounds.size) else { return }
        if session.ruler { PrintRenderer.drawRuler(ctx: ctx, paper: bounds, content: rect) }
    }
}

// MARK: - 构造入口

enum PrintPreviewBuilder {

    /// 当前选区打印：一页。
    static func sessionForSelection(canvas: CanvasView, rect: CGRect) -> PrintWindowController? {
        guard let document = canvas.document else { return nil }
        let name = document.spaceInfo(canvas.space)?.name ?? "模型"
        let page = PrintPage(space: canvas.space, rect: rect, title: name)
        return PrintWindowController(canvas: canvas, pages: [page],
                                     title: "打印预览 · \(document.fileName)")
    }

    /// 打印图纸：按布局里的"图框"逐张出页。
    ///
    /// 不能按视口出页：一个视口可以横跨好几张图框——酒店的立面图就是一条
    /// 1654 宽的大视口压着 4 张 A3 图框，按视口出页只得到 12 页，最后那页
    /// 把四张立面挤成一条，另外三张图框直接消失。图纸的页单位是图框，视口
    /// 只是"这里显示模型哪一块"的窗口。
    static func pagesForWholeDrawing(canvas: CanvasView) -> [PrintPage] {
        guard let document = canvas.document else { return [] }
        var pages: [PrintPage] = []
        let log = ProcessInfo.processInfo.environment["CADLENS_PRINT_LOG"] != nil
        // 先按布局空间收视口；模型空间不参与"按图框打印"。
        for (offset, space) in document.spaces.enumerated() where space.kind != 0 {
            let index = Int32(offset)
            let extent = document.layoutExtent(index)
            var viewports = document.viewports.filter {
                $0.space == index
                    && $0.clip.width > 1 && $0.clip.height > 1
                    && $0.size.width > 0.5 && $0.size.height > 0.5
                    && $0.modelHeight > 1e-9
                    && !document.isOverallPaperViewport($0)
            }
            // 有些布局把模型视口存成"关闭"，可是在 CAD 里照样出图。整张布局
            // 一个打开的视口都没有时，按打开的处理，否则这一页就是白纸。
            let revealing = viewports.filter { $0.status != 0 }
            if !revealing.isEmpty { viewports = revealing }
            // 落在纸外的视口（指向别的模型副本）不该算这一页，否则同一张
            // 图纸会被打两遍。
            if extent.width > 1, extent.height > 1 {
                viewports = viewports.filter { viewport in
                    let overlap = viewport.clip.intersection(extent)
                    guard !overlap.isNull, !overlap.isEmpty else { return false }
                    let area = overlap.width * overlap.height
                    return area >= viewport.clip.width * viewport.clip.height * 0.2
                }
            }
            guard !viewports.isEmpty else {
                let rect = extent.width > 1 && extent.height > 1 ? extent : space.box
                if rect.width > 1, rect.height > 1 {
                    pages.append(PrintPage(space: index, rect: rect, title: space.name))
                }
                continue
            }
            // 布局里通常还有一个"整张纸"的视口，它把下面每个图框的视口都包住。
            // 按它出页就是把整页缩成一张小图，没有意义——剔掉它，除非剔完
            // 一个不剩（那说明这个布局只有那一个视口）。
            let all = viewports
            viewports = all.filter { candidate in
                !all.contains { other in
                    other.id != candidate.id
                        && candidate.clip.insetBy(dx: 1, dy: 1).contains(other.clip)
                }
            }
            if viewports.isEmpty { viewports = all }

            // 一个布局只有一张图（一个视口就铺满整张纸）时，直接按纸面出
            // 一页。这类结构图/建筑图最常见：8 个布局 = 8 张 A1，若还去
            // 纸里找"矩形图框"，找到的往往是标题栏那一小块，打出来就是
            // 一张只剩图签的碎页。
            let sheetArea = extent.width * extent.height
            if sheetArea > 1, viewports.allSatisfy({ viewport in
                let overlap = viewport.clip.intersection(extent)
                guard !overlap.isNull, !overlap.isEmpty else { return false }
                return overlap.width * overlap.height >= sheetArea * 0.6
            }) {
                pages.append(PrintPage(space: index, rect: extent, title: space.name))
                continue
            }

            let sheets = pageFrames(document: document, space: index,
                                    viewports: viewports)
            if log {
                print("[print] space=\(space.name) viewports=\(viewports.count) "
                      + "frames=\(sheets.count) pages=\(pages.count)")
                for (i, f) in sheets.enumerated() {
                    print(String(format: "[print]   frame %d: (%.1f,%.1f)-(%.1f,%.1f)",
                                 i + 1, f.minX, f.minY, f.maxX, f.maxY))
                }
            }
            if sheets.isEmpty {
                // 找不到图框就退回逐视口出页：没有图框的布局（随手画的模型
                // 视口）至少还能一视口一页。
                viewports.sort { a, b in
                    let tolerance = 0.5 * min(a.clip.height, b.clip.height)
                    if abs(a.clip.midY - b.clip.midY) > tolerance {
                        return a.clip.midY > b.clip.midY
                    }
                    return a.clip.minX < b.clip.minX
                }
                for (position, viewport) in viewports.enumerated() {
                    pages.append(PrintPage(space: index, rect: viewport.clip,
                                           title: "\(space.name) · 视口 \(position + 1)"))
                }
                continue
            }
            for (position, sheet) in sheets.enumerated() {
                pages.append(PrintPage(space: index, rect: sheet,
                                       title: "\(space.name) · 图框 \(position + 1)"))
            }
        }
        return pages
    }

    /// 一张图纸的页 = 一个图框。返回按阅读顺序（先上后下、同排从左到右）
    /// 排好的图框。
    ///
    /// 图纸里还有两种矩形要排除：套在整张纸外面的图框边线（包住所有图框），
    /// 以及每个图框内部的标题栏小框。前者按"包住两个以上图框"识别，后者按
    /// "被图框包住且面积远小于它"识别。
    private static func pageFrames(document: CadDocument, space: Int32,
                                   viewports: [CadViewport]) -> [CGRect] {
        var candidates: [CGRect] = []
        for frame in sheetFrames(document: document, space: space) {
            // 图框必须真的有视口落在里面，而且**高度和视口是同一量级**：
            // 图框里的家具详图、标题栏也是矩形，只看"有交集"会把它们当成
            // 一页打出去（2226 那张图框里就有两个这样的内框）。
            let covered = viewports.contains { viewport in
                let overlap = viewport.clip.intersection(frame)
                guard !overlap.isNull, !overlap.isEmpty else { return false }
                let area = overlap.width * overlap.height
                guard area >= frame.width * frame.height * 0.25 else { return false }
                let ratio = frame.height / max(viewport.clip.height, 1)
                return ratio >= 0.55 && ratio <= 2.2
            }
            guard covered else { continue }
            // 同一个框常常被画两遍（图框块一次、纸空间一次），去掉重合的。
            let duplicate = candidates.contains { existing in
                abs(existing.minX - frame.minX) < 1 && abs(existing.minY - frame.minY) < 1
                    && abs(existing.width - frame.width) < 1
                    && abs(existing.height - frame.height) < 1
            }
            if !duplicate { candidates.append(frame) }
        }
        // 包住两个以上图框的，是整张纸的边框，不是一张图。
        var sheets = candidates.filter { frame in
            let inner = candidates.filter { other in
                other != frame
                    && other.width * other.height < frame.width * frame.height
                    && frame.insetBy(dx: -1, dy: -1).contains(other)
            }
            return inner.count < 2
        }
        if sheets.isEmpty { sheets = candidates }
        // 标题栏小块：被另一张图框包住、面积不到它一半。
        sheets = sheets.filter { frame in
            !sheets.contains { other in
                other.width * other.height > frame.width * frame.height * 2
                    && other.insetBy(dx: -1, dy: -1).contains(frame)
            }
        }
        sheets.sort { a, b in
            let tolerance = 0.5 * min(a.height, b.height)
            if abs(a.midY - b.midY) > tolerance { return a.midY > b.midY }
            return a.minX < b.minX
        }
        return sheets
    }


    /// 纸空间里的矩形图框（闭合四点多段线）。按面积从小到大返回，供"这个
    /// 视口属于哪张图"的归属判断使用。
    private static func sheetFrames(document: CadDocument, space: Int32) -> [CGRect] {
        var paper: [CGRect] = []
        var projected: [CGRect] = []
        document.withDisplaySpace(space) {
            for entity in document.entities where entity.space == space {
                guard entity.kind == .polyline || entity.kind == .solid else { continue }
                let box = entity.box
                guard box.width > 40, box.height > 40 else { continue }
                var corners = Array(document.points(for: entity))
                if corners.count == 5,
                   hypot(corners[4].x - corners[0].x, corners[4].y - corners[0].y) < 1e-6 {
                    corners.removeLast()
                }
                guard corners.count == 4 else { continue }
                let tolerance = max(box.width, box.height) * 0.004
                let targets = [CGPoint(x: box.minX, y: box.minY),
                               CGPoint(x: box.maxX, y: box.minY),
                               CGPoint(x: box.maxX, y: box.maxY),
                               CGPoint(x: box.minX, y: box.maxY)]
                let isRectangle = corners.allSatisfy { corner in
                    targets.contains { hypot($0.x - corner.x, $0.y - corner.y) <= tolerance }
                }
                guard isRectangle else { continue }
                // 切到布局后 `entities` 里除了纸空间自己的图元，还混着透过视口
                // 投进来的模型副本——房间边界、家具方框、分格线在纸面上也是
                // 规规矩矩的四点矩形，被当成图框就会给一张图多出好几页（西昌
                // 那张 34 张 A3 会打成 53 页，多出来的 19 页全是这种）。投影
                // 副本都带着视口的纸面裁剪框，纸空间图元没有，靠这个分开。
                if entity.hasClip { projected.append(box) } else { paper.append(box) }
            }
        }
        // 页的单位是画在纸上的图框。少数图把图框画在模型里、只用一个视口显示，
        // 这种布局纸面上一个图框都没有，才退回投影副本去认。
        let frames = paper.isEmpty ? projected : paper
        return frames.sorted { $0.width * $0.height < $1.width * $1.height }
    }

    /// 预览窗口里"一键添加布局图框"用：只补布局页，不重复已有页。
    static func layoutPages(for canvas: CanvasView) -> [PrintPage] {
        pagesForWholeDrawing(canvas: canvas)
    }

    static func writePDF(session: PrintSession, canvas: CanvasView, to url: URL) {
        guard !session.pages.isEmpty else { return }
        let first = session.setup.paperSizePoints(content: session.pages[0].rect)
        var mediaBox = CGRect(origin: .zero, size: first)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { return }
        for page in session.pages {
            let paper = session.setup.paperSizePoints(content: page.rect)
            var box = CGRect(origin: .zero, size: paper)
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: NSValue(rect: box)] as CFDictionary)
            _ = PrintRenderer.draw(ctx: ctx, setup: session.setup, canvas: canvas,
                                   space: page.space, worldRect: page.rect,
                                   paperSize: paper)
            if session.ruler {
                PrintRenderer.drawRuler(ctx: ctx, paper: box, content: page.rect)
            }
            box = .zero
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}
