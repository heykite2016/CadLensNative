import AppKit
import UniformTypeIdentifiers

/// Main window in the layout a drafter expects: command toolbar on top,
/// instrument palette on the left, layer/annotation docks on the right,
/// command line and status bar at the bottom, layout tabs where the model
/// space tabs live in AutoCAD.
final class MainWindowController: NSWindowController, NSMenuDelegate {

    let canvas = CanvasView(frame: .zero)
    let toolbar = CADToolbar()
    private let palette = ToolPalette()
    private let sidebar = SidebarController()
    private let statusBar = CADStatusBar()
    private let commandBar = CADCommandBar()
    private let layoutTabs = CADLayoutTabs()
    /// 图纸标签栏。一块画布 + 若干份文档状态，是本窗口的"多图纸"。
    private let documentTabs = CADDocumentTabs()

    private(set) var cadDocument: CadDocument?
    /// 打开过的图纸。每份带着自己的空间、相机和选中项，切换时换进画布。
    private(set) var sessions: [DocumentSession] = []
    private(set) var activeIndex = -1

    var activeSession: DocumentSession? {
        guard activeIndex >= 0, activeIndex < sessions.count else { return nil }
        return sessions[activeIndex]
    }
    private var sidebarWidth: NSLayoutConstraint!
    /// 压在画布上的玻璃浮层，按从下到上的顺序。截图时用它把浮层重画一次。
    private(set) var overlayViews: [NSView] = []
    /// 侧栏展开宽度。收起后要能按同一个值弹回来，所以留一个常量。
    private let sidebarWidthValue: CGFloat = 272
    private var annotationsVisible = true
    private var lastTool: MeasureKind?
    private let preferredContentSize: NSSize

    init() {
        let visible = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // 宽度直接铺满屏幕：左边工具列 + 中间图纸 + 右边侧栏，一条横向量满
        // 才够用。高度沿用上次的（夹在可用范围内），启动时顶着菜单栏下沿。
        let defaultSize = NSSize(
            width: visible.width,
            height: min(max(visible.height * 0.86, 760), visible.height))
        preferredContentSize = defaultSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "速看CAD"
        // 图纸铺满整窗：标题栏透明，内容延伸到红绿灯下面。系统的三个按钮
        // 藏掉，改由左上角玻璃胶囊里的自绘版本接管——标题栏那一条仍会吞掉
        // 鼠标事件，留着系统按钮就等于让工具岛的上半截点不动。
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = Theme.canvasBackground
        // 使用系统原生红绿灯：全屏/缩放/左右停靠都由 macOS 自己处理，
        // 不再自绘，也不隐藏标准按钮。
        window.minSize = NSSize(width: 1080, height: 700)
        // .default 在新系统上不保证标题栏隐藏 + fullSizeContentView 的窗口
        // 能进全屏；显式声明 primary 才允许绿色按钮/⌃⌘F 进入。
        window.collectionBehavior = [.fullScreenPrimary, .fullScreenAllowsTiling]
        window.setFrameAutosaveName("CadLensMainWindow.v4")
        // 自动保存只认高度。宽度是"铺满屏幕"这个约定的一部分，不能被上次
        // 随手拉窄的窗口带跑——否则每次启动都得再手动拉宽一次。
        let savedHeight = window.frame.height
        let height = (savedHeight >= 700 && savedHeight <= visible.height)
            ? savedHeight : defaultSize.height
        window.setContentSize(NSSize(width: visible.width, height: height))
        var frame = window.frame
        frame.origin.x = visible.minX
        frame.origin.y = visible.maxY - frame.height
        window.setFrame(frame, display: false)
        super.init(window: window)

        buildLayout()
        wire()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged),
            name: .cadLensThemeChanged, object: nil)
    }

    /// 画布深浅变了：界面外观、画布栅格、图元反色、自绘控件都要重来一遍。
    /// NSApp.appearance 已由 canvasTone setter 同步设好，这里让每个窗口重新
    /// 取一次原生色并把自绘控件标脏。
    @objc private func themeChanged() {
        Theme.refreshAppearance()
        window?.backgroundColor = Theme.canvasBackground
        for window in NSApp.windows {
            window.appearance = NSApp.appearance
            window.contentView?.applyThemeRecursively()
        }
        canvas.themeDidChange()
        sidebar.refresh()
        refreshChromeState()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Layout

    private func buildLayout() {
        let root = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        root.wantsLayer = true

        // 底部一行只有布局页签和状态胶囊，自己不再铺底：两条浮层各自是玻璃，
        // 中间让图纸露出来。
        let bottomRow = CADGlassSurface()
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        bottomRow.addSubview(layoutTabs)
        bottomRow.addSubview(statusBar)

        sidebar.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(canvas)
        root.addSubview(toolbar)
        root.addSubview(palette)
        root.addSubview(sidebar.view)
        root.addSubview(commandBar)
        root.addSubview(bottomRow)

        // 图纸页签住进工具岛：多图纸时它是这条里最需要宽度的一块。
        toolbar.install(tabs: documentTabs)

        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.leadingOverlayInset = 0
        // 面板默认收起：看图是主任务，图层/标注清单要用的才点开。
        sidebarWidth = sidebar.view.widthAnchor.constraint(equalToConstant: 0)
        sidebar.view.isHidden = true
        sidebar.view.alphaValue = 0

        let railWidth = ToolPalette.width
        NSLayoutConstraint.activate([
            // 画布铺满整窗，所有浮层压在它上面。
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: root.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            // 工具岛从系统红绿灯右边起，给原生按钮留出真实标题栏的位置。
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 84),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            palette.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            palette.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
            palette.bottomAnchor.constraint(equalTo: commandBar.topAnchor, constant: -10),

            // 侧栏是浮层：开合不该改变画布尺寸，否则每次看图层清单，图纸都
            // 要重新取景、视口跳一下。
            sidebar.view.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            sidebar.view.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
            sidebar.view.bottomAnchor.constraint(equalTo: commandBar.topAnchor, constant: -10),
            sidebarWidth,

            // 命令行从工具竖排的右边线起，和画布左边缘齐平，视线不用横穿窗口。
            commandBar.leadingAnchor.constraint(equalTo: palette.trailingAnchor, constant: 10),
            commandBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            commandBar.bottomAnchor.constraint(equalTo: bottomRow.topAnchor, constant: -8),

            bottomRow.leadingAnchor.constraint(equalTo: palette.trailingAnchor, constant: 10),
            bottomRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            bottomRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            bottomRow.heightAnchor.constraint(equalToConstant: 32),

            layoutTabs.leadingAnchor.constraint(equalTo: bottomRow.leadingAnchor),
            layoutTabs.centerYAnchor.constraint(equalTo: bottomRow.centerYAnchor),
            // 布局名再长也不许吃掉状态栏：标签栏封顶，状态栏保底。
            layoutTabs.widthAnchor.constraint(lessThanOrEqualToConstant: CADLayoutTabs.maxStripWidth),

            statusBar.leadingAnchor.constraint(equalTo: layoutTabs.trailingAnchor, constant: 10),
            statusBar.trailingAnchor.constraint(equalTo: bottomRow.trailingAnchor),
            statusBar.topAnchor.constraint(equalTo: bottomRow.topAnchor),
            statusBar.bottomAnchor.constraint(equalTo: bottomRow.bottomAnchor),
        ])
        // 画布取景的有效区域：把四周浮层让出来，"显示全图"不会把图纸塞进
        // 工具岛底下。这个值与上面的约束是同一套数字。
        canvas.overlayInsets = NSEdgeInsets(top: 76, left: railWidth + 22,
                                            bottom: 88, right: 22)

        // 快照合成用：画布的 GPU 图要手工贴回窗口图，贴完这层浮层得重画一遍，
        // 否则图元会"浮"在玻璃工具岛上（真机合成顺序是对的，只有截图会穿帮）。
        overlayViews = [toolbar, palette, sidebar.view, commandBar, bottomRow]

        // 指针压在浮层上时把十字收起来：画布铺满整窗，自绘十字的两条长线
        // 会从玻璃底下穿过去，看着像"工具条上还有一根取点线"。
        for surface in overlayViews.compactMap({ $0 as? CADGlassSurface }) {
            surface.onPointerInsideChanged = { [weak self] _ in
                self?.updateChromeHover()
            }
        }

        window?.contentView = root
        window?.makeFirstResponder(canvas)
    }

    // MARK: Wiring

    private func wire() {
        toolbar.onCommand = { [weak self] command in self?.handle(command) }

        palette.onToolSelected = { [weak self] kind in
            self?.canvas.activeTool = kind
        }
        palette.onToggleSnap = { [weak self] on in
            guard let self else { return }
            self.canvas.settings.objectSnap = on
            self.canvas.settings.save()
            self.refreshChromeState()
        }
        palette.onToggleOrtho = { [weak self] on in
            guard let self else { return }
            self.canvas.settings.orthoMode = on
            self.canvas.settings.save()
            self.refreshChromeState()
        }
        palette.onCalibrate = { [weak self] in self?.beginCalibration() }
        palette.onToggleErase = { [weak self] in self?.toggleEraseTool() }

        statusBar.onToggleSnap = { [weak self] on in
            self?.canvas.settings.objectSnap = on
            self?.canvas.settings.save()
            self?.refreshChromeState()
        }
        statusBar.onToggleGrid = { [weak self] on in
            self?.canvas.settings.showGrid = on
            self?.canvas.settings.save()
            self?.canvas.needsDisplay = true
            self?.refreshChromeState()
        }
        statusBar.onToggleOrtho = { [weak self] on in
            self?.canvas.settings.orthoMode = on
            self?.canvas.settings.save()
            self?.refreshChromeState()
        }
        statusBar.onToggleLineweight = { [weak self] on in
            self?.canvas.settings.showLineweights = on
            self?.canvas.settings.save()
            self?.canvas.invalidateTiles()
            self?.refreshChromeState()
        }
        statusBar.snapMenuProvider = { [weak self] in self?.snapMenu }
        statusBar.onToggleAnnotations = { [weak self] on in
            self?.annotationsVisible = on
            self?.canvas.annotationsHidden = !on
        }

        commandBar.onSubmit = { [weak self] text in self?.runCommand(text) }
        commandBar.suggestionsProvider = { text in Self.suggestions(for: text) }

        layoutTabs.onSelect = { [weak self] index in
            self?.canvas.space = Int32(index)
        }

        documentTabs.onSelect = { [weak self] index in self?.activate(index) }
        documentTabs.onClose = { [weak self] index in self?.closeSession(at: index) }
        documentTabs.onNew = { [weak self] in self?.openDocument(nil) }
        documentTabs.delegateURL = { [weak self] index in
            guard let self, index >= 0, index < self.sessions.count else { return nil }
            return self.sessions[index].url
        }

        sidebar.onLayerToggle = { [weak self] index, visible in
            guard let document = self?.cadDocument, index < document.layers.count else { return }
            document.layers[index].visible = visible
            self?.canvas.invalidateTiles()
        }
        sidebar.onSelectPage = { [weak self] index in
            self?.canvas.space = Int32(index)
        }
        sidebar.onSelectAnnotation = { [weak self] index in
            self?.canvas.selectedAnnotation = index
            self?.canvas.needsDisplay = true
        }
        sidebar.onActivateAnnotation = { [weak self] index in
            guard let self else { return }
            // 先切到这条标注所在的空间，再导航——在布局页双击模型里的标注，
            // 跳过去只会看到一片空白。
            if let document = self.cadDocument, index < document.annotations.count {
                let target = document.annotations[index].space
                if target != self.canvas.space { self.canvas.space = target }
            }
            self.canvas.revealAnnotation(at: index)
            self.canvas.window?.makeFirstResponder(self.canvas)
        }
        sidebar.onToggleAnnotation = { [weak self] index, visible in
            guard let document = self?.cadDocument, index < document.annotations.count else { return }
            document.annotations[index].hidden = !visible
            self?.canvas.commitAnnotationChange()
        }
        sidebar.onDeleteAnnotation = { [weak self] index in
            guard let self, let document = self.cadDocument,
                  index < document.annotations.count else { return }
            let removed = document.annotations.remove(at: index)
            self.canvas.registerUndo(.remove(removed))
            self.canvas.commitAnnotationChange()
            self.refreshSidebar()
        }
        sidebar.onSelectStyle = { [weak self] style in
            AnnotationRenderer.style = style
            self?.canvas.settings.annotationStyle = style.rawValue
            self?.canvas.settings.save()
            self?.canvas.needsDisplay = true
            self?.refreshSidebar()
        }

        // The colour goes through the canvas settings, not a fresh
        // `CadSettings.load()`: the in-memory settings carry the toggles the
        // user just flipped, and reloading from disk here would silently revert
        // them.
        sidebar.onSelectInkColor = { [weak self] color in
            guard let self else { return }
            AnnotationRenderer.inkOverride = color
            self.canvas.settings.annotationColorHex = color.hexString
            self.canvas.settings.save()
            self.canvas.needsDisplay = true
            self.refreshSidebar()
        }

        canvas.onCursorMoved = { [weak self] world in
            guard let self, let document = self.cadDocument else { return }
            let x = document.lengthValue(Double(world.x))
            let y = document.lengthValue(Double(world.y))
            // 单位只在右侧那颗「单位 mm」里写一次：坐标后面再挂一个 mm，
            // 读数条会变成"mm 单位 mm"。
            self.statusBar.updateCoordinate(
                String(format: "X %@    Y %@", self.format(x), self.format(y)))
        }
        canvas.onPromptChanged = { [weak self] text in
            self?.commandBar.setPrompt(text)
        }
        canvas.onSelectionChanged = { [weak self] annotation in
            self?.sidebar.selectAnnotation(annotation?.id)
        }
        canvas.onAnnotationsChanged = { [weak self] in
            self?.refreshSidebar()
        }
        canvas.onSpaceChanged = { [weak self] index in
            self?.layoutTabs.select(Int(index))
            self?.sidebar.selectPage(Int(index))
            self?.refreshSidebar()
        }
        canvas.onToolChanged = { [weak self] kind in
            self?.palette.setActiveTool(kind)
            if kind != nil { self?.lastTool = kind }
        }
        // AutoCAD：命令结束后回车/空格重复上一条命令。测量工具也一样，
        // 连续量几段墙不需要每次都回工具条点一下。
        canvas.onRepeatLastTool = { [weak self] in
            guard let self, let last = self.lastTool else { return }
            self.setTool(last)
        }
        canvas.onEraseChanged = { [weak self] on in
            guard let self else { return }
            self.toolbar.setActive(.erase, on)
            self.palette.setEraseActive(on)
        }
        canvas.onZoomWindowChanged = { [weak self] on in
            self?.toolbar.setActive(.zoomWindow, on)
        }
        canvas.onZoomChanged = { [weak self] scale in
            self?.statusBar.updateZoom(scale)
        }
    }

    // MARK: Command completion

    /// 命令目录：十二个测量工具 + 常用视图/编辑命令。命令行靠它给出候选与说明，
    /// 让"记不住别名"不再是把人挡在命令之外的墙。
    private static let commandCatalog: [CommandSuggestion] = {
        var list = MeasureKind.allCases.map { kind in
            CommandSuggestion(title: kind.title,
                              alias: (kind.aliases.first ?? "").uppercased(),
                              detail: kind.purpose)
        }
        list += [
            CommandSuggestion(title: "窗口缩放", alias: "Z", detail: "拖出一个范围放大"),
            CommandSuggestion(title: "显示全图", alias: "E", detail: "把整张图放进窗口"),
            CommandSuggestion(title: "平移", alias: "P", detail: "按住拖动图纸"),
            CommandSuggestion(title: "图层面板", alias: "LA", detail: "打开图层与标注信息面板"),
            CommandSuggestion(title: "比例校准", alias: "CAL", detail: "取两点已知长度校准图纸比例"),
            CommandSuggestion(title: "撤销", alias: "U", detail: "撤销上一步标注操作"),
            CommandSuggestion(title: "删除标注", alias: "E2", detail: "删除当前选中的标注"),
            CommandSuggestion(title: "帮助", alias: "?", detail: "快捷键与使用说明"),
        ]
        return list
    }()

    /// 候选排序：整词命中 → 别名前缀 → 中文名前缀 → 包含。同分时短别名优先，
    /// 因为更短的命令更可能是用户正要敲的那个。
    static func suggestions(for raw: String) -> [CommandSuggestion] {
        let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return [] }
        var scored: [(Int, String, CommandSuggestion)] = []
        for item in commandCatalog {
            let alias = item.alias.lowercased()
            let score: Int
            if alias == key {
                score = 0
            } else if alias.hasPrefix(key) {
                score = 1
            } else if item.title == raw {
                score = 1
            } else if item.title.hasPrefix(raw) {
                score = 2
            } else if alias.contains(key) || item.title.contains(raw) {
                score = 3
            } else {
                continue
            }
            scored.append((score, item.alias, item))
        }
        scored.sort { a, b in
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1.count != b.1.count { return a.1.count < b.1.count }
            return a.1 < b.1
        }
        return scored.map(\.2)
    }

    private func format(_ value: Double) -> String {
        let precision = cadDocument?.precision ?? 0
        return String(format: "%.\(precision)f", value)
    }

    // MARK: Commands

    private func handle(_ command: CADToolbar.Command) {
        switch command {
        case .open: openDocument(nil)
        case .print: PrintCommands.beginSelectionPrint(from: self)
        case .printFrames: PrintCommands.printDrawing(from: self)
        case .undo: canvas.undoManager?.undo()
        case .redo: canvas.undoManager?.redo()
        case .erase: toggleEraseTool()
        case .select:
            canvas.activeTool = nil
            palette.setActiveTool(nil)
        case .pan:
            // 平移已经是手势，不再有模式可切。
            commandBar.setPrompt("平移：在图纸上按住左键拖动即可")
        case .zoomWindow:
            // 一次性动作：工具点亮，框完自动退。
            canvas.zoomWindowMode = true
            commandBar.setPrompt("窗口缩放：拖出一个范围")
        case .fit: canvas.zoomToExtents(animated: true)
        case .zoomIn: canvas.zoom(by: 1.25)
        case .zoomOut: canvas.zoom(by: 0.8)
        case .layers: toggleSidebar(selecting: 0)
        case .annotations: toggleSidebar(selecting: 1)
        case .settings: showSettings(nil)
        case .help: showQuickHelp()
        default: break
        }
    }

    /// Text typed into the command line. Aliases mirror the AutoCAD commands a
    /// Chinese drafter already has in muscle memory, and the Chinese caption of
    /// every tool works as well because that is what the palette shows.
    private func runCommand(_ raw: String) {
        let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return }

        if let kind = MeasureKind.allCases.first(where: {
            $0.aliases.contains(key) || $0.title == raw || $0.shortTitle == raw
        }) {
            setTool(kind)
            return
        }

        switch key {
        case "z", "zoom", "缩放":
            canvas.zoomWindowMode = true
            toolbar.setActive(.zoomWindow, true)
        case "e", "extents", "全图", "ze":
            canvas.zoomToExtents(animated: true)
        case "p", "pan", "平移":
            // 保留别名只为不让人以为命令失效：平移本来就不需要切工具。
            commandBar.setPrompt("平移：在图纸上按住左键拖动即可（无需切换工具）")
        case "la", "layer", "图层":
            toggleSidebar(selecting: 0)
        case "dim", "标注":
            toggleSidebar(selecting: 1)
        case "st", "style", "样式":
            showStyleSheet()
        case "cal", "calibrate", "校准":
            beginCalibration()
        case "u", "undo", "撤销":
            canvas.undoManager?.undo()
        case "esc", "取消":
            canvas.cancelMeasurement()
        case "?", "help", "帮助":
            showQuickHelp()
        case "er", "eraseall", "删除工具":
            toggleEraseTool()
        case "e2", "erase", "删除":
            canvas.deleteSelection()
        default:
            commandBar.setPrompt("未知命令 “\(raw)” · 试试 AL / DLI / AA / Z / E")
            NSSound.beep()
        }
    }

    func setTool(_ kind: MeasureKind?) {
        canvas.activeTool = kind
        palette.setActiveTool(kind)
        if let kind {
            lastTool = kind
            commandBar.setPrompt(kind.purpose + " · Esc 取消")
        } else {
            commandBar.setPrompt("")
        }
    }

    /// 删除工具是一个模式而不是一次动作：点一下删一条，拖一个框删一片，
    /// 退出前一直是它。
    private func toggleEraseTool() {
        canvas.eraseMode.toggle()
        if canvas.eraseMode {
            commandBar.setPrompt("删除标注：点击单选，或拖框删除完全框选的标注 · Esc 退出")
        } else if let last = lastTool {
            setTool(last)
        }
    }

    private func showStyleSheet() {
        let menu = NSMenu(title: "标注样式")
        for style in AnnotationStyle.allCases {
            let item = NSMenuItem(title: style.title, action: #selector(pickStyle(_:)),
                                  keyEquivalent: "")
            item.representedObject = style.rawValue
            item.target = self
            item.state = AnnotationRenderer.style == style ? .on : .off
            menu.addItem(item)
        }
        if let view = window?.contentView {
            menu.popUp(positioning: menu.items.first,
                       at: NSPoint(x: 130, y: view.bounds.height - 60), in: view)
        }
    }

    @objc private func pickStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = AnnotationStyle(rawValue: raw) else { return }
        AnnotationRenderer.style = style
        // 与颜色路径同理：改单字段必须在内存里的 settings 上改，不能从磁盘
        // 重新 load 一份，否则刚翻过的开关会被旧副本覆盖回去。
        canvas.settings.annotationStyle = raw
        canvas.settings.save()
        canvas.needsDisplay = true
        sidebar.refresh()
    }

    /// 说明是一份可以一直开着的窗口，而不是一次性的提示框：对照操作时才不用
    /// 反复开关。
    private func showQuickHelp() {
        HelpWindowController.shared.show()
    }

    /// No opening dialog: the instruction is already the most useful thing the
    /// command line can say, and a modal in front of "click two points" only
    /// adds a step before the work. The dialog appears where a number is
    /// genuinely needed — after both points are picked.
    private func beginCalibration() {
        canvas.beginCalibration { [weak self] measured, apply in
            guard let self, let document = self.cadDocument else { return }
            let prompt = NSAlert()
            prompt.messageText = "输入实际长度"
            prompt.informativeText = String(format: "图上长度 %.2f %@",
                                            document.lengthValue(Double(measured)),
                                            document.displayUnit.suffix)
            prompt.addButton(withTitle: "确定")
            prompt.addButton(withTitle: "取消")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            field.placeholderString = "实际长度"
            prompt.accessoryView = field
            prompt.window.initialFirstResponder = field
            guard prompt.runModal() == .alertFirstButtonReturn,
                  let actual = Double(field.stringValue), actual > 0, measured > 0 else {
                return
            }
            // actual 是“显示单位”下的数值。先得到“米/图纸单位”的绝对目标值，
            // 再换成相对于当前 unitMeters 的比例——apply() 里是 *= factor。
            // 之前直接 actual / measured，把 mm 当成了米：米图按 mm 校准会
            // 放大 1000 倍，mm 图改成 m 显示也会错。
            let target = actual * document.displayUnit.metersPerUnit / Double(measured)
            let factor = target / document.unitMeters
            guard factor > 0, factor.isFinite, target.isFinite else { return }
            apply(factor)
            // 比例变了，已经落在图上的标注也必须改口：长度/面积/周长全部
            // 按新的 unitMeters 重算，否则旧标注还印着校准前的数值。
            self.canvas.refreshAnnotationTexts()
            self.commandBar.setPrompt(
                String(format: "校准完成：1 图纸单位 = %.6f 米", target))
            self.refreshSidebar()
        }
    }

    // MARK: Documents

    /// 打开一张图纸。已经打开过就切过去——重复打开同一个文件在新标签里再来
    /// 一份，只会让人分不清哪一份上的标注是刚量的。
    func open(url: URL) {
        let target = url.standardizedFileURL
        if let existing = sessions.firstIndex(where: { $0.url.standardizedFileURL == target }) {
            activate(existing, force: true)
            commandBar.setPrompt("已切到「\(sessions[existing].displayName)」")
            return
        }
        do {
            let settings = CadSettings.load()
            let loaded = try CadDocument(url: url)
            loaded.displayUnit = settings.displayUnit
            loaded.areaUnit = settings.areaUnit
            loaded.precision = settings.precision
            let session = DocumentSession(url: url, document: loaded)
            sessions.append(session)
            activeIndex = sessions.count - 1
            canvas.settings = settings
            applyAnnotationStyle(settings)
            AnnotationRenderer.inkOverride = NSColor(hex: settings.annotationColorHex)
            sidebar.reflectInkColor(AnnotationRenderer.inkOverride ?? Theme.measurementStroke)
            AnnotationRenderer.scalesWithDrawing = settings.annotationScalesWithDrawing
            applyActiveSession(recent: true)
            palette.apply(settings: settings)
            DevelopmentHarness.handleDocumentLoaded(self)
            if !loaded.missingXrefs.isEmpty {
                presentMissingXrefs(for: loaded)
            }
        } catch {
            showLoadError(error)
        }
    }

    /// 切到第 index 张图纸。切走之前先把当前这张的视图状态存回去，否则"切回
    /// 去还在刚才那个位置"这句话就不成立。
    func activate(_ index: Int, force: Bool = false) {
        guard index >= 0, index < sessions.count else { return }
        if !force, index == activeIndex {
            refreshDocumentTabs()
            return
        }
        captureActiveSession()
        // 一块窗口只有一个撤销栈，而撤销动作里写的是"当前文档"。不清空就会
        // 让 A 图上的一次删除在切到 B 图后撤销到 B 上——这是最容易毁图纸的
        // 那种 bug，宁可不跨图纸撤销。
        window?.undoManager?.removeAllActions()
        canvas.measurePoints.removeAll()
        activeIndex = index
        applyActiveSession()
        canvas.window?.makeFirstResponder(canvas)
    }

    /// 存下当前图纸的视图状态。只在画布确实装着这张图时才写——切换过程中
    /// activeIndex 已经指向新图、画布还是旧图，这时写会把旧状态写到新图上。
    private func captureActiveSession() {
        guard let session = activeSession, cadDocument === session.document else { return }
        session.space = canvas.space
        session.camera = canvas.transform
        session.fitScale = AnnotationRenderer.fitScale
        session.selectedAnnotation = canvas.selectedAnnotation
        session.hasCamera = canvas.transform.scale > 0
    }

    /// 把 activeIndex 指向的图纸装进整条 UI：画布、侧栏、布局标签、标题、
    /// 状态栏、图纸标签栏。任何"跟着图纸走"的东西都必须在这里更新。
    private func applyActiveSession(recent: Bool = false) {
        refreshDocumentTabs()

        guard let session = activeSession else {
            cadDocument = nil
            canvas.load(document: nil, space: 0, camera: nil)
            sidebar.document = nil
            layoutTabs.configure([], selected: 0)
            window?.title = "速看CAD"
            window?.representedURL = nil
            toolbar.setDocumentCaption("未打开图纸")
            annotationsVisible = true
            canvas.annotationsHidden = false
            refreshChromeState()
            refreshSidebar()
            return
        }

        let loaded = session.document
        cadDocument = loaded
        canvas.load(document: loaded, space: session.space,
                    camera: session.hasCamera ? session.camera : nil,
                    fitScale: session.fitScale)
        canvas.selectedAnnotation = session.selectedAnnotation
        window?.title = session.displayName
        window?.representedURL = session.url
        if recent { NSDocumentController.shared.noteNewRecentDocumentURL(session.url) }
        sidebar.document = loaded
        refreshChromeState()
        refreshSidebar()

        let names = loaded.spaces.map { $0.name.isEmpty ? "布局" : $0.name }
        layoutTabs.configure(names, selected: Int(session.space))
        toolbar.setDocumentCaption(loaded.isPDF
            ? "PDF · \(loaded.spaces.count) 页"
            : "\(loaded.entities.count) 图元 · \(loaded.layers.count) 图层")
        if loaded.truncatedEntities {
            commandBar.setNotice("图元超过 90 万，已截断绘制",
                                 detail: "这张图超过 900,000 个图元安全上限，超出的部分没有载入。请按图层拆分或裁剪后查看。")
        } else if loaded.skippedObjects > 0 {
            commandBar.setNotice(Self.xrefBadge(for: loaded),
                                 detail: Self.xrefNote(for: loaded))
        } else {
            commandBar.setPrompt("就绪 · 选择测量工具，或直接输入命令")
        }
    }

    private func refreshDocumentTabs() {
        let items = sessions.map { session -> CADDocumentTabs.Item in
            let document = session.document
            let lines = [
                session.url.path,
                "\(document.entities.count) 图元 · \(document.layers.count) 图层"
                    + " · \(document.annotations.count) 条标注",
                "右键：关闭 / 关闭其他 / 在访达中显示",
            ]
            return CADDocumentTabs.Item(title: session.displayName,
                                        tooltip: lines.joined(separator: "\n"),
                                        badge: document.annotations.count)
        }
        documentTabs.configure(items, active: activeIndex)
    }

    /// 关闭一张图纸。关的是当前这张才需要先把视图状态存回去；关的是别的，
    /// 直接摘掉即可。
    func closeSession(at index: Int) {
        guard index >= 0, index < sessions.count else { return }
        if index == activeIndex { captureActiveSession() }
        let session = sessions[index]
        sessions.remove(at: index)

        if sessions.isEmpty {
            activeIndex = -1
            applyActiveSession()
            commandBar.setPrompt("已关闭全部图纸 · ⌘O 打开，或把图纸拖进窗口")
            return
        }
        if index < activeIndex {
            activeIndex -= 1
        } else if index == activeIndex {
            activeIndex = min(index, sessions.count - 1)
        }
        applyActiveSession()
        commandBar.setPrompt("已关闭「\(session.displayName)」")
    }

    /// ⌘W：有图纸就关图纸，没有才轮到关窗口——这和 CAD 软件的"关闭图形"
    /// 一致，比直接关窗少一次误操作。
    @objc func closeActiveDocument(_ sender: Any?) {
        if !sessions.isEmpty {
            closeSession(at: activeIndex)
        } else {
            window?.performClose(sender)
        }
    }

    /// ⌃Tab / ⌃⇧Tab：在图纸之间循环。
    func cycleDocument(_ delta: Int) {
        guard sessions.count > 1 else { return }
        let next = ((activeIndex + delta) % sessions.count + sessions.count) % sessions.count
        activate(next)
    }

    /// ⌘1…⌘9：直接跳到第 n 张。
    func activateDocument(number: Int) {
        guard number >= 1, number <= sessions.count else {
            NSSound.beep()
            return
        }
        activate(number - 1)
    }

    func typeCommand(_ text: String) {
        commandBar.typeIntoInput(text)
    }

    /// 标注的"样式 + 端符"一起下发：样式决定字高、线宽、界线长度，端符
    /// （箭头 / 45° 短斜线）是单独可选的，空串表示跟随样式默认。
    private func applyAnnotationStyle(_ settings: CadSettings) {
        AnnotationRenderer.style = AnnotationStyle(rawValue: settings.annotationStyle)
            ?? .architectural
        AnnotationRenderer.markerOverride = AnnotationMarker(rawValue: settings.annotationMarker)
    }

    func apply(settings: CadSettings) {
        canvas.settings = settings
        applyAnnotationStyle(settings)
        AnnotationRenderer.inkOverride = NSColor(hex: settings.annotationColorHex)
        AnnotationRenderer.scalesWithDrawing = settings.annotationScalesWithDrawing
        cadDocument?.displayUnit = settings.displayUnit
        cadDocument?.areaUnit = settings.areaUnit
        cadDocument?.precision = settings.precision
        canvas.refreshAnnotationTexts()
        palette.apply(settings: settings)
        canvas.invalidateTiles()
        refreshChromeState()
        refreshSidebar()
    }

    /// One-glance badge for the status strip; the names live in the tooltip.
    private static func xrefBadge(for document: CadDocument) -> String {
        let unresolved = document.xrefNames.count
        let inserts = document.skippedObjects
        return unresolved > 0
            ? "缺 \(unresolved) 个外部参照 · \(inserts) 处未绘制"
            : "跳过 \(inserts) 个外部参照对象"
    }

    private static func xrefNote(for document: CadDocument) -> String {
        guard document.skippedObjects > 0 else { return "" }
        let names = document.xrefNames
        guard !names.isEmpty else { return "已跳过 \(document.skippedObjects) 个外部参照" }
        let shown = names.prefix(4).joined(separator: "、")
        let more = names.count > 4 ? " 等 \(names.count) 个" : ""
        return "缺外部参照：\(shown)\(more)（共 \(document.skippedObjects) 处插入）"
    }

    private func showLoadError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "无法打开图纸"
        alert.informativeText = error.localizedDescription
        if let window { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }

    func refreshSidebar() {
        sidebar.refresh()
    }

    // MARK: Object snap targets

    /// One menu, two entry points (right-click on the status-bar 捕捉 button and
    /// 视图 ▸ 对象捕捉). Rebuilt on open so its checkmarks are never stale.
    lazy var snapMenu: NSMenu = {
        let menu = NSMenu(title: "对象捕捉")
        menu.delegate = self
        return menu
    }()

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "对象捕捉" else { return }
        populateSnapMenu(menu)
    }

    /// Fills a menu with the master switch and one checkbox per target. Shared
    /// with the main menu bar so both lists can never disagree.
    func populateSnapMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let master = NSMenuItem(title: "启用对象捕捉", action: #selector(toggleSnapMaster(_:)),
                                keyEquivalent: "f3")
        master.target = self
        master.state = canvas.settings.objectSnap ? .on : .off
        menu.addItem(master)
        menu.addItem(.separator())

        for kind in SnapKind.allCases {
            let item = NSMenuItem(title: kind.title, action: #selector(toggleSnapKind(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            item.state = canvas.settings.snapModes.isEnabled(kind) ? .on : .off
            item.isEnabled = canvas.settings.objectSnap
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let all = NSMenuItem(title: "全部捕捉", action: #selector(snapSelectAll(_:)),
                             keyEquivalent: "")
        all.target = self
        menu.addItem(all)
        let standard = NSMenuItem(title: "仅端点 / 中点 / 圆心 / 交点",
                                  action: #selector(snapSelectStandard(_:)), keyEquivalent: "")
        standard.target = self
        menu.addItem(standard)
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "捕捉在整个应用内统一生效", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
    }

    @objc private func toggleSnapMaster(_ sender: Any?) {
        canvas.settings.objectSnap.toggle()
        canvas.settings.save()
        refreshChromeState()
        commandBar.setPrompt(canvas.settings.objectSnap
            ? "对象捕捉：开启 · 右键状态栏「捕捉」可设置捕捉点"
            : "对象捕捉：关闭")
    }

    @objc private func toggleSnapKind(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = SnapKind(rawValue: raw) else { return }
        var modes = canvas.settings.snapModes
        modes.set(kind, !modes.isEnabled(kind))
        applySnapModes(modes, announcing: kind.title)
    }

    @objc private func snapSelectAll(_ sender: Any?) {
        applySnapModes(SnapModes(), announcing: "全部")
    }

    @objc private func snapSelectStandard(_ sender: Any?) {
        applySnapModes(.basic, announcing: "基础")
    }

    /// Applying a target set is global: nothing is per-document, nothing is
    /// per-tool, so the next pick in any mode uses it immediately.
    func applySnapModes(_ modes: SnapModes, announcing what: String? = nil) {
        canvas.settings.snapModes = modes
        if modes.anyEnabled { canvas.settings.objectSnap = true }
        canvas.settings.save()
        refreshChromeState()
        canvas.snapResult = nil
        canvas.needsDisplay = true
        if let what {
            let armed = SnapKind.allCases.filter { modes.isEnabled($0) }.map(\.title)
            commandBar.setPrompt("捕捉点已更新（" + what + "）："
                + (armed.isEmpty ? "无" : armed.joined(separator: "、")))
        }
    }

    /// 指针是不是压在玻璃浮层上。
    ///
    /// 不用进出计数：布局页签住在底部条里，两层 tracking area 会各自进出，
    /// 计数很容易长期偏移。直接对当前鼠标位置做一次命中测试，答案只有对错。
    private func updateChromeHover() {
        guard let content = window?.contentView else { return }
        let point = content.convert(window?.mouseLocationOutsideOfEventStream ?? .zero,
                                    from: nil)
        var node: NSView? = content.hitTest(point)
        var inside = false
        while let view = node {
            if view is CADGlassSurface { inside = true; break }
            node = view.superview
        }
        canvas.pointerOverChrome = inside
    }

    /// 截图/自测用：用一串伪造的布局名替换页签栏，核对"模型和当前布局是否
    /// 被截断"这类排版问题——样例图纸只有模型页，真图里十几个布局才看得出。
    func debugSetLayoutTabs(_ names: [String], selected: Int) {
        layoutTabs.configure(names, selected: selected)
        layoutTabs.displayIfNeeded()
    }

    /// 自测用：把侧栏与工具岛的实际状态打出来（截图脚本核对"面板到底有没有
    /// 展开"，比盯着 PNG 猜要快）。
    func debugChromeDump() -> String {
        let s = sidebar.view
        let head = String(format: "sidebar frame=%@ hidden=%@ alpha=%.2f width=%.0f super=%@ toolbar=%@",
                          NSStringFromRect(s.frame), s.isHidden ? "YES" : "NO",
                          s.alphaValue, sidebarWidth.constant,
                          s.superview == nil ? "-" : "yes",
                          NSStringFromRect(toolbar.frame))
        return head + " " + sidebar.debugDump()
    }

    /// 供菜单动作调用：刷新工具栏/状态栏的开关态。
    func refreshChromeStatePublic() { refreshChromeState() }

    /// 外观（深/浅）切换后，把整套界面和画布配色重新算一遍。
    ///
    /// 画布的底色、纸面、以及 ACI 7 图元的线色是同一个 `Theme.isDark` 派生
    /// 出来的，三者必须一起换——只换底色就会出现"浅色画布上画白线"。
    func applyAppearanceChange() {
        Theme.refreshAppearance()
        window?.appearance = NSApp.appearance
        canvas.invalidateTiles()
        canvas.hatchView.invalidate()
        window?.contentView?.needsDisplay = true
        for chrome in [toolbar, palette, commandBar, statusBar, layoutTabs,
                       documentTabs, sidebar.view] {
            chrome.needsDisplay = true
        }
        sidebar.refresh()
        refreshChromeState()
    }

    private func refreshChromeState() {
        statusBar.updateSettings(canvas.settings, annotationsVisible: annotationsVisible)
        statusBar.updateZoom(canvas.transform.scale)
        if let document = cadDocument {
            statusBar.updateScale("单位 " + document.displayUnit.suffix)
        }
        palette.apply(settings: canvas.settings)
        palette.setEraseActive(canvas.eraseMode)
        toolbar.setActive(.erase, canvas.eraseMode)
        toolbar.setActive(.zoomWindow, canvas.zoomWindowMode)
        toolbar.setEnabled(.undo, canvas.undoManager?.canUndo ?? false)
        toolbar.setEnabled(.redo, canvas.undoManager?.canRedo ?? false)
    }

    // MARK: - 外部参照

    /// 缺参照时问一句：指定文件，还是先忽略。
    ///
    /// 参照的几何在另一个文件里，解析器救不回来——只能让用户指路。做成 sheet
    /// 而不是 modal，是因为"先看看这张图长什么样"也是合理选择。
    private func presentMissingXrefs(for document: CadDocument) {
        let missing = document.missingXrefs
        guard !missing.isEmpty, let window else { return }
        let alert = NSAlert()
        alert.messageText = "「\(document.fileName)」缺少 \(missing.count) 个外部参照"
        let listed = missing.prefix(6).map { "· " + $0.displayPath }.joined(separator: "\n")
        let more = missing.count > 6 ? "\n……另有 \(missing.count - 6) 个" : ""
        alert.informativeText = listed + more
            + "\n\n它们的图形存在别的文件里，不加载就画不出来。"
            + "如果这些文件就在本图所在目录，可以点「选择文件…」指一下位置。"
        alert.addButton(withTitle: "选择文件…")
        alert.addButton(withTitle: "忽略")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else {
                self.commandBar.setNotice("已忽略 \(missing.count) 个外部参照",
                                          detail: "重开图纸可以再选")
                return
            }
            self.chooseXrefFiles(for: document)
        }
    }

    private func chooseXrefFiles(for document: CadDocument) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DocumentTypes.all
        panel.allowsMultipleSelection = true
        panel.directoryURL = document.url.deletingLastPathComponent()
        panel.message = "选择外部参照文件（同名的会自动对上，其余按顺序接上）"
        panel.prompt = "加载"
        panel.begin { [weak self] response in
            guard let self, response == .OK else { return }
            var loaded = 0
            for url in panel.urls {
                let candidates = document.missingXrefIndexes
                guard !candidates.isEmpty else { break }
                let stem = url.deletingPathExtension().lastPathComponent.lowercased()
                let matched = candidates.first {
                    document.xrefInserts[$0].shortName.lowercased() == stem
                } ?? candidates.first {
                    document.xrefInserts[$0].shortName.lowercased().hasPrefix(stem)
                } ?? candidates[0]
                if document.attachXref(at: url, index: matched) { loaded += 1 }
            }
            document.invalidateDisplay()
            // 重新装一遍文档：几何变了，字符高度、空间索引、包围盒都要重算。
            self.canvas.document = document
            self.sidebar.document = document
            self.refreshSidebar()
            let left = document.missingXrefs.count
            self.commandBar.setNotice(
                loaded > 0 ? "已加载 \(loaded) 个外部参照" : "没有加载任何外部参照",
                detail: left > 0 ? "还有 \(left) 个未找到" : "外部参照齐全")
            if loaded > 0 { self.canvas.zoomToExtents(animated: true) }
        }
    }

    // MARK: Actions

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DocumentTypes.all
        panel.allowsMultipleSelection = true
        panel.message = "选择 DWG、DXF 或 PDF 图纸（可按住 ⌘ 多选，每张各占一个标签）"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls { self?.open(url: url) }
        }
    }

    @objc func toggleSidebar(_ sender: Any?) {
        toggleSidebar(selecting: nil)
    }

    /// 图层面板和标注面板是同一块侧栏的两个页签，两个工具栏按钮各开各的页：
    ///
    /// - 收起时点「图层」→ 打开并切到图层页
    /// - 已开着图层页时再点「图层」→ 收起（按钮就是开关）
    /// - 开着标注页时点「图层」→ 直接切过去，不收起
    ///
    /// 这条规则让两个按钮既能"打开"又能"关掉"，且不会出现"两个都亮着"的
    /// 状态——同时只可能有一页是打开的。
    private func toggleSidebar(selecting tab: Int?) {
        let collapsed = sidebarWidth.constant <= 1
        guard let tab else {
            sidebarWidth.constant = collapsed ? sidebarWidthValue : 0
            finishSidebarToggle()
            return
        }
        if collapsed {
            sidebar.selectTab(tab)
            sidebarWidth.constant = sidebarWidthValue
        } else if sidebar.currentTab == tab {
            sidebarWidth.constant = 0
        } else {
            sidebar.selectTab(tab)
        }
        finishSidebarToggle()
    }

    /// 侧栏开合：宽度弹簧式推开，内容同时淡入。
    ///
    /// 之前只在动画组里调了一次 `layoutSubtreeIfNeeded()`——约束是组外改的，
    /// 这一下等于没动，面板是硬跳出来的。必须打开隐式动画，让这次布局本身
    /// 走动画；收起时先别 hide，等动画跑完再隐藏，否则看不出它在收。
    private func finishSidebarToggle() {
        let open = sidebarWidth.constant > 0
        if open { sidebar.view.isHidden = false }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Theme.Motion.standard
            context.timingFunction = Theme.Motion.springCurve
            context.allowsImplicitAnimation = true
            sidebar.view.animator().alphaValue = open ? 1 : 0
            window?.contentView?.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            guard let self, self.sidebarWidth.constant == 0 else { return }
            self.sidebar.view.isHidden = true
        })
        toolbar.setActive(.layers, open && sidebar.currentTab == 0)
        toolbar.setActive(.annotations, open && sidebar.currentTab == 1)
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show(settings: canvas.settings) { [weak self] updated in
            self?.apply(settings: updated)
        }
    }

    @objc func deleteSelection(_ sender: Any?) { canvas.deleteSelection() }

    @objc func clearAnnotations(_ sender: Any?) {
        guard let cadDocument, !cadDocument.annotations.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "清除全部标注？"
        alert.informativeText = "当前图纸的 \(cadDocument.annotations.count) 条标注将被删除。"
        alert.addButton(withTitle: "清除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        cadDocument.annotations.removeAll()
        canvas.selectedAnnotation = nil
        canvas.commitAnnotationChange()
        refreshSidebar()
    }

    @objc func zoomInAction(_ sender: Any?) { canvas.zoom(by: 1.25) }
    @objc func zoomOutAction(_ sender: Any?) { canvas.zoom(by: 0.8) }
    @objc func zoomFitAction(_ sender: Any?) { canvas.zoomToExtents(animated: true) }
}

enum DocumentTypes {
    static var all: [UTType] {
        ["dwg", "dxf", "pdf"].compactMap { UTType(filenameExtension: $0) }
    }
}
