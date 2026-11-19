import AppKit
import CoreServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: MainWindowController?
    /// 视图 ▸ 对象捕捉 的子菜单，内容由主窗口按当前设置填充。
    private var snapSubmenu: NSMenu?
    /// 视图 ▸ 画布配色 的子菜单，勾选态跟着当前画布深浅走。
    private var toneSubmenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DevelopmentHarness.applyRequestedAppearance()
        NSApp.mainMenu = buildMenu()
        if mainWindow == nil {
            let controller = MainWindowController()
            mainWindow = controller
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        }
        // Filled once the window owns the settings; the delegate keeps it in
        // step afterwards. Building it lazily only on first open would leave
        // F3 unregistered until the user happened to open the menu.
        if let window = mainWindow, let menu = snapSubmenu {
            window.populateSnapMenu(menu)
        }
        NSApp.activate(ignoringOtherApps: true)

        let arguments = CommandLine.arguments.dropFirst()
        if let path = arguments.first(where: { !$0.hasPrefix("-") }) {
            open(url: URL(fileURLWithPath: path))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // 拖进来一叠图纸就一叠全开：每张一个标签，这是多图纸该有的样子。
        guard !urls.isEmpty else { return }
        if mainWindow == nil {
            let controller = MainWindowController()
            mainWindow = controller
            controller.showWindow(nil)
        }
        mainWindow?.window?.makeKeyAndOrderFront(nil)
        for url in urls { mainWindow?.open(url: url) }
    }

    func open(url: URL) {
        if mainWindow == nil {
            let controller = MainWindowController()
            mainWindow = controller
            controller.showWindow(nil)
        }
        mainWindow?.window?.makeKeyAndOrderFront(nil)
        mainWindow?.open(url: url)
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        // Application menu
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let appName = "速看CAD"
        appMenu.addItem(withTitle: "关于 \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings(_:)),
                                  keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        let defaultHandler = NSMenuItem(title: "设为默认 DWG/DXF 打开方式",
                                        action: #selector(setDefaultCADHandler(_:)),
                                        keyEquivalent: "")
        defaultHandler.target = self
        appMenu.addItem(defaultHandler)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 \(appName)",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "隐藏其他",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "全部显示",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 \(appName)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // File
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        let open = NSMenuItem(title: "打开…", action: #selector(openDocument(_:)),
                              keyEquivalent: "o")
        open.target = self
        fileMenu.addItem(open)
        let recent = NSMenuItem(title: "打开最近使用", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "打开最近使用")
        recentMenu.delegate = self
        recent.submenu = recentMenu
        fileMenu.addItem(recent)
        fileMenu.addItem(.separator())
        // 打印排在最前：图纸最终的出口是纸。两条路对应两种实际动作——
        // 打一块区域（放大节点、局部说明）和按布局图框整份出图。
        let preview = NSMenuItem(title: "选区打印…", action: #selector(printSelection(_:)),
                                 keyEquivalent: "p")
        preview.target = self
        fileMenu.addItem(preview)
        let printItem = NSMenuItem(title: "打印图纸…", action: #selector(printDrawing(_:)),
                                   keyEquivalent: "p")
        printItem.keyEquivalentModifierMask = [.command, .option]
        printItem.target = self
        fileMenu.addItem(printItem)
        fileMenu.addItem(.separator())
        let closeDoc = NSMenuItem(title: "关闭图纸", action: #selector(closeDocument(_:)),
                                  keyEquivalent: "w")
        closeDoc.target = self
        fileMenu.addItem(closeDoc)
        let closeWindow = NSMenuItem(title: "关闭窗口",
                                     action: #selector(NSWindow.performClose(_:)),
                                     keyEquivalent: "w")
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(closeWindow)
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        // 窗口：这里放的是图纸之间的切换，不是系统窗口列表。看图时同时开着
        // 平面、立面、总平面是常态，⌃⇥ 换一张比去标签上找快。
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        let next = NSMenuItem(title: "下一张图纸", action: #selector(nextDocument(_:)),
                              keyEquivalent: "\t")
        next.keyEquivalentModifierMask = [.control]
        next.target = self
        windowMenu.addItem(next)
        let previous = NSMenuItem(title: "上一张图纸", action: #selector(previousDocument(_:)),
                                  keyEquivalent: "\t")
        previous.keyEquivalentModifierMask = [.control, .shift]
        previous.target = self
        windowMenu.addItem(previous)
        windowMenu.addItem(.separator())
        for number in 1...9 {
            let item = NSMenuItem(title: "第 \(number) 张图纸",
                                  action: #selector(activateDocumentNumber(_:)),
                                  keyEquivalent: "\(number)")
            item.keyEquivalentModifierMask = [.command]
            item.tag = number
            item.target = self
            windowMenu.addItem(item)
        }
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        // Edit
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        let delete = NSMenuItem(title: "删除标注", action: #selector(deleteSelection(_:)),
                                keyEquivalent: "\u{8}")
        delete.target = self
        editMenu.addItem(delete)
        let clearAll = NSMenuItem(title: "清除全部标注", action: #selector(clearAnnotations(_:)),
                                  keyEquivalent: "\u{8}")
        clearAll.keyEquivalentModifierMask = [.command, .shift]
        clearAll.target = self
        editMenu.addItem(clearAll)
        editItem.submenu = editMenu
        main.addItem(editItem)

        // View
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "视图")
        add(viewMenu, "放大", #selector(zoomIn(_:)), "+")
        add(viewMenu, "缩小", #selector(zoomOut(_:)), "-")
        add(viewMenu, "显示全图", #selector(zoomFit(_:)), "0")
        viewMenu.addItem(.separator())
        let snapItem = NSMenuItem(title: "对象捕捉", action: nil, keyEquivalent: "")
        let snapMenu = NSMenu(title: "对象捕捉")
        snapMenu.delegate = self
        snapItem.submenu = snapMenu
        snapSubmenu = snapMenu
        viewMenu.addItem(snapItem)
        add(viewMenu, "正交", #selector(toggleOrthoMenu(_:)), "f8")
        add(viewMenu, "栅格", #selector(toggleGrid(_:)), "f7")
        add(viewMenu, "显示线宽", #selector(toggleLineweightMenu(_:)), "l")
        viewMenu.addItem(.separator())
        // 只有画布配色需要用户切换；界面始终跟随系统外观，不再有主题菜单。
        let toneItem = NSMenuItem(title: "画布配色", action: nil, keyEquivalent: "")
        let tones = NSMenu(title: "画布配色")
        tones.delegate = self
        toneItem.submenu = tones
        toneSubmenu = tones
        viewMenu.addItem(toneItem)
        viewMenu.addItem(.separator())
        let sidebar = NSMenuItem(title: "信息面板", action: #selector(toggleSidebar(_:)),
                                 keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .option]
        sidebar.target = self
        viewMenu.addItem(sidebar)
        viewMenu.addItem(.separator())
        let fullScreen = NSMenuItem(title: "进入全屏幕",
                                    action: #selector(toggleFullScreenAction(_:)),
                                    keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        fullScreen.target = self
        viewMenu.addItem(fullScreen)
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        // Measure
        let measureItem = NSMenuItem()
        let measureMenu = NSMenu(title: "测量")
        let shortcuts: [(MeasureKind, String)] = [
            (.aligned, "a"), (.linear, "l"), (.continuous, "c"), (.rectangle, "r"),
            (.polygon, "p"), (.circleArea, "o"), (.hatchArea, "f"), (.radius, "d"),
            (.angle, "g"), (.arcLength, "k"), (.sideArea, "s"), (.note, "t"),
        ]
        for (kind, key) in shortcuts {
            let item = NSMenuItem(title: kind.title, action: #selector(selectMeasureTool(_:)),
                                  keyEquivalent: key)
            item.representedObject = kind.rawValue
            item.target = self
            measureMenu.addItem(item)
        }
        measureItem.submenu = measureMenu
        main.addItem(measureItem)

        // Help
        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "帮助")
        let usage = NSMenuItem(title: "使用说明", action: #selector(showHelp(_:)),
                               keyEquivalent: "?")
        usage.target = self
        helpMenu.addItem(usage)
        let support = NSMenuItem(title: "支持作者…", action: #selector(showSupport(_:)),
                                 keyEquivalent: "")
        support.target = self
        helpMenu.addItem(support)
        helpItem.submenu = helpMenu
        main.addItem(helpItem)

        return main
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    // MARK: Actions

    @objc private func openDocument(_ sender: Any?) { mainWindow?.openDocument(sender) }

    @objc private func closeDocument(_ sender: Any?) { mainWindow?.closeActiveDocument(sender) }

    @objc private func nextDocument(_ sender: Any?) { mainWindow?.cycleDocument(1) }

    @objc private func previousDocument(_ sender: Any?) { mainWindow?.cycleDocument(-1) }

    @objc private func activateDocumentNumber(_ sender: NSMenuItem) {
        mainWindow?.activateDocument(number: sender.tag)
    }
    @objc private func showSettings(_ sender: Any?) { mainWindow?.showSettings(sender) }
    @objc private func printSelection(_ sender: Any?) {
        guard let mainWindow else { return }
        PrintCommands.beginSelectionPrint(from: mainWindow)
    }
    @objc private func printDrawing(_ sender: Any?) {
        guard let mainWindow else { return }
        PrintCommands.printDrawing(from: mainWindow)
    }
    @objc private func deleteSelection(_ sender: Any?) { mainWindow?.deleteSelection(sender) }

    @objc private func clearAnnotations(_ sender: Any?) { mainWindow?.clearAnnotations(sender) }
    @objc private func zoomIn(_ sender: Any?) { mainWindow?.zoomInAction(sender) }
    @objc private func zoomOut(_ sender: Any?) { mainWindow?.zoomOutAction(sender) }
    @objc private func zoomFit(_ sender: Any?) { mainWindow?.zoomFitAction(sender) }
    @objc private func toggleSidebar(_ sender: Any?) { mainWindow?.toggleSidebar(sender) }

    @objc private func toggleFullScreenAction(_ sender: Any?) {
        guard let window = mainWindow?.window else { return }
        window.toggleFullScreen(sender)
    }

    @objc private func pickCanvasTone(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < CanvasTone.allCases.count else { return }
        Theme.canvasTone = CanvasTone.allCases[sender.tag]
        if let menu = sender.menu {
            for item in menu.items where item.tag >= 0 { item.state = item.tag == sender.tag ? .on : .off }
        }
    }

    @objc private func toggleSnapMenu(_ sender: Any?) {
        guard let canvas = mainWindow?.canvas else { return }
        canvas.settings.objectSnap.toggle()
        canvas.settings.save()
        mainWindow?.refreshChromeStatePublic()
        canvas.onPromptChanged?(canvas.settings.objectSnap ? "对象捕捉：开启" : "对象捕捉：关闭")
    }

    @objc private func toggleOrthoMenu(_ sender: Any?) {
        guard let canvas = mainWindow?.canvas else { return }
        canvas.settings.orthoMode.toggle()
        canvas.settings.save()
        canvas.onPromptChanged?(canvas.settings.orthoMode ? "正交：开启" : "正交：关闭")
    }

    @objc private func toggleGrid(_ sender: Any?) {
        guard let canvas = mainWindow?.canvas else { return }
        canvas.settings.showGrid.toggle()
        canvas.settings.save()
        canvas.needsDisplay = true
    }

    @objc private func toggleLineweightMenu(_ sender: Any?) {
        guard let canvas = mainWindow?.canvas else { return }
        canvas.settings.showLineweights.toggle()
        canvas.settings.save()
        canvas.invalidateTiles()
    }

    @objc private func selectMeasureTool(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = MeasureKind(rawValue: raw) else { return }
        let canvas = mainWindow?.canvas
        canvas?.activeTool = canvas?.activeTool == kind ? nil : kind
    }

    /// 菜单里的「使用说明」和命令 `?` 走同一个窗口：之前菜单还留着一个
    /// NSAlert 弹框，用户点菜单看到的是旧内容，另做的说明窗口根本没打开。
    @objc private func showHelp(_ sender: Any?) {
        HelpWindowController.shared.show()
    }

    @objc private func showSupport(_ sender: Any?) {
        // Index 8 is the “支持作者” section appended to HelpWindowController.
        HelpWindowController.shared.show(section: 8)
    }

    /// The Finder default can also be changed in Get Info, but a one-click
    /// entry inside the app is easier after moving it into /Applications.
    @objc private func setDefaultCADHandler(_ sender: Any?) {
        let types = ["com.autodesk.dwg", "com.autodesk.dxf"]
        let bundleID = (Bundle.main.bundleIdentifier ?? "com.cadlens.native") as CFString
        var failures: [String] = []
        for type in types {
            let status = LSSetDefaultRoleHandlerForContentType(
                type as CFString, .all, bundleID)
            if status != noErr { failures.append(type) }
        }
        let alert = NSAlert()
        if failures.isEmpty {
            alert.messageText = "已设为默认打开方式"
            alert.informativeText = "以后双击 .dwg / .dxf 会用速看CAD 打开。\n也可以在 Finder 的「显示简介 → 打开方式」里随时改回。"
            alert.alertStyle = .informational
        } else {
            alert.messageText = "设置失败"
            alert.informativeText = "无法注册：\(failures.joined(separator: "、"))。\n请在 Finder 的「显示简介 → 打开方式」中手动选择速看CAD。"
            alert.alertStyle = .warning
        }
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        open(url: url)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === snapSubmenu {
            mainWindow?.populateSnapMenu(menu)
            return
        }
        if menu === toneSubmenu {
            menu.removeAllItems()
            for (index, tone) in CanvasTone.allCases.enumerated() {
                let item = NSMenuItem(title: tone.title,
                                      action: #selector(pickCanvasTone(_:)), keyEquivalent: "")
                item.tag = index
                item.target = self
                item.state = tone == Theme.canvasTone ? .on : .off
                menu.addItem(item)
            }
            return
        }
        guard menu.title == "打开最近使用" else { return }
        menu.removeAllItems()
        let recents = NSDocumentController.shared.recentDocumentURLs
        if recents.isEmpty {
            let empty = NSMenuItem(title: "没有最近使用", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for url in recents.prefix(12) {
            let item = NSMenuItem(title: url.lastPathComponent,
                                  action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = url
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "清除菜单", action: #selector(clearRecents), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    @objc private func clearRecents() {
        NSDocumentController.shared.clearRecentDocuments(nil)
    }
}
