import AppKit

/// 设置面板：一张玻璃卡片，左边分区、右边内容、底部固定操作条。
///
/// 从"一堆挤在一起的原生控件"改成有分区的卡片，是因为设置项已经从 6 个长到
/// 十几个（单位、精度、配色、标注样式、捕捉点、画质），一列排下来找不到东西。
/// 每一项都即时生效——没有"确定"要按，底部那颗只是关窗。
final class SettingsWindowController: NSWindowController {

    static let shared = SettingsWindowController()

    private var onChange: ((CadSettings) -> Void)?
    private var settings = CadSettings()

    private let card = GlassPanel(radius: Glass.Radius.panel)
    private let sectionList = NSStackView()
    private let contentHost = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var sectionButtons: [SettingsSectionButton] = []
    private var currentSection = 0

    /// 右侧每一区的控件都留着引用：切换分区时不必重建，值也不会掉。
    private let unitPopup = NSPopUpButton()
    private let areaUnitPopup = NSPopUpButton()
    private let precisionStepper = NSStepper()
    private let precisionLabel = NSTextField(labelWithString: "0")
    private let qualityPopup = NSPopUpButton()
    private let stylePopup = NSPopUpButton()
    /// 端符：箭头 / 45° 短斜线。建筑图习惯斜线，机械图习惯箭头，两边都要有。
    private let markerSegment = NSSegmentedControl(labels: ["箭头", "短斜线"],
                                                   trackingMode: .selectOne,
                                                   target: nil, action: nil)
    private let inkWell = NSColorWell()
    private let scaleWithDrawing = NSSwitch()
    private let snapMaster = NSSwitch()
    private let orthoSwitch = NSSwitch()
    private let lineweightSwitch = NSSwitch()
    private let gridSwitch = NSSwitch()
    private let crosshairSwitch = NSSwitch()
    private var toneButtons: [NSButton] = []
    private var snapButtons: [(SnapKind, NSButton)] = []

    private enum Section: Int, CaseIterable {
        case display, annotation, snap, quality
        var title: String {
            switch self {
            case .display: return "显示"
            case .annotation: return "标注"
            case .snap: return "对象捕捉"
            case .quality: return "画质与性能"
            }
        }
        var subtitle: String {
            switch self {
            case .display: return "单位、精度与画布外观"
            case .annotation: return "尺寸的画法与墨色"
            case .snap: return "量图时能吸住哪些点"
            case .quality: return "渲染质量与显示开关"
            }
        }
    }

    private init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 860, height: 520),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "设置"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        buildContent()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged),
            name: .cadLensThemeChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func themeChanged() {
        window?.contentView?.applyThemeRecursively()
        refreshSectionButtons()
    }

    // MARK: 外观

    private func buildContent() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.chromeSunken.cgColor

        card.translatesAutoresizingMaskIntoConstraints = false
        card.elevated = true
        content.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            card.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        // 左：分区
        let rail = NSView()
        rail.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(rail)

        let mark = BrandMark()
        mark.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: "设置")
        name.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        name.textColor = Glass.primaryText
        name.translatesAutoresizingMaskIntoConstraints = false

        sectionList.orientation = .vertical
        sectionList.alignment = .leading
        sectionList.spacing = 2
        sectionList.translatesAutoresizingMaskIntoConstraints = false
        rail.addSubview(mark)
        rail.addSubview(name)
        rail.addSubview(sectionList)

        let version = NSTextField(labelWithString: "CadLens 1.8\nmacOS 12+")
        version.font = NSFont.systemFont(ofSize: 10.5)
        version.textColor = Glass.tertiaryText
        version.maximumNumberOfLines = 2
        version.translatesAutoresizingMaskIntoConstraints = false
        rail.addSubview(version)

        for section in Section.allCases {
            let button = SettingsSectionButton(title: section.title)
            button.onSelect = { [weak self] in self?.select(section.rawValue) }
            sectionButtons.append(button)
            sectionList.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: 162).isActive = true
        }

        let rule = GlassSeparator()
        rule.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(rule)

        // 右：内容
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(contentHost)

        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = Glass.primaryText
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = Glass.tertiaryText
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            rail.topAnchor.constraint(equalTo: card.topAnchor),
            rail.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            rail.widthAnchor.constraint(equalToConstant: 186),

            mark.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: 18),
            mark.topAnchor.constraint(equalTo: rail.topAnchor, constant: 18),
            mark.widthAnchor.constraint(equalToConstant: 24),
            mark.heightAnchor.constraint(equalToConstant: 24),
            name.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: mark.centerYAnchor),

            sectionList.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: 12),
            sectionList.trailingAnchor.constraint(equalTo: rail.trailingAnchor, constant: -12),
            sectionList.topAnchor.constraint(equalTo: mark.bottomAnchor, constant: 18),

            version.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: 20),
            version.bottomAnchor.constraint(equalTo: rail.bottomAnchor, constant: -18),

            rule.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            rule.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            rule.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            rule.widthAnchor.constraint(equalToConstant: 1),

            contentHost.leadingAnchor.constraint(equalTo: rule.trailingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: card.topAnchor),
            contentHost.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        // 铁路轨道一样的标题行：标题 + 一句说明，跟着分区换。
        let heading = NSStackView(views: [titleLabel, subtitleLabel])
        heading.orientation = .horizontal
        heading.alignment = .firstBaseline
        heading.spacing = 10
        heading.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(heading)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor, constant: 24),
            heading.topAnchor.constraint(equalTo: contentHost.topAnchor, constant: 20),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: contentHost.trailingAnchor,
                                              constant: -24),
        ])

        configureControls()
        buildFooter()
        select(0)
    }

    private func configureControls() {
        for unit in MeasureUnit.allCases { unitPopup.addItem(withTitle: unitTitle(unit)) }
        for unit in AreaUnit.allCases { areaUnitPopup.addItem(withTitle: areaUnitTitle(unit)) }
        for popup in [unitPopup, areaUnitPopup] {
            popup.font = NSFont.systemFont(ofSize: 12.5)
            popup.target = self
            popup.action = #selector(changed)
            popup.widthAnchor.constraint(equalToConstant: 180).isActive = true
        }

        precisionStepper.minValue = 0
        precisionStepper.maxValue = 4
        precisionStepper.increment = 1
        precisionStepper.target = self
        precisionStepper.action = #selector(changed)
        precisionLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        precisionLabel.textColor = Glass.primaryText

        qualityPopup.addItems(withTitles: ["一般（最快）", "精细", "极致"])
        qualityPopup.target = self
        qualityPopup.action = #selector(changed)
        qualityPopup.font = NSFont.systemFont(ofSize: 12.5)
        qualityPopup.widthAnchor.constraint(equalToConstant: 180).isActive = true

        for style in AnnotationStyle.allCases {
            let item = NSMenuItem(title: style.title, action: nil, keyEquivalent: "")
            item.representedObject = style.rawValue
            stylePopup.menu?.addItem(item)
        }
        stylePopup.target = self
        stylePopup.action = #selector(changed)
        stylePopup.font = NSFont.systemFont(ofSize: 12.5)
        stylePopup.widthAnchor.constraint(equalToConstant: 180).isActive = true

        markerSegment.target = self
        markerSegment.action = #selector(changed)
        markerSegment.font = NSFont.systemFont(ofSize: 12)
        markerSegment.segmentStyle = .rounded
        markerSegment.widthAnchor.constraint(equalToConstant: 180).isActive = true
        markerSegment.toolTip = "尺寸线两端的符号"

        inkWell.target = self
        inkWell.action = #selector(changed)
        inkWell.toolTip = "标注墨色"
        if #available(macOS 13.0, *) { inkWell.colorWellStyle = .minimal }
        inkWell.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            inkWell.widthAnchor.constraint(equalToConstant: 26),
            inkWell.heightAnchor.constraint(equalToConstant: 22),
        ])

        for control in [scaleWithDrawing, snapMaster, orthoSwitch,
                        lineweightSwitch, gridSwitch, crosshairSwitch] {
            control.target = self
            control.action = #selector(changed)
        }

        for tone in CanvasTone.allCases {
            let button = NSButton(title: "", target: self, action: #selector(tonePicked(_:)))
            button.isBordered = false
            button.tag = CanvasTone.allCases.firstIndex(of: tone) ?? 0
            button.toolTip = tone.title
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 46),
                button.heightAnchor.constraint(equalToConstant: 30),
            ])
            toneButtons.append(button)
        }

        for kind in SnapKind.allCases {
            let button = NSButton(checkboxWithTitle: kind.title, target: self,
                                  action: #selector(snapKindChanged))
            button.font = NSFont.systemFont(ofSize: 12)
            snapButtons.append((kind, button))
        }
    }

    private func buildFooter() {
        let hint = NSTextField(labelWithString: "修改即时生效")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = Glass.tertiaryText
        hint.translatesAutoresizingMaskIntoConstraints = false

        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetDefaults))
        reset.bezelStyle = .rounded
        reset.font = NSFont.systemFont(ofSize: 12)
        reset.translatesAutoresizingMaskIntoConstraints = false

        let done = NSButton(title: "完成", target: self, action: #selector(finish))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.font = NSFont.systemFont(ofSize: 12)
        done.translatesAutoresizingMaskIntoConstraints = false

        contentHost.addSubview(hint)
        contentHost.addSubview(reset)
        contentHost.addSubview(done)
        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor, constant: 24),
            hint.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor, constant: -20),
            done.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor, constant: -24),
            done.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor, constant: -18),
            done.widthAnchor.constraint(equalToConstant: 82),
            reset.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -8),
            reset.centerYAnchor.constraint(equalTo: done.centerYAnchor),
            reset.widthAnchor.constraint(equalToConstant: 92),
        ])
    }

    // MARK: 分区内容

    /// 截图脚本用：把面板直接切到某一分区（0 显示 / 1 标注 / 2 捕捉 / 3 质量）。
    func showSection(_ index: Int) { select(index) }

    private func select(_ index: Int) {
        guard let section = Section(rawValue: index) else { return }
        currentSection = index
        titleLabel.stringValue = section.title
        subtitleLabel.stringValue = section.subtitle
        refreshSectionButtons()

        // 上一次分区的内容整块摘掉；标题行与底部条是常驻的。
        sectionBody?.removeFromSuperview()
        let body = NSStackView()
        sectionBody = body
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 0
        body.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor, constant: 24),
            body.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor, constant: -24),
            body.topAnchor.constraint(equalTo: contentHost.topAnchor, constant: 58),
            body.bottomAnchor.constraint(lessThanOrEqualTo: contentHost.bottomAnchor,
                                         constant: -64),
        ])

        switch section {
        case .display:
            body.addArrangedSubview(row("长度单位", "图上数值的换算基准", unitPopup))
            body.addArrangedSubview(row("面积单位", "面积标注与侧栏合计共用", areaUnitPopup))
            let stepper = NSStackView(views: [precisionLabel, precisionStepper])
            stepper.orientation = .horizontal
            stepper.spacing = 8
            stepCounter = stepper
            body.addArrangedSubview(row("小数位数", "长度与坐标的小数点后位数", stepper))
            body.addArrangedSubview(row("画布配色", "界面深浅跟随画布", toneStrip()))
        case .annotation:
            body.addArrangedSubview(row("标注样式", "字高、线宽与界线长度", stylePopup))
            body.addArrangedSubview(row("尺寸线端符", "箭头或建筑 45° 短斜线", markerSegment))
            body.addArrangedSubview(row("标注颜色", "覆盖样式默认墨色", inkWell))
            body.addArrangedSubview(row("跟随图纸缩放", "关：标注保持屏幕尺寸；开：随图纸缩放",
                                        scaleWithDrawing))
        case .snap:
            body.addArrangedSubview(row("启用对象捕捉", "F3 总开关", snapMaster))
            let grid = NSStackView()
            grid.orientation = .vertical
            grid.alignment = .leading
            grid.spacing = 6
            for (_, button) in snapButtons { grid.addArrangedSubview(button) }
            body.addArrangedSubview(row("捕捉点", "量图时吸住这些位置", grid, stacked: true))
            body.addArrangedSubview(row("正交约束", "F8：只走水平与竖直", orthoSwitch))
        case .quality:
            body.addArrangedSubview(row("画布质量", "细节越多越慢", qualityPopup))
            body.addArrangedSubview(row("显示 CAD 线宽", "关掉后所有线一样细", lineweightSwitch))
            body.addArrangedSubview(row("显示栅格", "F7", gridSwitch))
            body.addArrangedSubview(row("显示十字光标", "全屏十字与取景框", crosshairSwitch))
        }
        reload()
    }

    private var stepCounter: NSStackView?
    private var sectionBody: NSStackView?

    private func row(_ title: String, _ detail: String, _ control: NSView,
                     stacked: Bool = false) -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: title)
        name.font = NSFont.systemFont(ofSize: 12.5)
        name.textColor = Glass.primaryText
        name.translatesAutoresizingMaskIntoConstraints = false
        let note = NSTextField(wrappingLabelWithString: detail)
        note.font = NSFont.systemFont(ofSize: 10.5)
        note.textColor = Glass.tertiaryText
        note.maximumNumberOfLines = 1
        note.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false

        let divider = GlassSeparator(vertical: false)
        divider.translatesAutoresizingMaskIntoConstraints = false

        wrap.addSubview(name)
        wrap.addSubview(note)
        wrap.addSubview(control)
        wrap.addSubview(divider)
        NSLayoutConstraint.activate([
            wrap.widthAnchor.constraint(equalToConstant: 600),
            name.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            name.topAnchor.constraint(equalTo: wrap.topAnchor, constant: stacked ? 10 : 12),
            note.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            note.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),

            control.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            note.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -16),

            divider.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            wrap.bottomAnchor.constraint(greaterThanOrEqualTo: control.bottomAnchor,
                                         constant: 12),
            wrap.bottomAnchor.constraint(greaterThanOrEqualTo: note.bottomAnchor, constant: 12),
        ])
        return wrap
    }

    private func toneStrip() -> NSView {
        let strip = NSStackView(views: toneButtons)
        strip.orientation = .horizontal
        strip.spacing = 8
        return strip
    }

    private func refreshSectionButtons() {
        for (index, button) in sectionButtons.enumerated() {
            button.isActive = index == currentSection
        }
        for (index, button) in toneButtons.enumerated() {
            let tone = CanvasTone.allCases[index]
            button.image = toneSwatch(tone, selected: tone == Theme.canvasTone)
        }
        for (kind, button) in snapButtons {
            button.state = settings.snapModes.isEnabled(kind) ? .on : .off
            button.isEnabled = settings.objectSnap
        }
    }

    /// 三块画布配色样本：深、浅、跟随系统（半深半浅）。
    private func toneSwatch(_ tone: CanvasTone, selected: Bool) -> NSImage {
        let size = NSSize(width: 46, height: 30)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        switch tone {
        case .dark: NSColor(srgbRed: 0.06, green: 0.07, blue: 0.09, alpha: 1).setFill()
        case .light: NSColor.white.setFill()
        case .auto:
            NSColor.white.setFill()
            path.fill()
            NSColor(srgbRed: 0.06, green: 0.07, blue: 0.09, alpha: 1).setFill()
            NSRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height).fill()
        }
        if tone != .auto { path.fill() }
        (selected ? Theme.accent : Glass.separator).setStroke()
        path.lineWidth = selected ? 2 : 1
        path.stroke()
        image.unlockFocus()
        return image
    }

    // MARK: 数据

    func show(settings: CadSettings, onChange: @escaping (CadSettings) -> Void) {
        self.settings = settings
        self.onChange = onChange
        reload()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 面板上要显示哪一种端符：用户钉过就用钉的，没钉过就跟当前样式走。
    private var currentMarker: AnnotationMarker {
        if let pinned = AnnotationMarker(rawValue: settings.annotationMarker) { return pinned }
        return AnnotationStyle(rawValue: settings.annotationStyle)?.metrics.marker
            ?? .architecturalTick
    }

    private func reload() {
        unitPopup.selectItem(at: settings.displayUnit.rawValue)
        areaUnitPopup.selectItem(at: settings.areaUnit.rawValue)
        precisionStepper.integerValue = settings.precision
        precisionLabel.stringValue = "\(settings.precision)"
        lineweightSwitch.state = settings.showLineweights ? .on : .off
        gridSwitch.state = settings.showGrid ? .on : .off
        crosshairSwitch.state = settings.showCrosshair ? .on : .off
        snapMaster.state = settings.objectSnap ? .on : .off
        orthoSwitch.state = settings.orthoMode ? .on : .off
        scaleWithDrawing.state = settings.annotationScalesWithDrawing ? .on : .off
        qualityPopup.selectItem(at: min(max(settings.canvasQuality, 0), 2))
        if let index = AnnotationStyle.allCases.firstIndex(where: {
            $0.rawValue == settings.annotationStyle }) {
            stylePopup.selectItem(at: index)
        }
        markerSegment.selectedSegment = currentMarker.usesTickGlyph ? 1 : 0
        inkWell.color = NSColor(hex: settings.annotationColorHex) ?? Theme.measurementStroke
        refreshSectionButtons()
    }

    @objc private func tonePicked(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < CanvasTone.allCases.count else { return }
        Theme.canvasTone = CanvasTone.allCases[sender.tag]
        refreshSectionButtons()
    }

    @objc private func snapKindChanged() {
        var modes = settings.snapModes
        for (kind, button) in snapButtons {
            modes.set(kind, button.state == .on)
        }
        settings.snapModes = modes
        if modes.anyEnabled { settings.objectSnap = true }
        settings.save()
        reload()
        onChange?(settings)
    }

    @objc private func changed() {
        settings.displayUnit = MeasureUnit(rawValue: unitPopup.indexOfSelectedItem) ?? .millimeter
        settings.areaUnit = AreaUnit(rawValue: areaUnitPopup.indexOfSelectedItem) ?? .squareMeter
        settings.precision = precisionStepper.integerValue
        precisionLabel.stringValue = "\(settings.precision)"
        settings.showLineweights = lineweightSwitch.state == .on
        settings.showGrid = gridSwitch.state == .on
        settings.showCrosshair = crosshairSwitch.state == .on
        settings.objectSnap = snapMaster.state == .on
        settings.orthoMode = orthoSwitch.state == .on
        settings.canvasQuality = qualityPopup.indexOfSelectedItem
        settings.annotationScalesWithDrawing = scaleWithDrawing.state == .on
        if let raw = stylePopup.selectedItem?.representedObject as? String {
            settings.annotationStyle = raw
        }
        settings.annotationMarker = markerSegment.selectedSegment == 1
            ? AnnotationMarker.architecturalTick.rawValue
            : AnnotationMarker.filledArrow.rawValue
        let ink = inkWell.color
        settings.annotationColorHex = ink.isEqual(Theme.measurementStroke) ? "" : ink.hexString
        settings.save()
        refreshSectionButtons()
        onChange?(settings)
    }

    @objc private func resetDefaults() {
        settings = CadSettings()
        settings.save()
        reload()
        onChange?(settings)
    }

    @objc private func finish() {
        window?.orderOut(nil)
        window?.close()
    }

    private func unitTitle(_ unit: MeasureUnit) -> String {
        switch unit {
        case .millimeter: return "毫米 (mm)"
        case .centimeter: return "厘米 (cm)"
        case .meter: return "米 (m)"
        case .kilometer: return "千米 (km)"
        case .inch: return "英寸 (in)"
        case .foot: return "英尺 (ft)"
        }
    }

    private func areaUnitTitle(_ unit: AreaUnit) -> String {
        switch unit {
        case .squareMillimeter: return "平方毫米 (mm²)"
        case .squareCentimeter: return "平方厘米 (cm²)"
        case .squareMeter: return "平方米 (m²)"
        case .hectare: return "公顷 (ha)"
        case .squareInch: return "平方英寸 (in²)"
        case .squareFoot: return "平方英尺 (ft²)"
        }
    }
}

/// 设置左栏的分区项：选中的是一块蓝底白字，未选中只有文字。
private final class SettingsSectionButton: NSView {
    var onSelect: (() -> Void)?
    var isActive = false { didSet { needsDisplay = true } }

    private let title: String
    private var hovering = false { didSet { needsDisplay = true } }

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true
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
            .font: NSFont.systemFont(ofSize: 12, weight: isActive ? .semibold : .regular),
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
