import AppKit

/// Right-hand dock: layers and measurements, the two lists a drafter keeps
/// open. Presented as one panel with a segmented header instead of two
/// separate floating inspectors, which is how the reference app's
/// 图层与显示 / 属性与测量记录 docks are used in practice.
final class SidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    var document: CadDocument? {
        didSet { updateHeaderForDocument(); refresh() }
    }

    var onLayerToggle: ((Int, Bool) -> Void)?
    var onSelectLayer: ((Int) -> Void)?
    var onSelectPage: ((Int) -> Void)?
    var onSelectAnnotation: ((Int) -> Void)?
    /// 双击一行：跳到图纸上的那条标注。
    var onActivateAnnotation: ((Int) -> Void)?
    var onToggleAnnotation: ((Int, Bool) -> Void)?
    var onDeleteAnnotation: ((Int) -> Void)?
    var onSelectStyle: ((AnnotationStyle) -> Void)?
    var onSelectInkColor: ((NSColor) -> Void)?

    private enum Tab: Int { case layers = 0, measurements = 1 }

    private let segmented = CADSidebarTabs()
    private let layersTable = NSTableView()
    private let annotationsTable = NSTableView()
    private let layersScroll = NSScrollView()
    private let annotationsScroll = NSScrollView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let footer = NSStackView()
    private let styleBar = NSView()
    private let stylePopup = NSPopUpButton()
    private let summary = NSTextField(labelWithString: "")
    private let colorWell = NSColorWell()
    /// Running totals for the annotation tab. A quantity surveyor reads the
    /// sheet to add up wall length and floor area, and doing that by hand from
    /// seven rows is where transcription mistakes come from.
    private let lengthTotal = NSTextField(labelWithString: "")
    private let areaTotal = NSTextField(labelWithString: "")
    /// 两行合计竖着放：272pt 宽的面板装不下"长度合计 24339mm 面积合计 63.38m²"
    /// 一行，横排时最后那个 m² 会被面板边缘切掉。
    private let totalsStack = NSStackView()
    private var footerButtons: [NSButton] = []

    override func loadView() {
        // 侧栏是浮在图纸右边的一块玻璃：材质从"钉在窗口边上的面板"变成
        // "一张压在图纸上的卡片"，层级由透明度和投影表达。
        let root = GlassPanel(radius: Glass.Radius.panel)

        segmented.configure(["图层", "标注"], selected: 0)
        segmented.onSelect = { [weak self] _ in self?.tabChanged() }
        segmented.translatesAutoresizingMaskIntoConstraints = false

        headerLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        headerLabel.textColor = Theme.groupTitle
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        annotationsTable.target = self
        annotationsTable.doubleAction = #selector(activateAnnotation)

        configure(table: layersTable, identifier: "layer")
        configure(table: annotationsTable, identifier: "annotation")
        layersScroll.documentView = layersTable
        annotationsScroll.documentView = annotationsTable
        for scroll in [layersScroll, annotationsScroll] {
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.borderType = .noBorder
        }
        annotationsScroll.isHidden = true

        buildStyleBar()
        buildFooter()

        for view in [segmented, headerLabel, layersScroll, annotationsScroll,
                     styleBar, footer] {
            root.addSubview(view)
        }

        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            segmented.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            segmented.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24),

            headerLabel.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 10),
            headerLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            headerLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            styleBar.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 6),
            styleBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            styleBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            styleBar.heightAnchor.constraint(equalToConstant: 26),

            layersScroll.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 6),
            layersScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            layersScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            layersScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -4),

            annotationsScroll.topAnchor.constraint(equalTo: styleBar.bottomAnchor, constant: 6),
            annotationsScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            annotationsScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            annotationsScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -4),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            footer.heightAnchor.constraint(equalToConstant: 32),
        ])
        view = root
        updateHeaderForDocument()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged),
            name: .cadLensThemeChanged, object: nil)
    }

    /// 截图/自测用：把面板自身的几何打出来，布局被撑坏时能一眼看出是谁。
    func debugDump() -> String {
        String(format: "root=%@ bounds=%@ seg=%@ style=%@ ann=%@ foot=%@ layers=%@",
               NSStringFromRect(view.frame), NSStringFromRect(view.bounds),
               NSStringFromRect(segmented.frame), NSStringFromRect(styleBar.frame),
               NSStringFromRect(annotationsScroll.frame),
               NSStringFromRect(footer.frame),
               NSStringFromRect(layersScroll.frame))
    }

    @objc private func themeChanged() {
        headerLabel.textColor = Theme.groupTitle
        layersTable.reloadData()
        annotationsTable.reloadData()
    }

    private func buildStyleBar() {
        styleBar.translatesAutoresizingMaskIntoConstraints = false
        styleBar.isHidden = true

        let label = NSTextField(labelWithString: "标注样式")
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        stylePopup.controlSize = .small
        stylePopup.font = NSFont.systemFont(ofSize: 11)
        stylePopup.translatesAutoresizingMaskIntoConstraints = false
        stylePopup.target = self
        stylePopup.action = #selector(styleChanged(_:))
        for style in AnnotationStyle.allCases {
            let item = NSMenuItem(title: style.shortTitle, action: nil, keyEquivalent: "")
            item.representedObject = style.rawValue
            stylePopup.menu?.addItem(item)
        }
        stylePopup.selectItem(at: AnnotationStyle.allCases.firstIndex(
            of: AnnotationRenderer.style) ?? 0)

        // Ink colour, right where the style is chosen: a dimension's colour is
        // part of its style, and hunting for it in a preferences window is how
        // the setting ends up unused.
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.target = self
        colorWell.action = #selector(inkColorChanged(_:))
        colorWell.toolTip = "标注颜色"
        if #available(macOS 13.0, *) {
            colorWell.colorWellStyle = .minimal
        }
        colorWell.color = AnnotationRenderer.inkOverride ?? Theme.measurementStroke

        summary.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        summary.textColor = .tertiaryLabelColor
        summary.alignment = .right
        summary.translatesAutoresizingMaskIntoConstraints = false

        styleBar.addSubview(label)
        styleBar.addSubview(stylePopup)
        styleBar.addSubview(colorWell)
        styleBar.addSubview(summary)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: styleBar.leadingAnchor, constant: 2),
            label.centerYAnchor.constraint(equalTo: styleBar.centerYAnchor),
            stylePopup.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            stylePopup.centerYAnchor.constraint(equalTo: styleBar.centerYAnchor),
            stylePopup.widthAnchor.constraint(equalToConstant: 88),
            colorWell.leadingAnchor.constraint(equalTo: stylePopup.trailingAnchor, constant: 6),
            colorWell.centerYAnchor.constraint(equalTo: styleBar.centerYAnchor),
            colorWell.widthAnchor.constraint(equalToConstant: 20),
            colorWell.heightAnchor.constraint(equalToConstant: 18),
            summary.trailingAnchor.constraint(equalTo: styleBar.trailingAnchor, constant: -2),
            summary.centerYAnchor.constraint(equalTo: styleBar.centerYAnchor),
            summary.leadingAnchor.constraint(greaterThanOrEqualTo: colorWell.trailingAnchor,
                                             constant: 6),
        ])
    }

    private func buildFooter() {
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 6
        footer.translatesAutoresizingMaskIntoConstraints = false
        let showAll = NSButton(title: "全部显示", target: self, action: #selector(showAllLayers))
        let hideAll = NSButton(title: "全部隐藏", target: self, action: #selector(hideAllLayers))
        for button in [showAll, hideAll] {
            button.bezelStyle = .inline
            button.isBordered = false
            button.controlSize = .mini
            button.font = NSFont.systemFont(ofSize: 11)
            button.contentTintColor = .secondaryLabelColor
            footer.addArrangedSubview(button)
            footerButtons.append(button)
        }
        footer.addArrangedSubview(NSView())

        totalsStack.orientation = .vertical
        totalsStack.alignment = .trailing
        totalsStack.spacing = 0
        totalsStack.isHidden = true
        for label in [lengthTotal, areaTotal] {
            label.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingHead
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            totalsStack.addArrangedSubview(label)
        }
        footer.addArrangedSubview(totalsStack)
    }

    private func configure(table: NSTableView, identifier: String) {
        table.identifier = NSUserInterfaceItemIdentifier(identifier)
        table.headerView = nil
        table.rowHeight = 28
        table.style = .plain
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = false
        table.usesAlternatingRowBackgroundColors = false
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier)))
    }

    // MARK: State

    private func updateHeaderForDocument() {
        let isPDF = document?.isPDF ?? false
        segmented.setTitle(isPDF ? "页面" : "图层", for: Tab.layers.rawValue)
        headerLabel.stringValue = isPDF ? "PDF 页面" : "图层"
        if isPDF {
            headerLabel.stringValue = "页面"
        }
    }

    /// Length and area added up over every *visible* annotation. Hidden rows are
    /// excluded on purpose: "隐藏" is how a reviewer sets a measurement aside
    /// while re-checking a room, and a total that ignored that would disagree
    /// with what is on the sheet.
    private func updateTotals(_ document: CadDocument) {
        var length: Double = 0
        var area: Double = 0
        var lengths = 0
        var areas = 0
        for annotation in document.annotations where !annotation.hidden {
            if annotation.kind.isArea {
                area += annotation.value
                areas += 1
            } else if annotation.kind.isLength {
                length += annotation.value
                lengths += 1
            }
        }
        lengthTotal.stringValue = lengths > 0
            ? "长度合计 \(document.formatLength(length, unit: true))" : "长度合计 —"
        areaTotal.stringValue = areas > 0
            ? "面积合计 \(document.formatArea(area))"
            : "面积合计 —"
        lengthTotal.toolTip = "已显示的 \(lengths) 条长度标注之和"
        areaTotal.toolTip = "已显示的 \(areas) 处面积标注之和"
        totalsStack.isHidden = segmented.selectedIndex == Tab.layers.rawValue
    }

    /// 当前打开的是哪一页（0 = 图层，1 = 标注）。
    var currentTab: Int { segmented.selectedIndex }

    func selectTab(_ index: Int) {
        guard index >= 0, index <= 1 else { return }
        segmented.select(index)
        applyTab()
    }

    private func tabChanged() {
        applyTab()
    }

    private var tabGeneration = 0
    private var hasShownTab = false

    private func applyTab(animated: Bool = true) {
        let layers = segmented.selectedIndex == Tab.layers.rawValue
        let incoming: NSView = layers ? layersScroll : annotationsScroll
        let outgoing: NSView = layers ? annotationsScroll : layersScroll

        headerLabel.isHidden = !layers
        styleBar.isHidden = layers
        for button in footerButtons { button.isHidden = !layers }
        totalsStack.isHidden = layers

        // 两页是同一块位置的两种列表，硬切会让内容看起来"闪了一下"。做一次
        // 交叉淡入（120ms，和 hover 同一节奏），结构件仍然瞬间切换——它们
        // 尺寸不同，跟着淡入反而像在抖。
        tabGeneration += 1
        let generation = tabGeneration
        outgoing.isHidden = false
        incoming.isHidden = false
        if incoming.superview === outgoing.superview {
            incoming.superview?.addSubview(incoming, positioned: .above,
                                           relativeTo: outgoing)
        }
        guard animated, hasShownTab, incoming.window != nil else {
            outgoing.isHidden = true
            outgoing.alphaValue = 1
            incoming.alphaValue = 1
            hasShownTab = true
            refresh()
            return
        }
        incoming.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Motion.hover
            context.timingFunction = Theme.Motion.easeOutCurve
            incoming.animator().alphaValue = 1
            outgoing.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // 快速连点时会有新的 applyTab 接手，旧的那次不许把新页收起来。
            guard let self, self.tabGeneration == generation else { return }
            outgoing.isHidden = true
            outgoing.alphaValue = 1
        }
        hasShownTab = true
        refresh()
    }

    func refresh() {
        layersTable.reloadData()
        annotationsTable.reloadData()
        if let document {
            summary.stringValue = "\(document.annotations.count) 条"
            updateTotals(document)
        }
        let visible = segmented.selectedIndex == Tab.layers.rawValue
        if visible, let document {
            headerLabel.stringValue = document.isPDF
                ? "PDF 页面 · \(document.spaces.count)"
                : "图层 · \(document.layers.count)"
        }
    }

    func selectPage(_ index: Int) {
        guard document?.isPDF == true, index >= 0,
              index < layersTable.numberOfRows else { return }
        layersTable.selectRowIndexes([index], byExtendingSelection: false)
        layersTable.scrollRowToVisible(index)
    }

    func selectAnnotation(_ id: UUID?) {
        guard let id, let document,
              let row = document.annotations.firstIndex(where: { $0.id == id }) else { return }
        segmented.select(Tab.measurements.rawValue)
        applyTab()
        guard row < annotationsTable.numberOfRows else { return }
        annotationsTable.selectRowIndexes([row], byExtendingSelection: false)
        annotationsTable.scrollRowToVisible(row)
    }

    @objc private func inkColorChanged(_ sender: NSColorWell) {
        onSelectInkColor?(sender.color)
    }

    /// Keeps the well in step when the colour is changed elsewhere (settings,
    /// a restored session).
    func reflectInkColor(_ color: NSColor) {
        colorWell.color = color
    }

    @objc private func styleChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let style = AnnotationStyle(rawValue: raw) else { return }
        onSelectStyle?(style)
    }

    @objc private func showAllLayers() {
        guard let document else { return }
        for index in document.layers.indices {
            document.layers[index].visible = true
            onLayerToggle?(index, true)
        }
        layersTable.reloadData()
    }

    @objc private func hideAllLayers() {
        guard let document else { return }
        for index in document.layers.indices {
            document.layers[index].visible = false
            onLayerToggle?(index, false)
        }
        layersTable.reloadData()
    }

    // MARK: Data source

    func numberOfRows(in tableView: NSTableView) -> Int {
        guard let document else { return 0 }
        if tableView === layersTable {
            return document.isPDF ? document.spaces.count : document.layers.count
        }
        return document.annotations.count
    }

    /// An annotation row carries two lines — type above, value below — so it
    /// needs more than the layer row's single line. At a shared 26 pt the type
    /// and the value were drawn on top of each other and the whole dock read
    /// as a list of overlapping numbers.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        tableView === annotationsTable ? 38 : 24
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let document else { return nil }
        // A table keeps its row count from the last `numberOfRows` call, so a
        // model change that lands between that call and this one asks for a row
        // that no longer exists — deleting every annotation did exactly that and
        // trapped on `annotations[row]`. The delegate has to defend itself.
        if tableView === layersTable {
            let count = document.isPDF ? document.spaces.count : document.layers.count
            guard row < count else { return NSTableCellView() }
            return document.isPDF ? pageCell(document: document, row: row)
                                  : layerCell(document: document, row: row)
        }
        guard row < document.annotations.count else { return NSTableCellView() }
        return annotationCell(document: document, row: row)
    }

    private func layerCell(document: CadDocument, row: Int) -> NSView {
        let cell = NSTableCellView()
        let layer = document.layers[row]

        let checkbox = NSButton(checkboxWithTitle: "", target: self,
                                action: #selector(toggleLayer(_:)))
        checkbox.state = layer.visible ? .on : .off
        checkbox.tag = row
        checkbox.controlSize = .mini
        checkbox.setContentHuggingPriority(.required, for: .horizontal)

        let swatch = NSView()
        swatch.wantsLayer = true
        swatch.layer?.backgroundColor = layer.color.cgColor
        swatch.layer?.borderWidth = 0.5
        swatch.layer?.borderColor = Theme.hairline.cgColor
        swatch.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            swatch.widthAnchor.constraint(equalToConstant: 10),
            swatch.heightAnchor.constraint(equalToConstant: 10),
        ])

        let name = NSTextField(labelWithString: layer.name)
        name.font = NSFont.systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let count = NSTextField(labelWithString: "\(layer.count)")
        count.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .tertiaryLabelColor
        count.alignment = .right
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.translatesAutoresizingMaskIntoConstraints = false

        let rowStack = NSStackView(views: [checkbox, swatch, name])
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 6
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(rowStack)
        cell.addSubview(count)
        cell.textField = name

        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            rowStack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: rowStack.trailingAnchor,
                                           constant: 6),
            count.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            count.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func pageCell(document: CadDocument, row: Int) -> NSView {
        let cell = NSTableCellView()
        let space = document.spaces[row]
        let name = NSTextField(labelWithString: space.name.isEmpty ? "第 \(row + 1) 页" : space.name)
        name.font = NSFont.systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        let size = NSTextField(labelWithString: String(format: "%.0f × %.0f",
                                                       space.box.width, space.box.height))
        size.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        size.textColor = .tertiaryLabelColor
        size.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(name)
        cell.addSubview(size)
        cell.textField = name
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            name.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            size.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            size.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func annotationCell(document: CadDocument, row: Int) -> NSView {
        let cell = NSTableCellView()
        let annotation = document.annotations[row]

        let visibility = NSButton()
        visibility.bezelStyle = .inline
        visibility.isBordered = false
        visibility.image = (annotation.hidden ? CADGlyph.eyeOff : CADGlyph.eye).image(size: 14)
        visibility.contentTintColor = annotation.hidden ? .tertiaryLabelColor
            : NSColor.secondaryLabelColor
        visibility.tag = row
        visibility.target = self
        visibility.action = #selector(toggleAnnotation(_:))
        visibility.toolTip = annotation.hidden ? "显示此标注" : "隐藏此标注"
        visibility.translatesAutoresizingMaskIntoConstraints = false

        let index = NSTextField(labelWithString: "\(row + 1)")
        index.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        // Grey, not the measurement green: in this dock green is the colour of
        // a value, and a green ordinal made the list look like it had two
        // measurements per row.
        index.textColor = .tertiaryLabelColor
        index.alignment = .right
        index.translatesAutoresizingMaskIntoConstraints = false

        let kind = NSTextField(labelWithString: annotation.kind.title)
        kind.font = NSFont.systemFont(ofSize: 11)
        kind.textColor = .secondaryLabelColor
        kind.translatesAutoresizingMaskIntoConstraints = false

        let value = NSTextField(labelWithString: annotation.displayText)
        value.font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
        value.textColor = annotation.hidden ? .tertiaryLabelColor : .labelColor
        value.lineBreakMode = .byTruncatingTail
        value.translatesAutoresizingMaskIntoConstraints = false

        let remove = NSButton()
        remove.bezelStyle = .inline
        remove.isBordered = false
        remove.image = CADGlyph.trash.image(size: 13)
        remove.contentTintColor = .tertiaryLabelColor
        remove.tag = row
        remove.target = self
        remove.action = #selector(deleteAnnotation(_:))
        remove.toolTip = "删除此标注"
        remove.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [kind, value])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 0
        textStack.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(visibility)
        cell.addSubview(index)
        cell.addSubview(textStack)
        cell.addSubview(remove)

        NSLayoutConstraint.activate([
            visibility.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            visibility.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            visibility.widthAnchor.constraint(equalToConstant: 16),

            index.leadingAnchor.constraint(equalTo: visibility.trailingAnchor, constant: 4),
            index.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            index.widthAnchor.constraint(equalToConstant: 16),

            textStack.leadingAnchor.constraint(equalTo: index.trailingAnchor, constant: 4),
            textStack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: remove.leadingAnchor,
                                                constant: -6),

            remove.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            remove.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            remove.widthAnchor.constraint(equalToConstant: 16),
        ])
        return cell
    }

    @objc private func toggleLayer(_ sender: NSButton) {
        guard let document, sender.tag < document.layers.count else { return }
        document.layers[sender.tag].visible = sender.state == .on
        onLayerToggle?(sender.tag, sender.state == .on)
    }

    @objc private func toggleAnnotation(_ sender: NSButton) {
        guard let document, sender.tag < document.annotations.count else { return }
        let next = document.annotations[sender.tag].hidden
        onToggleAnnotation?(sender.tag, next)
        annotationsTable.reloadData()
    }

    @objc private func activateAnnotation() {
        let row = annotationsTable.clickedRow >= 0 ? annotationsTable.clickedRow
                                                   : annotationsTable.selectedRow
        guard row >= 0 else { return }
        onActivateAnnotation?(row)
    }

    @objc private func deleteAnnotation(_ sender: NSButton) {
        onDeleteAnnotation?(sender.tag)
        annotationsTable.reloadData()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === annotationsTable {
            let row = table.selectedRow
            guard row >= 0 else { return }
            onSelectAnnotation?(row)
        } else {
            let row = layersTable.selectedRow
            guard row >= 0 else { return }
            if document?.isPDF == true {
                onSelectPage?(row)
            } else {
                onSelectLayer?(row)
            }
        }
    }
}
