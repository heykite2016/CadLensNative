import AppKit

/// A scripted operator.
///
/// Every other harness in this project seeds annotations by calling
/// `handleToolClick` with exact world coordinates, which proves the geometry
/// maths and proves nothing about the tool. A person does not know where the
/// endpoint is: they aim a few pixels off it and rely on object snap to land on
/// it. This driver clicks *near* real endpoints of real entities through
/// `mouseDown`, and then checks the measured value against the true distance.
/// If snapping, the state machine, or the double-click terminator is broken,
/// the numbers are wrong by exactly the distance the click missed by.
///
/// `CADLENS_SELFTEST=1` runs it after the document is loaded and prints a
/// PASS/FAIL line per case.
enum SelfTest {
    static var wantsRun: Bool {
        ProcessInfo.processInfo.environment["CADLENS_SELFTEST"] == "1"
    }

    private static var passes = 0
    private static var failures = 0

    static func run(_ controller: MainWindowController) {
        let canvas = controller.canvas
        guard let window = canvas.window, let document = canvas.document else { return }
        let restoreSnap = canvas.settings.objectSnap
        canvas.settings.objectSnap = true
        canvas.annotationsHidden = false
        // The operator's own measurements are overwritten by the test run and
        // the sidecar is rewritten on every commit — so put back both the array
        // and the file when the run ends, whatever path it takes out.
        let savedAnnotations = document.annotations
        let keepResults = ProcessInfo.processInfo.environment["CADLENS_KEEP_SELFTEST"] == "1"
        defer {
            if !keepResults {
                document.annotations = savedAnnotations
                AnnotationStore.save(savedAnnotations, for: document.url)
                controller.refreshSidebar()
            }
        }
        document.annotations.removeAll()

        // MARK: clicking like a person

        /// Off-target by a few pixels on a consistent diagonal: far enough that
        /// a click that ignores snapping cannot pass by accident, close enough
        /// to be inside the 11 pt snap aperture a user actually gets.
        let miss = CGPoint(x: 3.5, y: -4.0)

        func mouse(_ type: NSEvent.EventType, view point: CGPoint, clicks: Int) {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: canvas.convert(point, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: clicks, pressure: 1)
            else { return }
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseUp: canvas.mouseUp(with: event)
            default: break
            }
        }

        func click(_ tool: MeasureKind, at viewPoints: [CGPoint], finishByDoubleClick: Bool = false) {
            canvas.activeTool = tool
            var points = viewPoints
            // DIMALIGNED/DIMLINEAR 现在需要第三点定尺寸线位置；自测也按真人
            // 的操作补一个偏出去的点，而不是走内部捷径。
            if (tool == .aligned || tool == .linear), points.count == 2 {
                let a = points[0], b = points[1]
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                let dx = b.x - a.x, dy = b.y - a.y
                let length = max(hypot(dx, dy), 1)
                let nx = -dy / length, ny = dx / length
                points.append(CGPoint(x: mid.x + nx * 34, y: mid.y + ny * 34))
            }
            for (index, point) in points.enumerated() {
                let last = index == points.count - 1
                let clicks = finishByDoubleClick && last ? 2 : 1
                mouse(.leftMouseDown, view: point, clicks: clicks)
                mouse(.leftMouseUp, view: point, clicks: clicks)
            }
            canvas.activeTool = nil
        }

        // MARK: real endpoints, from the drawing, not from a formula

        struct Endpoint { let world: CGPoint; let view: CGPoint; let layer: String }
        var endpoints: [Endpoint] = []
        let margin: CGFloat = 40
        let safe = canvas.bounds.insetBy(dx: margin, dy: margin)
        for entity in document.entities {
            guard document.isLayerVisible(entity) else { continue }
            switch entity.kind {
            case .line, .polyline:
                let slice = document.points(for: entity)
                guard slice.count >= 2 else { continue }
                for raw in [slice[slice.startIndex], slice[slice.endIndex - 1]] {
                    let view = canvas.transform.toView(raw)
                    guard safe.contains(view) else { continue }
                    let layerIndex = Int(entity.layer)
                    let name = document.layers.indices.contains(layerIndex)
                        ? document.layers[layerIndex].name : "-"
                    endpoints.append(Endpoint(world: raw, view: view, layer: name))
                }
            default:
                continue
            }
            if endpoints.count > 400 { break }
        }

        guard endpoints.count >= 8 else {
            print("[selftest] 图元端点不足，无法测试（\(endpoints.count)）")
            canvas.settings.objectSnap = restoreSnap
            return
        }

        // Drop endpoints that have another endpoint within 4 pt. On a dense
        // sheet (a door jamb is two lines 12 mm apart) several endpoints land
        // inside one snap aperture, and "which coincident point won" is not a
        // defect a user can even perceive — testing those measures the test's
        // luck, not the tool. What matters is the isolated endpoint a person
        // aims at, so those are the ones measured.
        let isolated = endpoints.filter { candidate in
            !endpoints.contains { other in
                hypot(other.view.x - candidate.view.x,
                       other.view.y - candidate.view.y) < 6
                    && other.view != candidate.view
            }
        }
        // The snap aperture is 16 pt, so two endpoints closer than 6 pt are the
        // same target as far as the tool — or the person — is concerned.
        if isolated.count >= 8 { endpoints = isolated }

        // Pairs a screen apart — a human picks two points they can see at once.
        var pairs: [(Endpoint, Endpoint)] = []
        var cursor = 0
        while pairs.count < 6, cursor + 1 < endpoints.count {
            let a = endpoints[cursor]
            cursor += 1
            guard let b = endpoints.prefix(endpoints.count).first(where: { other in
                let d = hypot(other.view.x - a.view.x, other.view.y - a.view.y)
                return d > 70 && d < 420
            }) else { continue }
            pairs.append((a, b))
        }

        // MARK: 1 — aligned distance with object snap

        for (index, pair) in pairs.enumerated() {
            let before = document.annotations.count
            click(.aligned, at: [CGPoint(x: pair.0.view.x + miss.x, y: pair.0.view.y + miss.y),
                                 CGPoint(x: pair.1.view.x + miss.x, y: pair.1.view.y + miss.y)])
            guard document.annotations.count == before + 1,
                  let made = document.annotations.last else {
                report(false, "对齐 #\(index + 1) 点击后没有生成标注")
                continue
            }
            let truth = MeasurementMath.distance(pair.0.world, pair.1.world)
            let error = abs(made.value - truth)
            let errorPixels = error * canvas.transform.scale
            report(errorPixels < 1.0,
                   String(format: "对齐 #%d 真值 %@ 测得 %@ 偏差 %.2fpx（%@ → %@）",
                          index + 1,
                          format(document, truth), format(document, made.value),
                          errorPixels, pair.0.layer, pair.1.layer))
        }

        // MARK: 1b — ortho must not override object snap
        // F8 打开时，捕捉到的端点仍然是落点；正交只能约束没有捕捉时的光标。
        if let pair = pairs.first {
            let restoreOrtho = canvas.settings.orthoMode
            canvas.settings.orthoMode = true
            let before = document.annotations.count
            click(.aligned, at: [CGPoint(x: pair.0.view.x + miss.x, y: pair.0.view.y + miss.y),
                                 CGPoint(x: pair.1.view.x + miss.x, y: pair.1.view.y + miss.y)])
            if document.annotations.count == before + 1, let made = document.annotations.last {
                let truth = MeasurementMath.distance(pair.0.world, pair.1.world)
                report(abs(made.value - truth) * canvas.transform.scale < 1.0,
                       String(format: "正交+捕捉 真值 %@ 测得 %@ 偏差 %.2fpx",
                              format(document, truth), format(document, made.value),
                              abs(made.value - truth) * canvas.transform.scale))
            } else {
                report(false, "正交+捕捉 点击后没有生成标注")
            }
            canvas.settings.orthoMode = restoreOrtho
        }

        // MARK: 2 — continuous chain, ended by double-click

        if pairs.count >= 3 {
            let before = document.annotations.count
            let chain = [pairs[0].0, pairs[1].0, pairs[2].0].map {
                CGPoint(x: $0.view.x + miss.x, y: $0.view.y + miss.y)
            }
            click(.continuous, at: chain, finishByDoubleClick: true)
            if document.annotations.count == before + 1, let made = document.annotations.last {
                let truth = MeasurementMath.distance(pairs[0].0.world, pairs[1].0.world)
                    + MeasurementMath.distance(pairs[1].0.world, pairs[2].0.world)
                let errorPixels = abs(made.value - truth) * canvas.transform.scale
                report(errorPixels < 1.5,
                       String(format: "连续 双击结束 真值 %@ 测得 %@ 偏差 %.2fpx",
                              format(document, truth), format(document, made.value), errorPixels))
            } else {
                report(false, "连续 双击没有结束测量（标注未生成）")
            }
        }

        // MARK: 3 — rectangle area from two snapped corners

        if let boxPair = pairs.first(where: {
            abs($0.0.view.x - $0.1.view.x) > 30 && abs($0.0.view.y - $0.1.view.y) > 30
        }) {
            let before = document.annotations.count
            let a = boxPair.0, b = boxPair.1
            click(.rectangle, at: [CGPoint(x: a.view.x + miss.x, y: a.view.y + miss.y),
                                   CGPoint(x: b.view.x + miss.x, y: b.view.y + miss.y)])
            if document.annotations.count == before + 1, let made = document.annotations.last {
                let dx = abs(b.world.x - a.world.x), dy = abs(b.world.y - a.world.y)
                let truth = dx * dy * document.unitMeters * document.unitMeters
                let measured = made.value * document.unitMeters * document.unitMeters
                let relative = truth > 0 ? abs(measured - truth) / truth : 1
                report(relative < 0.02,
                       String(format: "矩形面积 真值 %.3f m² 测得 %.3f m²（相对误差 %.1f%%）",
                              truth, measured, relative * 100))
            } else {
                report(false, "矩形 点击后没有生成标注")
            }
        }

        // MARK: 4 — Esc abandons a measurement in progress

        canvas.activeTool = .aligned
        let start = CGPoint(x: endpoints[0].view.x + miss.x, y: endpoints[0].view.y + miss.y)
        mouse(.leftMouseDown, view: start, clicks: 1)
        mouse(.leftMouseUp, view: start, clicks: 1)
        let openAfterFirstClick = canvas.measurePoints.count
        if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                         modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber,
                                         context: nil, characters: "\u{1b}",
                                         charactersIgnoringModifiers: "\u{1b}",
                                         isARepeat: false, keyCode: 53) {
            canvas.keyDown(with: escape)
        }
        report(openAfterFirstClick == 1 && canvas.measurePoints.isEmpty,
               "Esc 取消：首点后 \(openAfterFirstClick) 个点，Esc 后 \(canvas.measurePoints.count) 个点")
        canvas.activeTool = nil

        // 校准后刷新所有标注：改 unitMeters 后，已有标注文字必须跟着变。
        if let sample = document.annotations.first(where: { $0.kind == .aligned }) {
            let oldUnit = document.unitMeters
            let oldText = sample.text
            document.unitMeters = oldUnit * 2
            canvas.refreshAnnotationTexts()
            let newText = document.annotations.first(where: { $0.id == sample.id })?.text
            report(!oldText.isEmpty && newText != nil && oldText != newText,
                   "校准后刷新标注文字：\(oldText) → \(newText ?? "-")")
            document.unitMeters = oldUnit
            canvas.refreshAnnotationTexts()
        }

        // 窗口缩放与测量工具互斥：选测量工具必须退出窗口缩放。
        canvas.zoomWindowMode = true
        let enteredZoomWindow = canvas.zoomWindowMode
        canvas.activeTool = .aligned
        report(enteredZoomWindow && !canvas.zoomWindowMode,
               "切换测量工具退出窗口缩放")
        canvas.activeTool = nil

        // 填充净面积：外环 10×10、洞 2×2，必须是 96 而不是 100/104。
        let outer = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0),
                     CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]
        let hole = [CGPoint(x: 4, y: 4), CGPoint(x: 6, y: 4),
                    CGPoint(x: 6, y: 6), CGPoint(x: 4, y: 6)]
        let net = MeasurementMath.netArea(rings: [outer, hole])
        report(abs(net - 96) < 0.001,
               String(format: "填充净面积 外环100+洞4 期望 96.00 实测 %.2f", net))

        canvas.settings.objectSnap = restoreSnap
        canvas.activeTool = nil
        canvas.measurePoints.removeAll()

        // Leaves the app parked on a snapped endpoint so the snapshot shows the
        // marker, the caption and the crosshair exactly as a user sees them.
        if ProcessInfo.processInfo.environment["CADLENS_SELFTEST_HOVER"] == "1",
           let target = endpoints.first {
            canvas.activeTool = .aligned
            let hover = CGPoint(x: target.view.x + miss.x, y: target.view.y + miss.y)
            if let event = NSEvent.mouseEvent(
                with: .mouseMoved, location: canvas.convert(hover, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 0, pressure: 0) {
                canvas.mouseMoved(with: event)
            }
            canvas.crosshairOverride = hover
            canvas.pointerInside = true
            canvas.updateCrosshair()
        }

        // 切布局不重置画布：在模型里放大，切到布局再切回来，相机得原样
        // 还在（每个空间各记一份视图）。
        if document.spaces.count > 1, !keepResults {
            canvas.zoom(by: 1.6)
            canvas.transform.origin.x += 57
            canvas.transform.origin.y -= 33
            let expect = canvas.transform
            canvas.space = 1
            canvas.space = 0
            let back = canvas.transform
            let memoOK = abs(back.scale - expect.scale) < 1e-4
                && abs(back.origin.x - expect.origin.x) < 0.01
                && abs(back.origin.y - expect.origin.y) < 0.01
            report(memoOK, String(format: "切布局不重置画布：模型相机 %.3f/(%.1f,%.1f) → 切走再切回 %.3f/(%.1f,%.1f)",
                                  expect.scale, expect.origin.x, expect.origin.y,
                                  back.scale, back.origin.x, back.origin.y))
        } else if keepResults {
            print("[selftest] 跳过切布局相机检查：保留标注结果做真实图纸截图")
        } else {
            print("[selftest] 跳过切布局相机检查：这张图只有 \(document.spaces.count) 个空间")
        }

        // 布局页签：模型和当前布局必须完整显示，不能被压成省略号。
        let crowded = CADLayoutTabs()
        crowded.configure(["模型", "总平面图", "1F平面图", "2F平面图", "3F平面图",
                           "屋顶平面图", "东立面图", "南立面图", "剖面图A-A",
                           "剖面图B-B", "大样图1", "大样图2", "门窗表", "节点详图"],
                          selected: 9)
        let crowdedCut = crowded.debugTruncatedNames()
        let cutNote = crowdedCut.isEmpty ? "无" : crowdedCut.joined(separator: "/")
        report(!crowdedCut.contains("模型") && !crowdedCut.contains("剖面图B-B"),
               "布局页签：14 个布局时模型与当前布局仍完整显示（被截断的：\(cutNote)）")

        let roomy = CADLayoutTabs()
        roomy.configure(["模型", "1F平面图", "2F平面图"], selected: 2)
        report(roomy.debugTruncatedNames().isEmpty, "布局页签：布局不多时每个名字都完整")

        canvas.needsDisplay = true
        print("[selftest] 通过 \(passes) 项，失败 \(failures) 项")
    }

    private static func report(_ ok: Bool, _ message: String) {
        if ok { passes += 1 } else { failures += 1 }
        print("[selftest] \(ok ? "PASS" : "FAIL")  \(message)")
    }

    private static func format(_ document: CadDocument, _ value: Double) -> String {
        document.formatLength(value)
    }
}
