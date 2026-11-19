import AppKit

/// 两个打印入口。
///
/// 参考项目里"打印预览"和"打印图纸"是两条路：一条框选一块区域出一页，一条
/// 按布局里的图框批量出页。这里保持同样的两条，只是把入口名字改成动作本身
/// （选区打印 / 打印图纸），因为"预览"是每个窗口都有的东西，不是一个功能。
enum PrintCommands {

    /// 当前活着的预览窗口。预览里还能"再框一页"，所以要留引用。
    private static var preview: PrintWindowController?

    /// 选区打印：先框选，再开预览。
    static func beginSelectionPrint(from controller: MainWindowController) {
        guard let canvas = controller.canvas as CanvasView?,
              canvas.document != nil, let window = controller.window else {
            NSSound.beep()
            return
        }
        preview?.close()
        preview = nil
        canvas.printRegionMode = true
        canvas.onPrintRegionChanged = { [weak controller] on in
            controller?.toolbar.setActive(.print, on)
        }
        canvas.onPrintRegionPicked = { [weak controller] rect, space in
            controller?.toolbar.setActive(.print, false)
            guard let controller, let canvas = controller.canvas as CanvasView?,
                  let window = controller.window else { return }
            let name = canvas.document?.spaceInfo(space)?.name ?? "模型"
            let page = PrintPage(space: space, rect: rect, title: name)
            present(pages: [page], canvas: canvas, window: window,
                    title: "打印预览 · \(canvas.document?.fileName ?? "")")
        }
        window.makeFirstResponder(canvas)
    }

    /// 打印图纸：布局里的视口逐页进预览。
    static func printDrawing(from controller: MainWindowController) {
        guard let canvas = controller.canvas as CanvasView?,
              canvas.document != nil, let window = controller.window else {
            NSSound.beep()
            return
        }
        let pages = PrintPreviewBuilder.pagesForWholeDrawing(canvas: canvas)
        guard !pages.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "没有找到可打印的布局"
            alert.informativeText = "这张图纸的布局里没有视口或图框。可以用「选区打印」框一块区域来打。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }
        let unit = CGFloat(canvas.document?.unitMeters ?? 0.001) * 1000
        var setup = PrintSetup()
        setup.paper = PrintSetup.paperFitting(
            contentMM: CGSize(width: pages[0].rect.width * unit,
                              height: pages[0].rect.height * unit))
        present(pages: pages, canvas: canvas, window: window,
                title: "打印预览 · \(canvas.document?.fileName ?? "")", setup: setup)
    }

    private static func present(pages: [PrintPage], canvas: CanvasView,
                                window: NSWindow, title: String,
                                setup: PrintSetup? = nil) {
        let panel = PrintWindowController(canvas: canvas, pages: pages, title: title,
                                          setup: setup)
        preview = panel
        // 预览里"＋ 框选添加一页"：收起预览回主窗口框选，选完追加。
        panel.setAddPageHandler { [weak panel, weak canvas, weak window] in
            guard let canvas, let window else { return }
            canvas.printRegionMode = true
            canvas.onPrintRegionPicked = { rect, space in
                let name = canvas.document?.spaceInfo(space)?.name ?? "模型"
                panel?.appendPage(PrintPage(space: space, rect: rect, title: name))
            }
            window.makeFirstResponder(canvas)
        }
        panel.showWindow(nil)
        panel.window?.center()
        panel.window?.makeKeyAndOrderFront(nil)
        // 上屏之后才知道预览区到底多宽，等这一轮布局跑完再贴合。
        DispatchQueue.main.async { panel.refreshFit() }
    }
}
