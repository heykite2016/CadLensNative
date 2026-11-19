import AppKit

/// Scripted UI harness used for automated screenshots and interaction smoke
/// tests during development. It is inert unless the process is launched with
/// `CADLENS_SNAPSHOT` (and optionally `CADLENS_DEMO`) set.
///
///   CADLENS_SNAPSHOT=/tmp/shot.png CADLENS_DEMO=1 open -n -a CadLens.app plan.dxf
enum DevelopmentHarness {
    static var snapshotPath: String? {
        ProcessInfo.processInfo.environment["CADLENS_SNAPSHOT"]
    }

    static var wantsDemo: Bool {
        ProcessInfo.processInfo.environment["CADLENS_DEMO"] == "1"
    }

    static var shouldExit: Bool {
        ProcessInfo.processInfo.environment["CADLENS_SNAPSHOT_EXIT"] == "1"
    }

    static var wantsBenchmark: Bool {
        ProcessInfo.processInfo.environment["CADLENS_BENCH"] == "1"
    }

    /// `CADLENS_APPEARANCE=dark|light` forces an appearance for screenshots.
    static func applyRequestedAppearance() {
        switch ProcessInfo.processInfo.environment["CADLENS_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    private static var didOpenExtras = false
    /// 打印预览窗口要活着才能截图，否则拍到的是一块空白。
    private static var previewWindow: PrintWindowController?
    private static var helpWindow: HelpWindowController?

    private static func captureWindow(_ window: NSWindow?, to path: String) {
        guard let window, let view = window.contentView else { return }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    static func handleDocumentLoaded(_ controller: MainWindowController) {
        // `CADLENS_LIVE_VIEW=1` applies the scripted camera without capturing a
        // snapshot or exiting, so a screenshot of the real window can be
        // compared against the offscreen render path.
        // `CADLENS_EXTRA_DOCS=a.dxf,b.dxf` 先把手上的图补齐，截图与自测才看得到
        // 多图纸的样子。命令行只能带一个文件参数，多张得靠这个。
        if !didOpenExtras, let list = ProcessInfo.processInfo.environment["CADLENS_EXTRA_DOCS"] {
            didOpenExtras = true
            let paths = list.split(separator: ",").map { String($0) }
            DispatchQueue.main.async {
                for path in paths where !path.isEmpty {
                    controller.open(url: URL(fileURLWithPath: path))
                }
            }
        }

        let liveView = ProcessInfo.processInfo.environment["CADLENS_LIVE_VIEW"] != nil
        guard snapshotPath != nil || wantsBenchmark || liveView
                || SelfTest.wantsRun else { return }
        applyCamera(controller)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            // Re-apply after the canvas's own delayed fit has landed, so a
            // scripted camera actually survives into the capture.
            applyCamera(controller)
            // Seed after the camera has settled: seeding while the transform
            // was still the pre-fit placeholder projected the sample
            // annotations tens of thousands of points off screen.
            // 端符回归：`CADLENS_MARKER=arrow|tick` 在造样例标注前钉住端符，
            // 同一张图截两次就能比对箭头与 45° 短斜线。
            if let raw = ProcessInfo.processInfo.environment["CADLENS_MARKER"] {
                AnnotationRenderer.markerOverride = raw == "tick" ? .architecturalTick
                    : (raw == "arrow" ? .filledArrow : nil)
            }
            if ProcessInfo.processInfo.environment["CADLENS_FULLSCREEN_TEST"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    controller.window?.toggleFullScreen(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                        let full = controller.window?.styleMask.contains(.fullScreen) ?? false
                        let frame = controller.window?.frame ?? .zero
                        print(String(format: "[fullscreen] full=%d frame=%.0fx%.0f",
                                     full ? 1 : 0, frame.width, frame.height))
                        NSApp.terminate(nil)
                    }
                }
                return
            }
            if wantsDemo { seedAnnotations(controller) }
            // `CADLENS_SIDEBAR=1` 截图时把右侧栏展开，用来核对面板配色。
            if ProcessInfo.processInfo.environment["CADLENS_SIDEBAR"] == "1" {
                controller.toggleSidebar(nil)
            }
            // `CADLENS_SPACETEST=1`：切页签不重置画布的回归。样例 DXF 只有
            // 模型页，用多页 PDF（每页一个空间）来验。
            if ProcessInfo.processInfo.environment["CADLENS_SPACETEST"] == "1" {
                runSpaceSwitchTest(controller)
            }
            // `CADLENS_LAYOUTS="模型,1F平面图,..." CADLENS_LAYOUT_PICK=9` 伪造布局
            // 页签，核对长名字多页签时的截断与滚动。
            if let raw = ProcessInfo.processInfo.environment["CADLENS_LAYOUTS"] {
                let names = raw.components(separatedBy: ",")
                let pick = Int(ProcessInfo.processInfo.environment["CADLENS_LAYOUT_PICK"]
                    ?? "") ?? 0
                controller.debugSetLayoutTabs(names, selected: pick)
            }
            if ProcessInfo.processInfo.environment["CADLENS_ARC_TEST"] == "1" {
                seedArcMeasurement(controller)
            }
            if SelfTest.wantsRun { SelfTest.run(controller) }
            if ProcessInfo.processInfo.environment["CADLENS_DOCTEST"] == "1" {
                runDocumentSwitchTest(controller)
            }
            controller.canvas.displayIfNeeded()
            if wantsBenchmark { runBenchmark(controller) }
            if ProcessInfo.processInfo.environment["CADLENS_DEMO_LOG"] != nil {
                for item in controller.canvas.document?.annotations ?? [] {
                    print(String(format: "[demo] %@ value=%.4f n=%d text=%@",
                                 item.kind.rawValue, item.value, item.points.count, item.text))
                }
            }
            // 删除模式要在种完标注之后再开：seed 里设置 activeTool 会把
            // eraseMode 清掉，之前就是这么被静默覆盖的。
            if ProcessInfo.processInfo.environment["CADLENS_ERASE"] == "1" {
                controller.canvas.eraseMode = true
                controller.canvas.updateAnnotationHover(at: controller.canvas.transform.toWorld(
                    controller.canvas.crosshairOverride ?? CGPoint(x: 228, y: 298)))
            }
            if ProcessInfo.processInfo.environment["CADLENS_HELP"] == "1" {
                HelpWindowController.shared.show()
                helpWindow = HelpWindowController.shared
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if let window = HelpWindowController.shared.window,
                       ProcessInfo.processInfo.environment["CADLENS_HELP_LOG"] != nil {
                        print("[help] 截图前 window=\(window.frame) content=\(window.contentView?.frame ?? .zero)")
                    }
                    if let path = self.snapshotPath {
                        self.captureWindow(HelpWindowController.shared.window, to: path)
                    }
                    if self.shouldExit { NSApp.terminate(nil) }
                }
                return
            }
            // `CADLENS_SETTINGS=1` 打开设置面板并截图，核对画布配色行的排版。
            if ProcessInfo.processInfo.environment["CADLENS_SETTINGS"] == "1" {
                SettingsWindowController.shared.show(settings: controller.canvas.settings) { _ in }
                if let raw = ProcessInfo.processInfo.environment["CADLENS_SETTINGS_SECTION"],
                   let index = Int(raw) {
                    SettingsWindowController.shared.showSection(index)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if let path = self.snapshotPath {
                        self.captureWindow(SettingsWindowController.shared.window, to: path)
                    }
                    if self.shouldExit { NSApp.terminate(nil) }
                }
                return
            }
            if let typed = ProcessInfo.processInfo.environment["CADLENS_COMMAND"] {
                controller.typeCommand(typed)
            }
            // 标注进行中的预览定格：`CADLENS_TOOL_PREVIEW=rect|aligned|linear`
            // 把工具停在"已落一点、指针在第二点"的状态，截图核对预览画法
            // （矩形必须是框，不能是一条对角线）。
            if let mode = ProcessInfo.processInfo.environment["CADLENS_TOOL_PREVIEW"] {
                let canvas = controller.canvas
                let a = CGPoint(x: canvas.bounds.width * 0.34,
                                y: canvas.bounds.height * 0.62)
                let b = CGPoint(x: canvas.bounds.width * 0.62,
                                y: canvas.bounds.height * 0.38)
                switch mode {
                case "rect": canvas.activeTool = .rectangle
                case "linear": canvas.activeTool = .linear
                default: canvas.activeTool = .aligned
                }
                canvas.measurePoints = [canvas.transform.toWorld(a)]
                canvas.measureHover = canvas.transform.toWorld(b)
                canvas.crosshairOverride = b
                canvas.pointerInside = true
                canvas.updateCrosshair()
                canvas.needsDisplay = true
            }
            // 快速标注回归：`CADLENS_BATCH_TEST=preview|commit` 用当前视图
            // 中间一块区域模拟框选，检查预览和落图。真实图纸上用它核对
            // “框选后先预览、再确认”的流程。
            if let mode = ProcessInfo.processInfo.environment["CADLENS_BATCH_TEST"] {
                let canvas = controller.canvas
                let box = CGRect(x: canvas.bounds.width * 0.25,
                                 y: canvas.bounds.height * 0.30,
                                 width: canvas.bounds.width * 0.36,
                                 height: canvas.bounds.height * 0.36)
                canvas.activeTool = .batch
                canvas.commitBatchSelection(in: box)
                if mode == "commit" {
                    canvas.commitPendingBatch()
                }
                canvas.needsDisplay = true
            }
            if let path = ProcessInfo.processInfo.environment["CADLENS_PRINT_PREVIEW"] {
                renderPrintPreview(controller, to: path)
            }
            // 打印预览窗口截图：`CADLENS_PRINT_WINDOW=layout` 按布局图框出页，
            // `=selection` 用画布中心一块区域出页。窗口预览没有真实指针也能拍。
            if let mode = ProcessInfo.processInfo.environment["CADLENS_PRINT_WINDOW"] {
                let canvas = controller.canvas
                var pages: [PrintPage] = []
                if mode == "selection" {
                    let center = canvas.transform.toWorld(
                        CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
                    let scale = 1 / max(canvas.transform.scale, 1e-6)
                    let rect = CGRect(x: center.x - 200 * scale, y: center.y - 140 * scale,
                                      width: 400 * scale, height: 280 * scale)
                    pages = [PrintPage(space: canvas.space, rect: rect,
                                       title: canvas.document?.spaceInfo(canvas.space)?.name ?? "模型")]
                } else {
                    pages = PrintPreviewBuilder.pagesForWholeDrawing(canvas: canvas)
                }
                if !pages.isEmpty {
                    let panel = PrintWindowController(
                        canvas: canvas, pages: pages, title: "打印预览 · 测试")
                    panel.showWindow(nil)
                    panel.window?.makeKeyAndOrderFront(nil)
                    panel.window?.setContentSize(NSSize(width: 1180, height: 800))
                    previewWindow = panel
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        if let path = self.snapshotPath {
                            self.captureWindow(panel.window, to: path)
                        }
                        if self.shouldExit { NSApp.terminate(nil) }
                    }
                    return
                }
            }
            // `CADLENS_PRINT_PAGES=/tmp/pages` 把"打印图纸"算出来的每一页都
            // 渲染成 PNG：页数对不对、每页切到的位置对不对，靠它一眼看出来。
            if let directory = ProcessInfo.processInfo.environment["CADLENS_PRINT_PAGES"] {
                let pages = PrintPreviewBuilder.pagesForWholeDrawing(canvas: controller.canvas)
                let root = URL(fileURLWithPath: directory)
                try? FileManager.default.createDirectory(at: root,
                                                         withIntermediateDirectories: true)
                var setup = PrintSetup()
                setup.paper = .a3
                setup.scaleDenominator = 0
                setup.ink = .mono
                setup.unitMillimetres = CGFloat(controller.canvas.document?.unitMeters ?? 0.001) * 1000
                for (index, page) in pages.enumerated() {
                    let paper = setup.paperSizePoints(content: page.rect)
                    guard let image = PrintRenderer.image(
                        setup: setup, canvas: controller.canvas, space: page.space,
                        worldRect: page.rect, paperSize: paper, pixelsPerPoint: 1.2) else { continue }
                    let rep = NSBitmapImageRep(cgImage: image)
                    let name = String(format: "page-%02d.png", index + 1)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: root.appendingPathComponent(name))
                }
                print("[print] pages rendered: \(pages.count) -> \(directory)")
            }
            // 运行时切画布配色的回归：`CADLENS_CANVAS_TONE_SWITCH=light|dark`
            // 在截图前切一次，确认画布栅格、图元反色、十字光标颜色都跟着换。
            if let raw = ProcessInfo.processInfo.environment["CADLENS_CANVAS_TONE_SWITCH"],
               let tone = CanvasTone(rawValue: raw) {
                Theme.canvasTone = tone
                controller.canvas.displayIfNeeded()
            }
            // `CADLENS_CLOSE=all|active` 先关图再截图：关图后画布必须回到
            // 空白，不能留着上一张的残影。
            if ProcessInfo.processInfo.environment["CADLENS_EXTENT_LOG"] != nil,
               let document = controller.canvas.document {
                let space = controller.canvas.space
                let ext = document.layoutExtent(space)
                let box = document.spaceInfo(space)?.box ?? .null
                print(String(format: "[extent] space=%d ext=(%.1f,%.1f)-(%.1f,%.1f) box=(%.1f,%.1f)-(%.1f,%.1f)",
                             space, ext.minX, ext.minY, ext.maxX, ext.maxY,
                             box.minX, box.minY, box.maxX, box.maxY))
                for vp in document.viewports where vp.space == space {
                    print(String(format: "[extent]   vp ctr=(%.1f,%.1f) size=(%.1f,%.1f) clip=(%.1f,%.1f)-(%.1f,%.1f) status=%d",
                                 vp.center.x, vp.center.y, vp.size.width, vp.size.height,
                                 vp.clip.minX, vp.clip.minY, vp.clip.maxX, vp.clip.maxY, vp.status))
                }
            }
            if let mode = ProcessInfo.processInfo.environment["CADLENS_CLOSE"] {
                if mode == "active" {
                    controller.closeActiveDocument(nil)
                } else {
                    while !controller.sessions.isEmpty { controller.closeSession(at: 0) }
                }
                controller.canvas.displayIfNeeded()
            }
            exportIfRequested(controller)
            // 侧栏开合是 0.26s 的动画：立即截图会拍到宽度还是 0 的那一帧，
            // 侧栏在图上等于不存在。先让 run loop 转一会儿再拍。
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
            capture(controller)
            if shouldExit { NSApp.terminate(nil) }
        }
    }

    /// 多图纸切换的回归：缩放 → 切走 → 切回，相机与空间必须原样回来。
    ///
    /// 这条链路最容易坏在"切换时忘了把当前视图存回去"或者"切回时被自动
    /// 适配覆盖"——两种都会让人每次切回来都得重新找位置，而截图看不出来。
    /// 切模型/布局不重置画布：模型里放大过，切走再切回还应该是同一个位置。
    private static func runSpaceSwitchTest(_ controller: MainWindowController) {
        let canvas = controller.canvas
        guard let document = canvas.document, document.spaces.count > 1 else {
            print("[spacetest] 跳过：\(canvas.document?.spaces.count ?? 0) 个空间")
            return
        }
        canvas.zoom(by: 1.7)
        canvas.transform.origin.x += 63
        canvas.transform.origin.y -= 41
        let model = canvas.transform

        canvas.space = 1
        let layout = canvas.transform
        canvas.space = 0
        let back = canvas.transform

        let kept = abs(back.scale - model.scale) < 1e-4
            && abs(back.origin.x - model.origin.x) < 0.01
            && abs(back.origin.y - model.origin.y) < 0.01
        let framedLayout = abs(layout.scale - model.scale) > 1e-6
        print(String(format: "[spacetest] %@ 模型 %.4f/(%.1f,%.1f) → 布局(首次取景=%@) %.4f/(%.1f,%.1f) → 回模型 %.4f/(%.1f,%.1f)",
                     kept ? "通过" : "失败",
                     model.scale, model.origin.x, model.origin.y,
                     framedLayout ? "是" : "否",
                     layout.scale, layout.origin.x, layout.origin.y,
                     back.scale, back.origin.x, back.origin.y))
    }

    private static func runDocumentSwitchTest(_ controller: MainWindowController) {
        let canvas = controller.canvas
        guard controller.sessions.count >= 2 else {
            print("[doctest] 失败：需要至少两张图纸，当前 \(controller.sessions.count) 张")
            return
        }
        let home = controller.activeIndex
        let other = home == 0 ? 1 : 0
        // 先让画布真的画过一次：`hasStrokeGeometry` 是渲染器每帧写的，
        // 一帧都没画过时它恒为 false，下面那项"几何已重建"会无辜判失败。
        canvas.displayIfNeeded()

        // 造一个不可能是"显示全图"结果的相机：放大 2.4 倍并平移一段。
        canvas.zoom(by: 2.4)
        canvas.transform.origin.x += 137
        canvas.transform.origin.y -= 91
        canvas.needsDisplay = true
        let expected = canvas.transform
        let expectedSpace = canvas.space

        controller.activate(other)
        let switchedScale = canvas.transform.scale
        let switchedDocument = canvas.document?.url.lastPathComponent ?? "nil"

        controller.activate(home)
        let restored = canvas.transform
        // 切图后几何必须立刻重建：如果 GPU 缓冲还压着上一张图，segmentCount
        // 会是上一张的值，肉眼看就是"切图有残影，动一下才没"。
        let rebuilt = (canvas.metalView.renderer?.hasStrokeGeometry ?? false)
            || !canvas.isUsingMetal
        let spaceOK = canvas.space == expectedSpace
        let scaleOK = abs(restored.scale - expected.scale) < 0.0001
        let originOK = abs(restored.origin.x - expected.origin.x) < 0.01
            && abs(restored.origin.y - expected.origin.y) < 0.01
        let passed = scaleOK && originOK && spaceOK && rebuilt
        print(String(format: "[doctest] %@ 切到 %@ (scale %.3f) 再切回：scale %.3f→%.3f origin (%.1f,%.1f)→(%.1f,%.1f) space %d 几何已重建=%@",
                     passed ? "通过" : "失败", switchedDocument, switchedScale,
                     expected.scale, restored.scale,
                     expected.origin.x, expected.origin.y,
                     restored.origin.x, restored.origin.y,
                     Int(spaceOK ? expectedSpace : -1), rebuilt ? "是" : "否"))

        // 切布局回归：布局与模型的几何差两个数量级，切过去后 stroke 缓冲必须
        // 立刻按新 scale 重建（`space.didSet` 里 clear + rebuild），而不是等
        // 0.12 s 的 settle timer，否则中间帧残留上一个布局的线段。
        guard let doc = canvas.document, doc.spaces.count > 1 else { return }
        let modelScale = canvas.transform.scale
        for candidate in 1..<doc.spaces.count {
            canvas.space = Int32(candidate)
            let newScale = canvas.transform.scale
            let built = canvas.metalView.renderer?.geometryBuiltScale ?? 0
            let scaleMoved = abs(newScale - modelScale) > 0.0001
            let geoOK = !canvas.isUsingMetal
                || (canvas.metalView.renderer?.hasStrokeGeometry ?? false)
                   && abs(built - newScale) / max(newScale, 1e-9) < 0.15
            print(String(format: "[doctest] %@ 切布局 space=%d scale %.5g→%.5g 几何builtScale=%.5g 相机已变=%@ 几何已同步=%@",
                         (scaleMoved && geoOK) ? "通过" : "失败",
                         candidate, modelScale, newScale, built,
                         scaleMoved ? "是" : "否", geoOK ? "是" : "否"))
            break
        }
        canvas.space = expectedSpace
    }

    /// 把一份 1:100 黑白 A3 打印件渲到文件，用来核对"纸上量出来是不是真的
    /// 1:100"——屏幕截图看不出比例对不对。
    private static func renderPrintPreview(_ controller: MainWindowController, to path: String) {
        let canvas = controller.canvas
        guard let document = canvas.document else { return }
        var setup = PrintSetup()
        setup.paper = .a3
        setup.scaleDenominator = 100
        setup.ink = .mono
        setup.content = .extents
        setup.unitMillimetres = CGFloat(document.unitMeters) * 1000
        let world = canvas.printWorldRect(extents: true)
        let size = setup.paperSizePoints(content: world)
        guard let image = PrintRenderer.image(setup: setup, canvas: canvas,
                                              worldRect: world, paperSize: size,
                                              pixelsPerPoint: 2) else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
        // 一张 A3 纸 420mm 高，1:100 下应容纳 42000 个图纸单位；把按比例算出
        // 的纸上尺寸打出来，比看图更容易发现比例被"适合纸张"偷偷改掉。
        let perUnit = setup.pointsPerWorldUnit(fitting: world, in: size)
        let printedWidthMM = world.width * perUnit / PrintSetup.pointsPerMillimetre
        let printedHeightMM = world.height * perUnit / PrintSetup.pointsPerMillimetre
        let ratio = setup.unitMillimetres / max(perUnit / PrintSetup.pointsPerMillimetre, 1e-9)
        print(String(format: "[print] %@ 纸张 %.0f×%.0fpt · 图幅 %.0f×%.0f 单位 → 纸上 %.0f×%.0fmm · 1:%.0f",
                     setup.paper.title, size.width, size.height,
                     world.width, world.height,
                     printedWidthMM, printedHeightMM, ratio))
    }

    /// `CADLENS_BENCH=1` drives the camera through a scripted gesture and
    /// reports the CPU cost of a synchronous redraw for each frame.
    private static func runBenchmark(_ controller: MainWindowController) {
        let canvas = controller.canvas
        guard canvas.document != nil else { return }
        let base = canvas.transform
        let centerWorld = CGPoint(x: base.origin.x + canvas.bounds.width / (2 * base.scale),
                                  y: base.origin.y + canvas.bounds.height / (2 * base.scale))

        /// Lets the debounced full-quality pass land, so the measured gesture
        /// starts from a raster that actually covers the canvas — otherwise the
        /// first frames only blit a stale, tiny image and the numbers flatter
        /// the cache.
        func settle() {
            let deadline = Date().addingTimeInterval(0.9)
            while Date() < deadline {
                RunLoop.current.run(mode: .default,
                                    before: Date().addingTimeInterval(0.01))
            }
            canvas.invalidateSheet()
            canvas.display()
        }

        func measure(_ label: String, frames: Int, _ body: (Int) -> Void) {
            var samples: [Double] = []
            var bodySamples: [Double] = []
            samples.reserveCapacity(frames)
            bodySamples.reserveCapacity(frames)
            for i in 0..<frames {
                let start = CACurrentMediaTime()
                body(i)
                let afterBody = CACurrentMediaTime()
                // A real gesture turns the run loop once per mouse event and
                // then redraws every dirty layer. `canvas.display()` on its own
                // only draws the canvas view and left the fill and overlay
                // layers out of the measurement.
                canvas.displayFullFrame()
                let end = CACurrentMediaTime()
                bodySamples.append((afterBody - start) * 1000)
                samples.append((end - start) * 1000)
            }
            let sorted = samples.sorted()
            let sortedBody = bodySamples.sorted()
            let median = sorted[sorted.count / 2]
            let p90 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
            let mean = samples.reduce(0, +) / Double(frames)
            // The mean is dominated by thermal throttling and by frames that
            // happen to miss a vsync; the median is the frame the user actually
            // feels, and p90 catches the stutter.
            print(String(format: "[bench] %-10@ median %6.2f  p90 %6.2f  mean %6.2f  worst %6.2f  body %5.2f  (n=%d)",
                         label as NSString, median, p90, mean, sorted.last ?? 0,
                         sortedBody[sortedBody.count / 2], frames))
        }

        // Cost of one full-quality raster, which is what a crisp frame after a
        // gesture actually costs.
        settle()
        measure("crisp", frames: 3) { _ in
            canvas.invalidateSheet()
        }

        canvas.center(on: centerWorld, scale: base.scale)
        settle()
        measure("pan", frames: 40) { i in
            canvas.center(on: CGPoint(x: centerWorld.x + CGFloat(i % 8) * 24 / base.scale,
                                      y: centerWorld.y), scale: base.scale)
        }
        canvas.center(on: centerWorld, scale: base.scale)
        settle()
        measure("zoom", frames: 40) { i in
            canvas.center(on: centerWorld,
                          scale: base.scale * CGFloat(1.0 + Double(i % 8) * 0.02))
        }
        canvas.zoomToExtents(animated: false)
        settle()
        measure("extents", frames: 20) { _ in canvas.zoomToExtents(animated: false) }
        canvas.center(on: centerWorld, scale: base.scale)
        // Repeat the first gesture at the end of the run. A machine that has
        // settled into its thermal state answers this one differently from the
        // opening pan, which tells a real cost apart from a warm-up artefact.
        settle()
        measure("pan2", frames: 40) { i in
            canvas.center(on: CGPoint(x: centerWorld.x + CGFloat(i % 8) * 24 / base.scale,
                                      y: centerWorld.y), scale: base.scale)
        }
        canvas.center(on: centerWorld, scale: base.scale)
    }

    /// `CADLENS_EXPORT_PNG=/tmp/a.png CADLENS_EXPORT_PDF=/tmp/a.pdf` writes the
    /// vector export paths without going through a save panel.
    private static func exportIfRequested(_ controller: MainWindowController) {
        let env = ProcessInfo.processInfo.environment
        let canvas = controller.canvas
        guard canvas.document != nil else { return }

        if let path = env["CADLENS_EXPORT_PNG"] {
            let backing = controller.window?.backingScaleFactor ?? 2
            let width = Int(canvas.bounds.width * backing)
            let height = Int(canvas.bounds.height * backing)
            if let image = canvas.vectorImage(pixelWidth: width, pixelHeight: height),
               let data = NSBitmapImageRep(cgImage: image)
                .representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }

        if let path = env["CADLENS_EXPORT_PDF"] {
            var mediaBox = CGRect(origin: .zero, size: canvas.bounds.size)
            if let ctx = CGContext(URL(fileURLWithPath: path) as CFURL,
                                   mediaBox: &mediaBox, nil) {
                ctx.beginPDFPage(nil)
                canvas.drawVector(in: ctx, targetRect: mediaBox)
                ctx.endPDFPage()
                ctx.closePDF()
            }
        }
    }

    /// `CADLENS_GRID=1` / `CADLENS_CROSSHAIR=0` force the two overlay toggles
    /// for a screenshot without touching the user's saved preferences.
    private static func applyRequestedToggles(_ controller: MainWindowController) {
        let env = ProcessInfo.processInfo.environment
        var settings = controller.canvas.settings
        var changed = false
        if let value = env["CADLENS_GRID"] {
            settings.showGrid = value == "1"
            changed = true
        }
        if let value = env["CADLENS_CROSSHAIR"] {
            settings.showCrosshair = value == "1"
            changed = true
        }
        if changed { controller.canvas.settings = settings }
    }

    /// `CADLENS_ZOOM=12 CADLENS_CENTER=14,10` pins the camera for a stable shot.
    /// `CADLENS_ZOOM_FACTOR=3` magnifies whatever the fit produced.
    ///
    /// Applied synchronously: the canvas performs its own fit-to-extents on a
    /// short delay after the document loads, so an override posted to the main
    /// queue was always overwritten and every "zoomed" screenshot was really
    /// the fitted view. It is applied once here and once more immediately
    /// before the capture, which is after that late fit has landed.
    private static func applyCamera(_ controller: MainWindowController) {
        let env = ProcessInfo.processInfo.environment
        let canvas = controller.canvas
        applyRequestedToggles(controller)
        do {
            if let raw = env["CADLENS_SPACE"], let index = Int32(raw),
               controller.cadDocument?.spaceInfo(index) != nil {
                canvas.space = index
            }
            if let factor = env["CADLENS_ZOOM_FACTOR"], let zoom = Double(factor), zoom > 0 {
                canvas.setZoomScale(canvas.transform.scale * CGFloat(zoom))
            }
            if let raw = env["CADLENS_ZOOM"], let scale = Double(raw) {
                let parts = (env["CADLENS_CENTER"] ?? "").split(separator: ",")
                let center = parts.count == 2
                    ? CGPoint(x: Double(parts[0]) ?? 0, y: Double(parts[1]) ?? 0)
                    : CGPoint(x: canvas.transform.origin.x
                              + canvas.bounds.width / (2 * canvas.transform.scale),
                              y: canvas.transform.origin.y
                              + canvas.bounds.height / (2 * canvas.transform.scale))
                canvas.center(on: center, scale: CGFloat(scale))
            }
            if ProcessInfo.processInfo.environment["CADLENS_DUMP_VIEWPORTS"] != nil,
               let document = controller.cadDocument {
                for (index, viewport) in document.viewports.enumerated() {
                    print(String(format: "[vp] %2d space=%d status=%d centre=(%.1f,%.1f) size=%.1fx%.1f clip=(%.1f,%.1f)-(%.1f,%.1f)",
                                 index, viewport.space, viewport.status,
                                 viewport.center.x, viewport.center.y,
                                 viewport.size.width, viewport.size.height,
                                 viewport.clip.minX, viewport.clip.minY,
                                 viewport.clip.maxX, viewport.clip.maxY))
                }
                for (index, space) in document.spaces.enumerated() {
                    print(String(format: "[space] %d %@ kind=%d box=(%.1f,%.1f)-(%.1f,%.1f)",
                                 index, space.name, space.kind,
                                 space.box.minX, space.box.minY,
                                 space.box.maxX, space.box.maxY))
                }
            }
            if let raw = env["CADLENS_POINTER"] {
                let parts = raw.split(separator: ",").map { Double($0) ?? 0 }
                if parts.count == 2 {
                    let view = CGPoint(x: parts[0], y: parts[1])
                    canvas.pointerInside = true
                    canvas.crosshairOverride = view
                    canvas.updateCrosshair()
                    // 悬停反馈：把指针位置的判定也跑一遍，截图才看得到高亮。
                    if let world = canvas.transform.toWorld(view) as CGPoint? {
                        canvas.updateAnnotationHover(at: world)
                    }
                }
            }
            // Dump the *active display list* (paper entities + projected model
            // copies) so layout composition can be checked against the
            // reference reader's spaceEntity= rows, handle by handle.
            if let path = env["CADLENS_DUMP_DISPLAY"],
               let document = controller.cadDocument {
                var lines: [String] = []
                lines.reserveCapacity(document.entities.count)
                for entity in document.entities {
                    let points = document.points(for: entity)
                        .map { String(format: "%.6f,%.6f", $0.x, $0.y) }
                        .joined(separator: ";")
                    lines.append(String(format:
                        "display|%d|%d|%d|%d|%.12g|%.12g|%.12g|%.12g|%d|%@",
                        entity.space, entity.kind.rawValue, entity.pcount, entity.flags,
                        entity.box.minX, entity.box.minY, entity.box.maxX, entity.box.maxY,
                        entity.hasClip ? 1 : 0, points))
                }
                try? lines.joined(separator: "\n")
                    .write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Drives the real measurement code path with synthetic clicks so the
    /// annotation geometry, labels and persistence are exercised end to end.
    private static func seedAnnotations(_ controller: MainWindowController) {
        let canvas = controller.canvas
        guard let document = controller.cadDocument else { return }
        let box = document.spaceInfo(0)?.box ?? .zero
        guard box.width > 0 else { return }
        // Deterministic runs: drop annotations left over from earlier sessions.
        document.annotations.removeAll()
        AnnotationStore.clear(for: document.url)

        func event(at point: CGPoint, clickCount: Int) -> NSEvent? {
            NSEvent.mouseEvent(with: .leftMouseDown,
                               location: canvas.transform.toView(point),
                               modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: canvas.window?.windowNumber ?? 0,
                               context: nil, eventNumber: 0,
                               clickCount: clickCount, pressure: 1)
        }

        func click(_ tool: MeasureKind, _ points: [CGPoint]) {
            canvas.activeTool = tool
            var points = points
            // 对齐/线性多一步“放置尺寸线”，样例也走同一条真实路径。
            if (tool == .aligned || tool == .linear), points.count == 2 {
                let a = points[0], b = points[1]
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                let dx = b.x - a.x, dy = b.y - a.y
                let length = max(hypot(dx, dy), 1)
                let nx = -dy / length, ny = dx / length
                points.append(CGPoint(x: mid.x + nx * 36, y: mid.y + ny * 36))
            }
            let openEnded = tool.requiredPoints == Int.max
            for (index, point) in points.enumerated() {
                let isLast = index == points.count - 1
                guard let event = event(at: point,
                                        clickCount: openEnded && isLast ? 2 : 1) else { return }
                canvas.handleToolClick(tool: tool, world: point, event: event)
            }
            canvas.activeTool = nil
        }

        let w = box.width, h = box.height
        _ = (w, h)
        // Seed by view fraction, then convert to world: the sample drawings use
        // different units (millimetres vs metres), so fractions of the model
        // bounding box produced annotations a few pixels long on some files and
        // could not exercise the dimension geometry at all.
        func p(_ fx: Double, _ fy: Double) -> CGPoint {
            let view = CGPoint(x: canvas.bounds.width * CGFloat(fx),
                               y: canvas.bounds.height * CGFloat(fy))
            return canvas.transform.toWorld(view)
        }

        click(.aligned, [p(0.15, 0.24), p(0.43, 0.24)])
        click(.linear, [p(0.60, 0.18), p(0.60, 0.44)])
        click(.rectangle, [p(0.16, 0.52), p(0.31, 0.70)])
        click(.polygon, [p(0.38, 0.54), p(0.48, 0.52), p(0.53, 0.68),
                         p(0.45, 0.76), p(0.36, 0.68)])
        click(.angle, [p(0.65, 0.20), p(0.65, 0.42), p(0.82, 0.36)])
        click(.radius, [p(0.68, 0.58), p(0.72, 0.58), p(0.68, 0.62)])
        // 圆面积：一大一小两个。大圆的面积值能压在半径线上，小圆放不下就得
        // 挑到法向上方——两种布局都要能在截图上看到，圆心不该被文字盖住。
        click(.circleArea, [p(0.20, 0.36), p(0.235, 0.395), p(0.165, 0.395)])
        // 半径足够长时面积值压在半径线上，这条分支也要能看到。
        click(.circleArea, [p(0.52, 0.30), p(0.60, 0.38), p(0.44, 0.38)])
        click(.continuous, [p(0.16, 0.86), p(0.31, 0.90), p(0.45, 0.85)])

        // 侧面积（多点）：直接落一条标注，跳过"输入高度"的模态对话框，否则
        // 截图流程会停在那一步等输入。
        let wall = [p(0.56, 0.86), p(0.68, 0.90), p(0.82, 0.86)]
        let wallLength = MeasurementMath.pathLength(wall, closed: false)
        var side = Annotation(kind: .sideArea, space: canvas.space, points: wall)
        side.value = Double(wallLength) * Double(wallLength) * 0.18
        side.text = "S侧 = " + document.formatArea(side.value)
        document.annotations.append(side)

        canvas.selectedAnnotation = document.annotations.count - 1
        canvas.needsDisplay = true
    }

    /// 圆弧测量自测：找图上第一段圆弧，在它上面取两个点走一遍"连续测量"，
    /// 打印弧长 / 弦长 / 加密点数，并把标注落在图上便于截图核对。
    ///
    /// 判据就一条：量出来的值必须接近弧长而不是弦长。圆弧如果退化成弦，
    /// 现场下料会短一截，而屏幕上看起来完全正常——只能靠数字验。
    private static func seedArcMeasurement(_ controller: MainWindowController) {
        let canvas = controller.canvas
        guard let document = controller.cadDocument else { return }
        document.annotations.removeAll()
        guard let arc = document.entities.first(where: { $0.kind == .arc && $0.r > 1 }) else {
            print("[arc] 这份图纸里没有圆弧")
            return
        }
        let center = CGPoint(x: arc.cx, y: arc.cy)
        let base = CGFloat(arc.a0)
        var span = CGFloat(arc.a1) - base
        while span <= 1e-6 { span += 2 * .pi }
        func point(_ t: CGFloat) -> CGPoint {
            let angle = base + span * t
            return CGPoint(x: center.x + CGFloat(arc.r) * cos(angle),
                           y: center.y + CGFloat(arc.r) * sin(angle))
        }
        let a = point(0.15), b = point(0.85)
        let (path, lengths) = canvas.densify([a, b], closed: false, document: document)
        let measured = lengths.reduce(0, +)
        let expected = Double(span * 0.7 * CGFloat(arc.r))
        let chord = Double(MeasurementMath.distance(a, b))
        print(String(format: "[arc] r=%.1f span=%.1f° points=%d 弧长=%.1f 实测=%.1f 弦长=%.1f",
                     arc.r, span * 180 / .pi, path.count, expected, measured, chord))

        var annotation = Annotation(kind: .continuous, space: canvas.space, points: [a, b])
        annotation.path = path
        annotation.segmentLengths = lengths
        annotation.value = measured
        annotation.text = "弧长 " + document.formatLength(measured, unit: true)
        document.annotations.append(annotation)
        canvas.selectedAnnotation = nil
        let radius = CGFloat(arc.r)
        canvas.zoom(toWorldRect: CGRect(x: center.x - radius * 1.35,
                                        y: center.y - radius * 1.35,
                                        width: radius * 2.7, height: radius * 2.7))
        canvas.needsDisplay = true
    }

    private static func capture(_ controller: MainWindowController) {
        if ProcessInfo.processInfo.environment["CADLENS_SETTINGS_LOG"] != nil {
            let s = controller.canvas.settings
            print("[settings] snap=\(s.objectSnap) grid=\(s.showGrid) ortho=\(s.orthoMode) lw=\(s.showLineweights) style=\(s.annotationStyle)")
        }
        guard let path = snapshotPath, let window = controller.window,
              // The frame view includes the title bar and toolbar.
              let view = window.contentView?.superview ?? window.contentView else { return }
        // 开合类动画把布局推迟到下一个显示周期；截屏前先强制排一次版，
        // 否则拍到的还是"宽度 0"的侧栏（等于没展开）。
        window.contentView?.layoutSubtreeIfNeeded()
        // 面板几何只有在排版跑过一次之后才是真的：以前这行打印在开合之后
        // 立刻执行，读到的是"约束已改、frame 还没跟上"的中间态。
        if ProcessInfo.processInfo.environment["CADLENS_UI_LOG"] == "1" {
            print("[ui] " + controller.debugChromeDump())
        }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)

        if let rawPath = ProcessInfo.processInfo.environment["CADLENS_RAW_SNAPSHOT"],
           let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: rawPath))
        }

        // The GPU layer is not part of the window-server snapshot, so it is
        // rendered offscreen and stamped into the canvas rectangle.
        let backing = window.backingScaleFactor
        let canvas = controller.canvas

        /// Stamps one canvas-sized bitmap over the window snapshot. The canvas
        /// runs underneath the toolbar, so only the visible part is used.
        func stamp(_ image: CGImage, flip: Bool) {
            let canvasRect = canvas.convert(canvas.bounds, to: view)
            let visible = canvasRect.intersection(window.contentLayoutRect)
            guard !visible.isNull, !visible.isEmpty,
                  canvasRect.width > 0,
                  let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
            let pixelScale = CGFloat(image.width) / canvasRect.width
            let source = CGRect(x: (visible.minX - canvasRect.minX) * pixelScale,
                                y: (canvasRect.maxY - visible.maxY) * pixelScale,
                                width: visible.width * pixelScale,
                                height: visible.height * pixelScale).integral
            guard let cropped = image.cropping(to: source) else { return }
            let ctx = context.cgContext
            ctx.saveGState()
            if flip {
                // The GPU target is top-down in a bottom-up view context.
                ctx.translateBy(x: visible.minX, y: visible.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(cropped, in: CGRect(origin: .zero, size: visible.size))
            } else {
                ctx.draw(cropped, in: visible)
            }
            ctx.restoreGState()
        }

        // The GPU layer is not part of the window-server snapshot, so it is
        // rendered offscreen and stamped in. Everything else — hatches,
        // annotations, the pointer — is already in the cached window image.
        if let metal = canvas.metalSnapshot(pixelScale: backing) { stamp(metal, flip: false) }

        // 画布的 GPU 图是整块贴上去的，贴完玻璃浮层被压在下面了。这里把浮层
        // 按真实层序重画一遍：画布在下、玻璃在上，快照才等于用户看到的画面。
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            for chrome in controller.overlayViews
            where !chrome.isHidden && chrome.alphaValue > 0.01 {
                let rect = chrome.convert(chrome.bounds, to: view)
                guard rect.width > 1, rect.height > 1,
                      let chromeRep = chrome.bitmapImageRepForCachingDisplay(in: chrome.bounds)
                else { continue }
                chrome.cacheDisplay(in: chrome.bounds, to: chromeRep)
                guard let image = chromeRep.cgImage else { continue }
                context.cgContext.draw(image, in: rect)
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
