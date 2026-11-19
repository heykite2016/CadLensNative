import AppKit
import Metal
import QuartzCore

final class CanvasView: NSView {
    // MARK: Model

    var document: CadDocument? {
        didSet { documentChanged() }
    }

    var space: Int32 = 0 {
        didSet {
            guard space != oldValue else { return }
            // 换空间=换一张显示列表：半成品标注、批量预览和尺寸线放置
            // 都不能跨空间存活，否则会落到错误的布局里。
            activeTool = nil
            pendingBatch.removeAll()
            awaitingDimensionLine = false
            measurePoints.removeAll()
            // Switching tabs swaps the document's display list (paper entities
            // + model content projected through this layout's viewports).
            invalidateSheet()
            withSheetQueue { [weak self] in
                self?.document?.activateSpace(self?.space ?? 0)
            }
            hatchView.space = space
            hatchView.invalidate()
            measureSheetTextHeight()
            // Switching layouts must drop the previous space's GPU geometry
            // and rebuild it *now*, not on the 0.12 s settle timer. The stroke
            // buffer is keyed by scale/pixelScale only (`needsRebuild`), so if
            // two layouts happen to fit at a similar zoom the stale segments
            // survive until the timer fires — visible as "切布局后残留上一个
            // 布局的线". clear() forces needsRebuild, and activateSpace above
            // already ran synchronously (sheetQueue.sync), so the new display
            // list is in place for the rebuild.
            metalView.renderer?.clear()
            // 切空间不重置视图：进过的空间用回它自己那份相机，没进过的
            // 才按全图取景。换图时 `spaceCameraMemo` 被清掉，所以这里读到
            // 的一定是本图里的位置。
            if !spaceMemoSuspended {
                spaceCameraMemo[oldValue] = transform
            }
            if let memo = spaceCameraMemo[space], memo.scale > 0 {
                apply(transform: memo)
                fittedBounds = bounds
            } else {
                zoomToExtents(animated: false)
            }
            rebuildMetalGeometry()
            needsDisplay = true
            onSpaceChanged?(space)
        }
    }

    var settings = CadSettings.load() {
        didSet {
            // The renderer's caches are keyed by entity, not by style, so a
            // settings change only needs the raster dropped. Rebuilding the
            // renderer would throw away the SHX/geometry caches for nothing.
            invalidateSheet()
            hatchView.settings = settings
            rebuildMetalGeometry()
            updateCrosshair()
            // The pointer cursor depends on `showCrosshair`, so the cursor
            // rects have to be re-registered or toggling the crosshair leaves
            // an invisible cursor behind on the canvas.
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    // MARK: Camera

    var transform = ViewTransform()

    /// 每个空间（模型 / 各布局）各记一份视图。模型里放大看节点，切到布局出
    /// 图，再切回来应该还是刚才那个放大位置——切页签等于换了一张图纸，不该
    /// 顺手把相机也清了。
    private var spaceCameraMemo: [Int32: ViewTransform] = [:]
    /// `load(document:space:)` 正把新图的相机往里装：那一刻旧空间那份属于
    /// 上一张图，不能记。
    private var spaceMemoSuspended = false

    /// True while the user is panning, zooming or dragging: detail is reduced
    /// so the sheet keeps up with the mouse instead of waiting for a bitmap.
    private var isInteracting = false
    private var interactionTimer: Timer?

    var renderer: CadRenderer?
    /// Document the current renderer was built for; the caches inside it are
    /// only valid for that display list.
    var rendererDocument: CadDocument?
    let metalView = MetalCanvasView()
    /// Paper/fill layer. Reached from the drag handlers so a translucent pan
    /// moves the cached raster instead of re-rasterising it.
    let hatchView = HatchView()
    private let overlayView = CanvasOverlayView()

    // MARK: Cached sheet
    //
    // The sheet is rasterised once per (camera, size, quality) and then blitted
    // through an affine transform. Panning and zooming used to re-stroke every
    // visible entity on every mouse tick  189 k entities meant ~365 ms per
    // frame, i.e. 2-3 fps. A blit is a few hundred microseconds, so the gesture
    // stays attached to the pointer, and a background pass replaces the image
    // with a full-quality raster once the input settles. Nothing is simplified
    // to buy the speed: the crisp frame is exactly what the old code drew.

    /// Last raster of the drawing, at `sheetTransform`.
    var sheetImage: CGImage?
    var sheetTransform = ViewTransform()
    var sheetPointSize = CGSize.zero
    var sheetSpace: Int32 = -1
    /// Quality/visibility signature; a change (line weights, appearance) makes
    /// the cached raster stale.
    var sheetSignature: Int = 0
    /// Serialises every use of `renderer` and of the document display list.
    /// Rendering happens on this queue; the main thread only blits.
    let sheetQueue = DispatchQueue(label: "cadlens.sheet.render",
                                   qos: .userInitiated)
    var sheetWorkItem: DispatchWorkItem?
    /// Identity of the most recent request, so a slower earlier render cannot
    /// overwrite a newer raster. Guarded by `sheetLock` because it is bumped on
    /// the main thread and read on the render queue — `DispatchQueue.main.sync`
    /// from the worker would deadlock against the synchronous first render.
    var sheetRequestID = 0
    let sheetLock = NSLock()
    var sheetRenderPending = false
    /// Camera of the request already in flight. A redraw for an unchanged
    /// camera must not restart the debounce, or a steady stream of redraws
    /// would keep postponing the crisp pass forever.
    var sheetPendingTransform = ViewTransform()

    // MARK: Interaction state

    var activeTool: MeasureKind? {
        didSet {
            measurePoints.removeAll()
            measureHover = nil
            awaitingDimensionLine = false
            pendingBatch.removeAll()
            pendingBatchViewRect = .zero
            if activeTool != nil {
                // 工具互斥：选了测量工具就退出窗口缩放/打印选区/删除，
                // 否则下一次点击还会被上一个模式截走。
                eraseMode = false
                zoomWindowMode = false
                printRegionMode = false
            }
            window?.invalidateCursorRects(for: self)
            onPromptChanged?(activeTool.map(prompt(for:)) ?? "")
            onToolChanged?(activeTool)
            // 选工具后立刻把光标反馈摆出来：即使指针此刻还在工具调色板上，
            // 也要用最后已知的画布位置显示，而不是等用户"点一下画布"才出现。
            // 工具已经收工时不能留这个预览——否则画布上会浮着一个吸附点，
            // 看着像还有一条标注没画完。
            if activeTool != nil, let last = lastCanvasPointer {
                measureHover = constrained(last)
            }
            updateCrosshair()
            needsDisplay = true
        }
    }

    /// 一条标注落定，工具就收工：回到"没选工具"的状态。
    ///
    /// 每个标注命令都是"画完一条就结束"（AutoCAD 里 DLI/DAL 也是这么收尾
    /// 的），留着工具激活只会让下一次点击在用户没准备的时候又落一个点。
    func finishToolAfterCommit() {
        activeTool = nil
        // 刚生成的标注不要在“选中/编辑”状态里留着：add() 会把它设为
        // selectedAnnotation，画布上就是一层蓝色高亮，用户必须再点一下
        // 空白处才退出。测量完成就是查看状态，清掉选中。
        selectedAnnotation = nil
        onSelectionChanged?(nil)
        // 即使 activeTool 已经是 nil，也显式同步一次调色板。工具状态和
        // 左侧蓝色高亮曾经在某些收尾路径上不同步，用户得再点一下画布才
        // 退出；多这一行是幂等的，不改变正常路径。
        onToolChanged?(nil)
        measureHover = nil
        snapResult = nil
        needsDisplay = true
    }

    /// 指针离开画布前的最后一个画布坐标。工具切换/关掉设置面板时用它立刻
    /// 恢复橡皮筋预览，不必等用户把鼠标移回画布再触发 mouseMoved。
    var lastCanvasPointer: CGPoint?
    /// 没有活动命令时按回车/空格重复上一个测量工具，和 CAD 的习惯一致。
    var onRepeatLastTool: (() -> Void)?

    var measurePoints: [CGPoint] = []
    private var hasPerformedInitialFit = false
    /// Canvas size captured by the last fit-to-extents, used to detect the
    /// post-layout growth that would otherwise leave the sheet clipped.
    private var fittedBounds = CGRect.zero
    /// Width covered by the floating tool palette on the leading edge. The
    /// canvas spans the whole window and the palette sits on top of it, so
    /// centring the drawing on the full width pushed its left edge underneath
    /// the toolbar and clipped it.
    var leadingOverlayInset: CGFloat = 0
    /// 四周浮层压住的宽度。图纸铺满整窗之后，"显示全图"不能把内容塞到玻璃
    /// 工具岛和命令行底下，所以取景要按这块可见区域来算。
    var overlayInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

    /// 去掉浮层之后的可见矩形（视图坐标，原点在左下）。
    private func usableRect(in size: CGSize) -> CGRect {
        let left = max(overlayInsets.left, leadingOverlayInset)
        let rect = CGRect(x: left, y: overlayInsets.bottom,
                          width: max(size.width - left - overlayInsets.right, 60),
                          height: max(size.height - overlayInsets.top - overlayInsets.bottom, 60))
        return rect
    }
    /// Set when a document/space is loaded but the view has not yet been laid
    /// out at its final size. The first `layout()` with a valid, on-screen
    /// bounds performs the fit; fitting earlier (with a transient zero/small
    /// frame) is what used to shrink the sheet into a corner.
    private var pendingInitialFit = false
    var measureHover: CGPoint?
    /// 两点已落、等第三点确定尺寸线位置（DIMALIGNED / DIMLINEAR）。
    var awaitingDimensionLine = false
    /// 批量标注在框选后先进入预览，点击/回车才落图；Esc 取消。
    var pendingBatch: [Annotation] = []
    /// 框选区域（视图坐标），预览时画一圈虚线，让用户知道框住了哪块。
    var pendingBatchViewRect: CGRect = .zero
    /// Test hook: pins the crosshair to a view point so the scripted screenshot
    /// harness can capture it without a real pointer in the window.
    var crosshairOverride: CGPoint?
    var snapResult: SnapResult?
    /// 当前孔径内的全部捕捉候选；Tab 在它们之间循环。
    var snapOptions: [SnapResult] = []
    var snapOptionIndex = 0
    var selectedAnnotation: Int?
    var draggingLabel = false
    var labelDragStart: CGPoint = .zero
    var labelDragOriginOffset: CGPoint = .zero
    var isPanning = false
    var pointerInside = false
    /// 指针压在玻璃浮层上（工具岛、竖排、侧栏、命令行、状态条）。
    ///
    /// 画布铺满整窗，这些浮层只是压在上面，鼠标并不会"离开画布"，所以十字
    /// 光标得由浮层显式通知才收得起来；光标形状则靠浮层自己注册箭头矩形。
    var pointerOverChrome = false {
        didSet {
            guard pointerOverChrome != oldValue else { return }
            updateCrosshair()
            if !usesMetal { needsDisplay = true }
        }
    }
    var panStartView: CGPoint = .zero
    var panStartOrigin: CGPoint = .zero
    /// 框选矩形（批量标注 / 删除共用），void 坐标系。
    var selectionRect: CGRect?
    var selectionAnchor: CGPoint = .zero
    /// 指针下面那条标注（框选/删除/空闲时的悬停反馈）。
    ///
    /// 没有这个反馈，删除模式下用户点了才知道"刚才那一下会不会删掉东西"，
    /// 选择模式下也看不出标注是可以点选的。
    var hoveredAnnotation: Int? {
        didSet { if oldValue != hoveredAnnotation { needsDisplay = true } }
    }

    /// 删除工具：点选删除，拖框删除被完全框选的标注。
    var eraseMode = false {
        didSet {
            window?.invalidateCursorRects(for: self)
            if eraseMode {
                activeTool = nil
                measurePoints.removeAll()
                measureHover = nil
                onPromptChanged?("删除标注：点击单选，或拖框删除完全框选的标注 · Esc 退出")
            }
            onEraseChanged?(eraseMode)
        }
    }

    /// A press with a tool armed whose pick has not been committed yet. See
    /// `beginPick` — press-and-drag pans the sheet, press-and-release picks.
    var pendingPickView: CGPoint?
    /// True while a pan that started as a press-with-a-tool is running.
    var panDidStartFromPick = false
    /// Last string written to the command line while calibrating, so a mouse
    /// move that does not change the reading does not re-lay-out the bar.
    var calibrationReadout = ""

    /// View tools: dragging pans the sheet, or drags a rubber band to zoom.
    var panMode = false {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    var zoomWindowMode = false {
        didSet {
            // 两个模式互斥，赋值时不能再次触发对方（否则互相置 false 会递归）。
            guard oldValue != zoomWindowMode else { return }
            window?.invalidateCursorRects(for: self)
            // 窗口缩放是"用一次"的动作，不是开关：框完就退，按钮的高亮要跟着灭。
            onZoomWindowChanged?(zoomWindowMode)
            if zoomWindowMode {
                printRegionMode = false
                activeTool = nil
                measurePoints.removeAll()
                measureHover = nil
                onPromptChanged?("窗口缩放：点两个对角点，或直接拖出矩形 · Esc 退出")
            } else {
                rectPick = RectPick()
                needsDisplay = true
            }
        }
    }

    /// 两点矩形选框的共享状态。窗口缩放与打印选区是同一个手势、同一条捕捉
    /// 链路，只有"松手之后干什么"不同。
    struct RectPick {
        var armed = false
        var startView: CGPoint = .zero
        var startWorld: CGPoint = .zero
        var rect: CGRect?
        var currentWorld: CGPoint = .zero
    }
    var rectPick = RectPick()

    /// 打印选区：和窗口缩放是同一套"两个对角点"的手势，只是结果不是改相机，
    /// 而是把这块世界矩形交给打印预览。要求也一样：十字光标 + 对象捕捉。
    var printRegionMode = false {
        didSet {
            guard oldValue != printRegionMode else { return }
            window?.invalidateCursorRects(for: self)
            if printRegionMode {
                activeTool = nil
                eraseMode = false
                panMode = false
                zoomWindowMode = false
                measurePoints.removeAll()
                measureHover = nil
                onPromptChanged?("打印选区：点两个对角点，或直接拖出矩形 · Esc 取消")
            } else {
                rectPick = RectPick()
                needsDisplay = true
            }
            onPrintRegionChanged?(printRegionMode)
        }
    }
    var onPrintRegionChanged: ((Bool) -> Void)?
    /// 选区落定：世界坐标矩形 + 当前空间。
    var onPrintRegionPicked: ((CGRect, Int32) -> Void)?
    private var viewHistory: [ViewTransform] = []

    /// Reports the live measurement string for the status bar.
    var onPromptChanged: ((String) -> Void)?
    var onCursorMoved: ((CGPoint) -> Void)?
    var onSelectionChanged: ((Annotation?) -> Void)?
    var onAnnotationsChanged: (() -> Void)?
    var onToolChanged: ((MeasureKind?) -> Void)?
    /// 删除模式的开关（工具栏按钮、调色板行、Esc 三条路都可能改它），
    /// 集中播报一次，三处高亮才不会各说各话。
    var onEraseChanged: ((Bool) -> Void)?
    var onZoomWindowChanged: ((Bool) -> Void)?
    var onSpaceChanged: ((Int32) -> Void)?
    var onDoubleClick: (() -> Void)?
    /// Camera scale after every zoom/pan, for the status bar read-out.
    var onZoomChanged: ((CGFloat) -> Void)?

    /// Soft switch for the annotation layer. Hidden annotations still hit-test
    /// and still export; only the on-screen pass skips them, which is what the
    /// status-bar "标注" toggle is expected to do.
    var annotationsHidden = false {
        didSet { needsDisplay = true }
    }

    // MARK: Calibration

    /// Two-point scale calibration. The handler receives the measured drawing
    /// length and a closure that applies the resulting factor.
    var calibrationPoints: [CGPoint] = []
    var calibrationHandler: ((Double, @escaping (Double) -> Void) -> Void)?

    func beginCalibration(_ handler: @escaping (Double, @escaping (Double) -> Void) -> Void) {
        calibrationPoints.removeAll()
        calibrationReadout = ""
        calibrationHandler = handler
        activeTool = nil
        panMode = false
        zoomWindowMode = false
        measureHover = nil
        snapResult = nil
        onPromptChanged?(settings.objectSnap
            ? "比例校准：点击已知长度的第一个点 · 可捕捉端点/交点/中点"
            : "比例校准：点击已知长度的第一个点 · 对象捕捉已关闭，按 F3 开启")
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func handleCalibrationClick(_ world: CGPoint) {
        let point = calibrationConstrained(world)
        calibrationPoints.append(point)
        measureHover = point
        calibrationReadout = ""
        if calibrationPoints.count < 2 {
            onPromptChanged?("比例校准：点击第二个点 · 已捕捉 "
                + (snapResult?.label ?? "自由点"))
            needsDisplay = true
            return
        }
        let first = calibrationPoints[0], second = calibrationPoints[1]
        let measured = MeasurementMath.distance(first, second)
        let handler = calibrationHandler
        calibrationHandler = nil
        calibrationPoints.removeAll()
        measureHover = nil
        snapResult = nil
        needsDisplay = true
        guard let handler, measured > 0 else { return }
        handler(measured) { [weak self] factor in
            guard let self, let document = self.document else { return }
            document.unitMeters *= factor
            document.unitIsCalibrated = true
            self.invalidateSheet()
            self.needsDisplay = true
            // The reference line stays on the sheet as a real dimension. It is
            // both the record of what the scale was set against and the fastest
            // way to catch a mistyped digit: the number it shows is the value
            // the drawing now believes that line measures.
            var annotation = Annotation(kind: .aligned, space: self.space,
                                        points: [first, second])
            annotation.value = Double(measured)
            annotation.text = document.formatLength(Double(measured))
            annotation.note = "比例校准基准"
            self.add(annotation)
        }
    }

    // MARK: Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        // Paper and hatches at the bottom, strokes and labels on the GPU layer
        // above them, annotations and the pointer on top.
        hatchView.frame = bounds
        hatchView.autoresizingMask = [.width, .height]
        addSubview(hatchView, positioned: .below, relativeTo: nil)
        metalView.frame = bounds
        metalView.autoresizingMask = [.width, .height]
        addSubview(metalView, positioned: .above, relativeTo: hatchView)
        overlayView.frame = bounds
        overlayView.autoresizingMask = [.width, .height]
        overlayView.canvas = self
        addSubview(overlayView, positioned: .above, relativeTo: metalView)
        // The single-pass Core Graphics path paints the background, hatches,
        // strokes, labels and the overlay itself, so the GPU stroke layer and
        // the cached hatch layer are hidden while it is the active renderer.
        hatchView.isHidden = !usesMetal
        metalView.isHidden = !usesMetal
        overlayView.isHidden = !usesMetal
        // Diagnostic: measure how much of an interaction frame is the window
        // server compositing three full-screen layers rather than our own pass.
        if let layers = getenv("CADLENS_LAYERS").map({ String(cString: $0) }) {
            hatchView.isHidden = layers == "metal"
            overlayView.isHidden = layers == "metal"
        }
        registerForDraggedTypes([.fileURL])
    }

    /// The on-screen pass renders through the same single Core Graphics path
    /// the reference uses (CadView.cpp::drawCadEntities) and that the headless
    /// exporter already runs — one pass that paints the background, every
    /// hatch, stroke, label and the composed layout viewport clips together.
    ///
    /// The old GPU-stroke + cached-hatch split is disabled: on a composed
    /// layout it rendered an empty sheet (grid and paper only) even though the
    /// document held 30k entities and 566 hatches. Until that split can be
    /// re-validated against the reference it stays off, so what is on screen
    /// is exactly what the exporter produces.
    /// Core Graphics was measured to be unusable for the real workload: with a
    /// pen wider than one device pixel, stroking 100 k segments takes minutes
    /// (CG only has a fast path for sub-pixel "thin" strokes), and on a Retina
    /// canvas every CAD line weight is wider than that. The Metal pass exists
    /// for exactly this reason; `CADLENS_METAL=0` forces the old path back for
    /// comparison.
    /// 只读：供开发自测判断当前渲染通路（Metal / CG 回退）。
    var isUsingMetal: Bool { usesMetal }

    private var usesMetal: Bool {
        guard getenv("CADLENS_METAL").map({ String(cString: $0) }) != "0" else {
            return false
        }
        return MTLCreateSystemDefaultDevice() != nil
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { !usesMetal }

    /// Redraw requests have to reach the overlay view too: it owns everything
    /// that is not on the GPU layer.
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            super.needsDisplay = newValue
            if newValue { overlayView.needsDisplay = true }
        }
    }

    /// True when the overlay draws anything anchored in world space, which is
    /// what makes it depend on the camera. Annotations and the live measurement
    /// rubber band do; the pointer crosshair, the snap marker and the zoom
    /// window are all in view space and are redrawn by their own triggers.
    private var overlayHasWorldContent: Bool {
        if activeTool != nil || calibrationHandler != nil || eraseMode
            || selectionRect != nil
            || !calibrationPoints.isEmpty || !measurePoints.isEmpty { return true }
        guard let document else { return false }
        return document.annotations.contains { $0.space == space }
    }

    /// Redraw triggered by a pure camera change.
    ///
    /// `needsDisplay` also dirties the overlay, and AppKit answers that by
    /// re-uploading the overlay's whole 2560×1600 backing store — 11 ms of the
    /// frame on this GPU — even when the overlay holds nothing that moved. The
    /// paper, the grid and the drawing are all on layers that follow the camera
    /// on the GPU, so unless the overlay owns world-space content the camera
    /// pass leaves it alone.
    func needsDisplayForCameraMove() {
        if overlayHasWorldContent {
            needsDisplay = true
        } else {
            super.needsDisplay = true
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Render at the backing store's own resolution. Dragging the window to a
        // Retina display (or launching straight on one) otherwise leaves the
        // layer at 1x, so a 0.7 pt line is drawn once and upscaled — visibly
        // jagged, exactly like anti-aliasing being off.
        if let scale = window?.backingScaleFactor {
            layer?.contentsScale = scale
        }
        needsDisplay = true
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleInitialFit()
    }

    /// Fit once, but only after the window has been laid out at its final size.
    /// Fitting earlier (while the canvas is still constrained by the toolbar,
    /// command bar and palette, or while the window is still resizing) shrinks
    /// the sheet into a corner and leaves the lower-right blank.
    private func scheduleInitialFit(delay: TimeInterval = 0.35) {
        guard document != nil, !hasPerformedInitialFit else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.window != nil, !self.hasPerformedInitialFit else { return }
            // The window has to have been laid out at its final size first;
            // fitting against the transient pre-layout bounds is what shrank
            // the sheet into a corner. Retry shortly if it is still settling.
            guard self.bounds.width > 40, self.bounds.height > 40 else {
                self.scheduleInitialFit(delay: 0.15)
                return
            }
            // First open frames the drawing's declared extent (header
            // EXTMIN/EXTMAX) through the same 32x32 density cluster the
            // reference viewer uses — see CadDocument.initialViewBox. Feeding
            // that pass the declared extent is what the author actually saved
            // with the file; feeding it the entity union instead let stray
            // construction geometry 8.7 km away hijack the framing and shrank
            // a 30 m plan to a thumbnail.
            self.zoomToExtents(animated: false)
            self.hasPerformedInitialFit = true
        }
    }

    override func layout() {
        super.layout()
        updateCrosshair()
        // The delayed first fit can still run against a canvas that has not
        // received its final size: the side panel, toolbar and command bar are
        // laid out after the window appears, so the canvas grows by a few
        // percent. Fitting to the smaller intermediate size left the sheet
        // touching — and clipping at — the left edge. Re-fit once when the
        // canvas has grown noticeably; a size the user chose by dragging is
        // left alone because it never differs from the fitted one by this much.
        guard hasPerformedInitialFit, bounds.width > 40, bounds.height > 40,
              fittedBounds.width > 0 else { return }
        if abs(bounds.width - fittedBounds.width) > fittedBounds.width * 0.08
            || abs(bounds.height - fittedBounds.height) > fittedBounds.height * 0.08 {
            // Keep the same framing as the first fit; otherwise a late layout
            // pass silently replaces the drawing camera with a show-all view.
            zoomToExtents(animated: false)
        }
    }

    /// Median height of the sheet's own numeric labels, in world units.
    ///
    /// 首选图纸尺寸标注自己的文字（DIMENSION 块展开出来的 TEXT，带
    /// `EntityFlags.dimension`）：那串数字就是用户要对比的"图上原有的标注
    /// 字号"。图纸里的尺寸被炸开成普通 TEXT 时，退回"纯数字的文字"这一条
    /// 启发式——爆炸后的尺寸值仍然是纯数字，而标题、房间名不会。
    ///
    /// Sampling stops at 4 000 entities: a 389 k-entity sheet does not need a
    /// better median than that, and the pass runs only when the document or the
    /// space changes.
    private func measureSheetTextHeight() {
        // 一个空间只量一次：这一趟要扫全部文字图元，不能挂在每帧的重绘上。
        // 换图纸时 `documentChanged` 会把计量作废。
        guard measuredTextSpace != space else { return }
        measuredTextSpace = space
        guard let document else {
            AnnotationRenderer.sheetTextHeight = 0
            return
        }
        var dimensionHeights: [CGFloat] = []
        var numericHeights: [CGFloat] = []
        dimensionHeights.reserveCapacity(512)
        numericHeights.reserveCapacity(1024)
        let log = ProcessInfo.processInfo.environment["CADLENS_TEXT_LOG"] != nil
        for entity in document.entities {
            guard entity.space == space, entity.kind == .text, entity.h > 1e-9 else { continue }
            let text = entity.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text.count <= 16 else { continue }
            if entity.isDimensionInk {
                dimensionHeights.append(CGFloat(entity.h))
            } else {
                let numeric = text.allSatisfy { character in
                    character.isNumber || character == "." || character == ","
                        || character == "-" || character == " "
                }
                if numeric { numericHeights.append(CGFloat(entity.h)) }
            }
            if dimensionHeights.count + numericHeights.count >= 4000 { break }
        }
        // 尺寸文字的样本太少时宁可换用"纯数字"这一路：某些图纸的尺寸全被
        // 炸成了普通文字，一条都带不上标记。
        let sample = dimensionHeights.count >= 6 ? dimensionHeights : numericHeights
        guard sample.count >= 6 else {
            AnnotationRenderer.sheetTextHeight = 0
            if log {
                print("[text] 没有可用的尺寸文字样本（标注文字 \(dimensionHeights.count) / 数字 \(numericHeights.count)），按样式字号画")
            }
            return
        }
        let sorted = sample.sorted()
        let median = sorted[sorted.count / 2]
        AnnotationRenderer.sheetTextHeight = median
        if log {
            print(String(format: "[text] space=%d 尺寸文字=%d 数字=%d 中位高度=%.3f 世界单位 (%.2f%% 分位 %.3f)",
                         space, dimensionHeights.count, numericHeights.count, Double(median),
                         Double(sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))])))
        }
    }

    private var measuredTextSpace: Int32 = -1

    private func documentChanged() {
        hasPerformedInitialFit = false
        fittedBounds = .zero
        // 相机记忆跟着图纸走：换图之后每个空间的视图都重新取景。
        spaceCameraMemo.removeAll()
        selectedAnnotation = nil
        measurePoints.removeAll()
        awaitingDimensionLine = false
        pendingBatch.removeAll()
        pendingBatchViewRect = .zero
        invalidateSheet()
        // 换图（含带相机切标签）时先把 GPU 缓冲清掉。渲染器活得比文档长，
        // 若只换 document 引用不重建，`present` 会继续画上一张的线段和文字，
        // 直到手势改变 scale/visible 触发 settle 重建才消失——这就是"切图有
        // 残影，手动移一下才没"的来源。清掉后 needsStrokeRebuild 必然返回
        // true，下一次 draw 的 refreshMetalGeometry 立刻重建新图几何。
        metalView.renderer?.clear()
        // Switching document/space mutates the display list the background
        // raster reads, so it has to wait for any pass already running.
        withSheetQueue { [weak self] in
            guard let self else { return }
            self.renderer = self.document.map { CadRenderer(document: $0) }
            self.rendererDocument = self.document
            if let document = self.document {
                document.displayUnit = self.settings.displayUnit
                document.areaUnit = self.settings.areaUnit
                document.precision = self.settings.precision
                document.activateSpace(self.space)
            }
            // 先切显示列表再量字高：纸空间的字是"模型文字 × 视口比例"投影
            // 进来的，量在切空间之前拿到的是上一张表的字号。
            self.measuredTextSpace = -1
            self.measureSheetTextHeight()
        }
        hatchView.document = document
        hatchView.space = space
        hatchView.settings = settings
        pendingInitialFit = (document != nil)
        // Only tessellate once the camera is real. At this point the transform
        // is still the placeholder (scale 1), where the 0.35 px tolerance
        // simplifies almost nothing and a 135k-entity drawing would spend
        // minutes uploading raw samples — all of which the automatic fit is
        // about to invalidate. `settleMetalGeometry()` builds after the fit.
        if !pendingInitialFit { rebuildMetalGeometry() }
        // Fit once the sheet is loaded. `viewDidMoveToWindow` usually fires
        // before any document is open (document == nil), so the initial fit is
        // also scheduled here — otherwise the camera stays at the default
        // origin=0/scale=1 and every entity beyond world (0,0)-(900,700) lands
        // off-screen, leaving an empty grid.
        if document != nil { scheduleInitialFit() }
        needsDisplay = true
    }

    /// Re-uploads the stroke list after the document, space or layer visibility
    /// changes. Camera moves do not touch it: they only update a shader uniform.
    private func rebuildMetalGeometry() {
        guard usesMetal else { return }
        guard let document, let renderer = metalView.renderer else {
            // 关图 / 换图：缓冲区里还压着上一张的线段和文字。渲染器比文档
            // 活得长，不显式清掉，`present` 每帧都会把旧图重新画一遍，
            // 空画布上就留下一整张残影。
            metalView.renderer?.clear()
            return
        }
        let scale = transform.scale > 0 ? transform.scale : 1
        renderer.build(document: document, space: space,
                       showLineweights: settings.showLineweights, scale: scale,
                       visible: visibleWorldRect)
        renderer.buildText(document: document, space: space, scale: scale,
                           pixelScale: window?.backingScaleFactor ?? 2,
                           quality: settings.canvasQuality)
    }

    /// Geometry is tessellated and labelled for the current zoom, so it only
    /// needs rebuilding once the camera moved far enough to matter.
    private func refreshMetalGeometry() {
        guard let document, let renderer = metalView.renderer else { return }
        // 手势进行中不重建：500k 图的 stroke 重建约 78 ms，发生在指头下面
        // 就是一帧掉到 12 fps。旧缓冲按新相机拉伸继续画（曲线/文字在阈值
        // 内仍然可用），松手 0.12 s 后再做全质量重建。
        // 首次没有几何时例外，否则加载后会短暂空白。
        if isInteracting, renderer.hasStrokeGeometry { return }
        let pixelScale = window?.backingScaleFactor ?? 2
        guard renderer.needsRebuild(scale: transform.scale, pixelScale: pixelScale)
        else { return }
        if space > 0 {
            renderer.buildText(document: document, space: space,
                               scale: transform.scale, pixelScale: pixelScale,
                               quality: settings.canvasQuality)
            // Safety net for the case where no fit ever ran (no window yet):
            // without a stroke buffer the layout would stay blank.
            if !pendingInitialFit, !renderer.hasStrokeGeometry {
                rebuildMetalGeometry()
            }
        } else {
            rebuildMetalGeometry()
        }
    }

    /// Re-tessellates once a gesture has settled.
    ///
    /// The stroke buffer is baked for one camera scale, and a layout used to
    /// keep the buffer it was built with on tab switch forever. Staring at a
    /// 1:150 sheet at 1.6x therefore drew the chords that were only accurate
    /// for the fit-all view ten times smaller — every arc became a straight
    /// line and small closed polylines collapsed into a diagonal. Rebuilding on
    /// every zoom step would stall the gesture instead, so it waits for the
    /// 0.12 s interaction timer, exactly like the raster layers.
    private func settleMetalGeometry() {
        if ProcessInfo.processInfo.environment["CADLENS_NO_SETTLE"] != nil { return }
        guard usesMetal, let document, let renderer = metalView.renderer else { return }
        let scale = transform.scale > 0 ? transform.scale : 1
        let pixelScale = window?.backingScaleFactor ?? 2
        let started = CACurrentMediaTime()
        // Text atlas 和 stroke 是两套阈值：只有文字需要更新时不要连带重建
        // 500k 条线段。
        if renderer.needsRebuild(scale: scale, pixelScale: pixelScale) {
            renderer.buildText(document: document, space: space, scale: scale,
                               pixelScale: pixelScale, quality: settings.canvasQuality)
        }
        if renderer.needsStrokeRebuild(scale: scale, visible: visibleWorldRect) {
            renderer.build(document: document, space: space,
                           showLineweights: settings.showLineweights, scale: scale,
                           visible: visibleWorldRect)
        }
        if ProcessInfo.processInfo.environment["CADLENS_FRAME_LOG"] != nil {
            print(String(format: "[rebuild] %6.2f ms", (CACurrentMediaTime() - started) * 1000))
        }
    }

    /// World rectangle the camera can see, inflated so a short pan does not
    /// force another tessellation pass.
    var visibleWorldRect: CGRect {
        guard bounds.width > 1, bounds.height > 1, transform.scale > 0 else {
            return .null
        }
        let rect = CGRect(x: transform.origin.x, y: transform.origin.y,
                          width: bounds.width / transform.scale,
                          height: bounds.height / transform.scale)
        // Reference: worldRect + 2 px. A quarter-viewport margin absorbs the
        // small pans between two settle passes without quadrupling the cull
        // volume the way a 60% margin did.
        return rect.insetBy(dx: -rect.width * 0.25, dy: -rect.height * 0.25)
    }

    // MARK: Camera API

    /// A stale or mis-decoded VPORT camera can point far outside the drawing;
    /// restoring it would open on an empty region. Require the saved view
    /// window to actually intersect the drawing content, otherwise fall back to
    /// entity-cluster framing.
    private func isSavedViewPlausible(_ saved: CadDocument.SavedView) -> Bool {
        guard let document else { return true }
        // Validate against the FULL entity union, not the 2–98% percentile box.
        // On this sheet the author's saved camera sits on the elevation detail
        // at the right-hand edge of the drawing, just outside the percentile
        // box — the old check rejected it, fell back to a whole-sheet fit, and
        // opened the file zoomed so far out that the drawing looked incomplete.
        var union = CGRect.null
        for i in document.entityIndices(in: 0) {
            let b = document.entities[i].box
            // `isEmpty` is true for a horizontal or vertical segment, so testing
            // it here dropped every wall and dimension line out of the union the
            // plausibility check runs against.
            guard b.width.isFinite, b.height.isFinite,
                  b.minX.isFinite, b.minY.isFinite else { continue }
            union = union.isNull ? b : union.union(b)
        }
        guard !union.isNull, union.width > 0, union.height > 0 else { return true }
        let window = CGRect(x: saved.center.x - saved.width / 2,
                            y: saved.center.y - saved.height / 2,
                            width: saved.width, height: saved.height)
        // A genuinely stale camera points at empty space and would open the
        // document on a blank screen; anything overlapping the drawing (with a
        // quarter-extent of slack for edge detail) is the author's framing.
        let reach = union.insetBy(dx: -union.width * 0.25, dy: -union.height * 0.25)
        return window.intersects(reach) || reach.contains(saved.center)
    }

    func zoomToExtents(animated: Bool, preferSavedView: Bool = false) {
        guard let document, let info = document.spaceInfo(space) else { return }
        let viewSize = bounds.size
        guard viewSize.width > 10, viewSize.height > 10 else { return }
        // CadView.cpp::fitToInitialView(): a CAD file persists the active model
        // camera as VIEWCTR / VIEWSIZE. Restoring it on first open reproduces
        // the author's framing — including outer plan views that an
        // entity-extent fit would crop. Only the first open uses it; the
        // "show all" command still frames the whole content box.
        if preferSavedView, space == 0, let saved = document.savedView,
           saved.width > 1e-9, saved.height > 1e-9,
           isSavedViewPlausible(saved) {
            let usable = usableRect(in: viewSize)
            let scale = max(1e-14, min(usable.width / saved.width,
                                       usable.height / saved.height))
            let origin = CGPoint(x: saved.center.x - usable.midX / scale,
                                 y: saved.center.y - usable.midY / scale)
            pushViewHistory()
            apply(transform: ViewTransform(origin: origin, scale: scale))
            fittedBounds = bounds
            AnnotationRenderer.fitScale = scale
            return
        }
        // Model space: the drawing's own camera when the file has one, else the
        // full content box. Paper space: `info.box` (LAYOUT.EXTMIN/EXTMAX) 常常
        // 只是上次保存时的视图范围，比整张图小一截，直接拿它适配会把图纸四
        // 周裁掉。改用 `layoutExtent`：视口纸面矩形 + 纸空间实体 + EXTMIN 的
        // 并集，那才是这张布局真实的边界。
        var box = space == 0
            ? (document.initialViewBox(for: space) ?? info.box)
            : document.layoutExtent(space)
        if box.isEmpty {
            for annotation in document.annotations where annotation.space == space && !annotation.hidden {
                for point in annotation.points {
                    box = box.isEmpty ? CGRect(x: point.x, y: point.y, width: 0, height: 0)
                        : box.union(CGRect(x: point.x, y: point.y, width: 0, height: 0))
                }
            }
        }
        guard !box.isEmpty, box.width.isFinite, box.height.isFinite else { return }
        // CadView.cpp::fitToBounds() frames 92% of the viewport and centres the
        // box, so the sheet never touches an edge. The usable area excludes the
        // strip the floating palette covers.
        let usable = usableRect(in: viewSize)
        let scale = min(usable.width * 0.92 / max(box.width, 1e-6),
                        usable.height * 0.92 / max(box.height, 1e-6))
        let origin = CGPoint(x: box.midX - usable.midX / scale,
                             y: box.midY - usable.midY / scale)
        pushViewHistory()
        apply(transform: ViewTransform(origin: origin, scale: scale))
        fittedBounds = bounds
        // The scale the sheet's own numerals are sized at; annotations lock to
        // it so they do not inflate when the user zooms into a detail.
        AnnotationRenderer.fitScale = scale
    }

    func zoom(by factor: CGFloat, anchor: CGPoint? = nil) {
        let pivot = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let world = transform.toWorld(pivot)
        let newScale = min(max(transform.scale * factor, 1e-9), 1e7)
        let origin = CGPoint(x: world.x - pivot.x / newScale,
                             y: world.y - pivot.y / newScale)
        apply(transform: ViewTransform(origin: origin, scale: newScale))
    }

    func setZoomScale(_ scale: CGFloat) {
        let pivot = CGPoint(x: bounds.midX, y: bounds.midY)
        let world = transform.toWorld(pivot)
        let newScale = min(max(scale, 1e-9), 1e7)
        apply(transform: ViewTransform(origin: CGPoint(x: world.x - pivot.x / newScale,
                                                       y: world.y - pivot.y / newScale),
                                       scale: newScale))
    }

    func center(on point: CGPoint, scale: CGFloat? = nil) {
        let targetScale = scale ?? transform.scale
        apply(transform: ViewTransform(
            origin: CGPoint(x: point.x - bounds.midX / targetScale,
                            y: point.y - bounds.midY / targetScale),
            scale: targetScale))
    }

    func worldPoint(at viewPoint: CGPoint) -> CGPoint { transform.toWorld(viewPoint) }

    /// Fits a world rectangle into the viewport with a small margin.
    func zoom(toWorldRect box: CGRect) {
        guard box.width > 0, box.height > 0, bounds.width > 10, bounds.height > 10 else { return }
        let scale = min(bounds.width / box.width, bounds.height / box.height)
        pushViewHistory()
        apply(transform: ViewTransform(origin: CGPoint(x: box.midX - bounds.midX / scale,
                                                       y: box.midY - bounds.midY / scale),
                                       scale: scale))
    }

    /// Remembers the camera before a jump so ⌘⇧Z style back-navigation works.
    func pushViewHistory() {
        if let last = viewHistory.last, last.scale == transform.scale,
           abs(last.origin.x - transform.origin.x) < 1e-9,
           abs(last.origin.y - transform.origin.y) < 1e-9 {
            return
        }
        viewHistory.append(transform)
        if viewHistory.count > 32 { viewHistory.removeFirst() }
    }

    func zoomPrevious() {
        guard let previous = viewHistory.popLast() else { return }
        apply(transform: previous)
    }

    /// 把一张图纸连同它上次的相机一起装进画布——多图纸切换走这条路。
    ///
    /// 换文档会把 `hasPerformedInitialFit` 清掉并排一次"显示全图"，所以切回
    /// 一张刚才在看节点的图纸时，如果不把相机压回去，人就得重新找位置。有
    /// 保存的相机就把它当默认取景，并取消排队中的 fit。
    func load(document newDocument: CadDocument?, space newSpace: Int32,
              camera: ViewTransform?, fitScale: CGFloat = 0) {
        document = newDocument
        guard newDocument != nil else {
            // 全部图纸都关了：回到空白画布，不要留着上一张的相机。相机留
            // 着的话下一次开图会先按旧缩放画一帧再跳回去，看着像闪了一下。
            hasPerformedInitialFit = false
            pendingInitialFit = false
            selectedAnnotation = nil
            hoveredAnnotation = nil
            measurePoints.removeAll()
            measureHover = nil
            snapResult = nil
            selectionRect = nil
            transform = ViewTransform()
            hatchView.transform = transform
            rebuildMetalGeometry()
            needsDisplay = true
            updateCrosshair()
            return
        }
        spaceMemoSuspended = true
        if space != newSpace { space = newSpace }
        spaceMemoSuspended = false
        guard let camera, camera.scale > 0 else { return }
        hasPerformedInitialFit = true
        pendingInitialFit = false
        apply(transform: camera)
        fittedBounds = bounds
        // 标注字号基准跟着图纸走：否则切回一张放大看节点的图时，标注会沿用
        // 上一张的 fit scale，数字大小突然跳一档。
        AnnotationRenderer.fitScale = fitScale
        // 带相机切图不会走 zoomToExtents，几何缓冲必须在这里显式重建一次；
        // 否则要等手势触发 settle，期间显示的是上一张图的残影。
        rebuildMetalGeometry()
    }

    func reveal(_ annotation: Annotation) {
        var box = CGRect(x: annotation.points.first?.x ?? 0,
                         y: annotation.points.first?.y ?? 0, width: 0, height: 0)
        for point in annotation.points {
            box = box.union(CGRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        let inset = max(box.width, box.height) * 0.6 + 200 / max(transform.scale, 1e-6)
        zoom(toWorldRect: box.insetBy(dx: -inset, dy: -inset))
    }

    func apply(transform newTransform: ViewTransform) {
        transform = newTransform
        hatchView.transform = newTransform
        beginInteraction()
        refreshHoverAfterCameraChange()
        needsDisplayForCameraMove()
        onZoomChanged?(newTransform.scale)
    }

    /// Wheel zoom holds the pointer still while the paper scales under it, so a
    /// rubber band anchored in world space stays behind at the old point unless
    /// it is re-solved against the new camera.
    private func refreshHoverAfterCameraChange() {
        guard activeTool != nil || calibrationHandler != nil, let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(point) else { return }
        let world = transform.toWorld(point)
        if calibrationHandler != nil {
            updateCalibrationHover(world)
        } else {
            measureHover = constrained(world)
        }
    }

    /// Lowers the detail level for the duration of a gesture, then schedules a
    /// full-quality frame once the input settles.
    func beginInteraction() {
        isInteracting = true
        hatchView.isInteracting = true
        interactionTimer?.invalidate()
        interactionTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) {
            [weak self] _ in
            guard let self else { return }
            self.isInteracting = false
            self.hatchView.isInteracting = false
            self.hatchView.needsDisplay = true
            // Curves are tessellated for the scale they were built at, so the
            // buffer has to follow the camera once the gesture stops.
            self.settleMetalGeometry()
            self.needsDisplay = true
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let frameStart = CACurrentMediaTime()
        var rebuildMS = 0.0
        var presentMS = 0.0
        if usesMetal {
            refreshMetalGeometry()
            let afterRebuild = CACurrentMediaTime()
            metalView.present(transform: transform)
            let afterPresent = CACurrentMediaTime()
            rebuildMS = (afterRebuild - frameStart) * 1000
            presentMS = (afterPresent - afterRebuild) * 1000
        } else {
            // Without a GPU pass this view draws everything itself. The sheet
            // blit paints the canvas background for the area it covers; only a
            // partial blit (or no document) needs the extra fill.
            drawDrawing(ctx)
            drawOverlay(in: ctx)
        }

        if ProcessInfo.processInfo.environment["CADLENS_FRAME_LOG"] != nil {
            let ms = (CACurrentMediaTime() - frameStart) * 1000
            print(String(format: "[frame] %6.2f ms  geo=%5.2f present=%5.2f wait=%5.2f  scale=%.5g  origin=(%.1f,%.1f)  metal=%@  interaction=%@",
                         ms, rebuildMS, presentMS, metalView.lastDrawableWaitMS,
                         transform.scale, transform.origin.x, transform.origin.y,
                         usesMetal ? "yes" : "no", isInteracting ? "yes" : "no"))
        }
    }

    /// 没有图纸时的画布：网格 + 一句引导。
    ///
    /// 关掉最后一张图后整块画布只剩一片底色，看起来像"卡住了"。铺一层和
    /// 正常画布同样的栅格，再给一句怎么继续的提示，空白就有了含义。
    private func drawEmptyState(_ ctx: CGContext) {
        guard bounds.width > 1, bounds.height > 1 else { return }
        // 走 GPU 时纸面层不画网格（它只画填充），空白画布的栅格得在这里补。
        if usesMetal, settings.showGrid, transform.scale > 0 { drawGrid(ctx) }

        let title = NSAttributedString(string: "没有打开的图纸", attributes: [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: Theme.foreground.withAlphaComponent(0.62),
        ])
        let hint = NSAttributedString(string: "⌘O 打开图纸，或把 DWG / PDF 拖进窗口",
                                      attributes: [
            .font: NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: Theme.foreground.withAlphaComponent(0.40),
        ])
        let titleSize = title.size()
        let hintSize = hint.size()
        let top = bounds.midY + 10
        title.draw(in: NSRect(x: bounds.midX - titleSize.width / 2,
                              y: top - titleSize.height,
                              width: titleSize.width, height: titleSize.height))
        hint.draw(in: NSRect(x: bounds.midX - hintSize.width / 2,
                             y: top - titleSize.height - 8 - hintSize.height,
                             width: hintSize.width, height: hintSize.height))
    }

    /// Grid, annotations, pointer feedback: everything that is not part of the
    /// drawing itself. Rendered by `CanvasOverlayView` on top of the GPU pass.
    func drawOverlay(in ctx: CGContext) {
        // Under the GPU pass the grid is stroked into the paper raster, so it
        // follows the camera on the compositor and stays behind the drawing.
        // The single-pass Core Graphics fallback has no paper layer, so it
        // keeps drawing the grid here.
        if !usesMetal, settings.showGrid { drawGrid(ctx) }
        // 画在 overlay 而不是 `draw`：纸面层是子视图且不透明，画在画布自己
        // 的 backing store 上会被它整块盖住。
        if document == nil { drawEmptyState(ctx) }
        drawAnnotations(ctx)
        drawMeasurePreview(ctx)
        drawCalibrationPreview(ctx)
        drawSnapMarker(ctx)
        drawSelectionRect(ctx)
        if !usesMetal { drawCrosshair(ctx) }
        drawZoomWindow(ctx)
    }

    /// Moves the crosshair bars. Cheap enough to call on every mouse event:
    /// it only assigns two layer frames.
    func updateCrosshair() {
        guard usesMetal, settings.showCrosshair, !pointerOverChrome,
              pointerInside || crosshairOverride != nil else {
            overlayView.setCrosshair(at: nil, pixelScale: 1)
            return
        }
        let point = crosshairOverride
            ?? convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        guard bounds.contains(point) else {
            overlayView.setCrosshair(at: nil, pixelScale: 1)
            return
        }
        overlayView.setCrosshair(at: point, pixelScale: window?.backingScaleFactor ?? 2)
    }

    /// Immediate-mode fallback and the cache miss path. Everything the user
    /// actually looks at comes from `sheetImage`; this runs only when there is
    /// no raster yet (first open, resize, settings change).
    private func drawDrawing(_ ctx: CGContext) {
        guard document != nil, transform.scale > 0,
              bounds.width > 1, bounds.height > 1 else {
            ctx.setFillColor(Theme.canvasBackground.cgColor)
            ctx.fill(bounds)
            return
        }
        // With the GPU pass active the sheet is already on screen; this layer
        // only contributes annotations and pointer feedback.
        guard !usesMetal else { return }

        let signature = currentSheetSignature()
        // A/B switch for the benchmark: `CADLENS_NO_SHEET_CACHE=1` reproduces
        // the old immediate-mode behaviour (full vector pass on every frame)
        // so the two paths can be measured on the same drawing.
        let bypass = getenv("CADLENS_NO_SHEET_CACHE") != nil
        let cacheValid = !bypass
            && sheetImage != nil
            && sheetSignature == signature
            && sheetSpace == space
            && sheetPointSize == bounds.size

        if !cacheValid {
            let request = sheetRequest(signature: signature)
            if let image = renderSheetImmediately(request) {
                sheetImage = image
                sheetTransform = request.transform
                sheetPointSize = request.size
                sheetSpace = request.space
                sheetSignature = signature
            }
        }
        guard let image = sheetImage else { return }
        blitSheet(image, in: ctx)
        // The camera moved since the raster was made: schedule the crisp pass.
        // Skipped when a pass for this very camera is already queued.
        let moved = sheetTransform.origin != transform.origin
            || sheetTransform.scale != transform.scale
        if !bypass, moved,
           !(sheetRenderPending && sheetPendingTransform == transform) {
            scheduleSheetRefresh()
        }
    }

    /// Draws one complete frame: paper/hatch layer, GPU pass and overlay.
    ///
    /// `display()` alone only draws this view, and AppKit defers the subviews
    /// to the next run-loop commit — so a benchmark loop that calls it in a
    /// tight loop measures a frame the user never sees, missing the fill blit
    /// and the grid/annotation pass entirely. This drives all three layers
    /// synchronously, which is what a real mouse event does.
    func displayFullFrame() {
        let log = ProcessInfo.processInfo.environment["CADLENS_FRAME_LOG"] != nil
        let t0 = CACurrentMediaTime()
        // The fill layer is a `CALayer` whose `contents` is only re-uploaded
        // when the raster changes, and the crosshair is two layers moved by the
        // compositor, so only the GPU pass and — when it actually has world
        // content — the overlay remain.
        display()
        let t1 = CACurrentMediaTime()
        if overlayView.needsDisplay { overlayView.display() }
        let t2 = CACurrentMediaTime()
        if log {
            print(String(format: "[span] canvas=%5.2f overlay=%5.2f total=%5.2f",
                         (t1 - t0) * 1000, (t2 - t1) * 1000, (t2 - t0) * 1000))
        }
    }

    /// 框选矩形：批量标注用强调色，删除用红色——同一个手势，两种后果，
    /// 颜色先告诉用户松手会发生什么。
    private func drawSelectionRect(_ ctx: CGContext) {
        guard let rect = selectionRect, rect.width > 0.5 || rect.height > 0.5 else { return }
        let color = eraseMode ? NSColor.systemRed : Theme.measurementStroke
        ctx.saveGState()
        ctx.setFillColor(color.withAlphaComponent(0.10).cgColor)
        ctx.fill(rect)
        ctx.setStrokeColor(color.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(rect)
        ctx.restoreGState()
    }

    /// 两点选框（窗口缩放 / 打印选区共用）。打印选区用琥珀色：松手之后
    /// 出来的是一张纸，不是一次视角切换，颜色先把这件事说清楚。
    private func drawZoomWindow(_ ctx: CGContext) {
        guard rectPick.armed || rectPick.rect != nil else { return }
        let color = printRegionMode ? Theme.snapMarker : Theme.measurementStroke
        ctx.saveGState()
        if let rect = rectPick.rect, rect.width > 0.5 || rect.height > 0.5 {
            ctx.setFillColor(color.withAlphaComponent(0.08).cgColor)
            ctx.fill(rect)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(rect)
            ctx.setLineDash(phase: 0, lengths: [])
        }
        // 起点已经落下但还没拖出面积时，给一个小十字，表示"等你点第二个点"。
        if rectPick.armed {
            let start = rectPick.startView
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(1.2)
            ctx.move(to: CGPoint(x: start.x - 6, y: start.y))
            ctx.addLine(to: CGPoint(x: start.x + 6, y: start.y))
            ctx.move(to: CGPoint(x: start.x, y: start.y - 6))
            ctx.addLine(to: CGPoint(x: start.x, y: start.y + 6))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private func drawGrid(_ ctx: CGContext) {
        guard transform.scale > 0 else { return }
        var step = 10.0 as CGFloat
        while step * transform.scale < 40 { step *= 10 }
        let world = transform.worldRect(bounds)
        let startX = floor(world.minX / step) * step
        let startY = floor(world.minY / step) * step
        let path = CGMutablePath()
        var x = startX
        while x < world.maxX {
            let vx = transform.toView(CGPoint(x: x, y: 0)).x
            path.move(to: CGPoint(x: vx, y: 0))
            path.addLine(to: CGPoint(x: vx, y: bounds.maxY))
            x += step
        }
        var y = startY
        while y < world.maxY {
            let vy = transform.toView(CGPoint(x: 0, y: y)).y
            path.move(to: CGPoint(x: 0, y: vy))
            path.addLine(to: CGPoint(x: bounds.maxX, y: vy))
            y += step
        }
        ctx.addPath(path)
        ctx.setStrokeColor(Theme.canvasGrid.cgColor)
        ctx.setLineWidth(0.5)
        ctx.strokePath()
    }

    // MARK: Overlays

    /// 取景框（十字光标中心的小方框）的边长。比捕捉方框（10pt）小一圈：
    /// 这两个框同时出现时，外面那个是"会吸到哪儿"，里面那个是"点在哪儿"。
    static let pickBoxSize: CGFloat = 7

    private func drawCrosshair(_ ctx: CGContext) {
        guard settings.showCrosshair, pointerInside, !pointerOverChrome else { return }
        // 与图层版一致：自测可以钉住位置（`crosshairOverride`），实机则跟着
        // 鼠标走。两边用不同的来源会出现"路径 A 拍到了、路径 B 没拍到"的假象。
        let p = crosshairOverride
            ?? convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        guard bounds.contains(p) else { return }
        let half = Self.pickBoxSize / 2
        let crossPath = CGMutablePath()
        crossPath.move(to: CGPoint(x: 0, y: p.y))
        crossPath.addLine(to: CGPoint(x: p.x - half, y: p.y))
        crossPath.move(to: CGPoint(x: p.x + half, y: p.y))
        crossPath.addLine(to: CGPoint(x: bounds.maxX, y: p.y))
        crossPath.move(to: CGPoint(x: p.x, y: 0))
        crossPath.addLine(to: CGPoint(x: p.x, y: p.y - half))
        crossPath.move(to: CGPoint(x: p.x, y: p.y + half))
        crossPath.addLine(to: CGPoint(x: p.x, y: bounds.maxY))
        let boxPath = CGPath(rect: CGRect(x: p.x - half, y: p.y - half,
                                          width: half * 2, height: half * 2),
                             transform: nil)
        ctx.saveGState()
        // 先画一层与画布反相的粗描边，再画主线：压在同色图元上也有轮廓。
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.setStrokeColor(Theme.crosshairHalo.cgColor)
        ctx.setLineWidth(2.5)
        ctx.addPath(crossPath)
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setStrokeColor(Theme.crosshairHalo.cgColor)
        ctx.setLineWidth(2.5)
        ctx.addPath(boxPath)
        ctx.strokePath()
        ctx.setStrokeColor(Theme.crosshair.withAlphaComponent(0.92).cgColor)
        ctx.setLineWidth(0.5)
        // 虚线，且在取景框处断开：十字线穿过中心会让"点落在哪"看不准。
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.addPath(crossPath)
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.addPath(boxPath)
        ctx.strokePath()
        ctx.stroke(CGRect(x: p.x - half, y: p.y - half,
                          width: Self.pickBoxSize, height: Self.pickBoxSize))
        ctx.restoreGState()
    }

    /// The snap indicator has to be readable over dense line work at a glance:
    /// at 9 pt on a hatched wall, a thin outline disappeared and the user could
    /// not tell whether the click would land on the endpoint or a millimetre
    /// away. It is now a filled disc with a 15 pt glyph on top plus the name of
    /// the snap, which is what every CAD package puts next to the cursor.
    private func drawSnapMarker(_ ctx: CGContext) {
        guard let snap = snapResult else { return }
        let p = transform.toView(snap.point)
        let color = Theme.snapMarker
        // 15 → 10：捕捉记号压在图形上，太大会把要瞄的那条线本身遮住。
        let size: CGFloat = 10

        ctx.saveGState()
        // Soft disc first: it separates the glyph from whatever is underneath
        // without hiding the entity the user is aiming at.
        ctx.setFillColor(color.withAlphaComponent(0.16).cgColor)
        let halo = CGRect(x: p.x - size, y: p.y - size, width: size * 2, height: size * 2)
        ctx.fillEllipse(in: halo)

        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(1.5)
        let box = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
        switch snap.kind {
        case .endpoint:
            ctx.stroke(box)
        case .midpoint:
            ctx.move(to: CGPoint(x: p.x, y: p.y - size / 2))
            ctx.addLine(to: CGPoint(x: p.x + size / 2, y: p.y + size / 2))
            ctx.addLine(to: CGPoint(x: p.x - size / 2, y: p.y + size / 2))
            ctx.closePath()
            ctx.fillPath()
        case .center:
            ctx.strokeEllipse(in: box.insetBy(dx: 1, dy: 1))
            ctx.fillEllipse(in: CGRect(x: p.x - 1.3, y: p.y - 1.3, width: 2.6, height: 2.6))
        case .intersection:
            // The X AutoCAD draws for an apparent intersection.
            ctx.move(to: CGPoint(x: p.x - size / 2, y: p.y - size / 2))
            ctx.addLine(to: CGPoint(x: p.x + size / 2, y: p.y + size / 2))
            ctx.move(to: CGPoint(x: p.x + size / 2, y: p.y - size / 2))
            ctx.addLine(to: CGPoint(x: p.x - size / 2, y: p.y + size / 2))
            ctx.strokePath()
        case .perpendicular:
            ctx.move(to: CGPoint(x: p.x - size / 2, y: p.y - size / 2))
            ctx.addLine(to: CGPoint(x: p.x - size / 2, y: p.y + size / 2))
            ctx.addLine(to: CGPoint(x: p.x + size / 2, y: p.y + size / 2))
            ctx.move(to: CGPoint(x: p.x - size / 2, y: p.y + size / 6))
            ctx.addLine(to: CGPoint(x: p.x - size / 6, y: p.y + size / 6))
            ctx.addLine(to: CGPoint(x: p.x - size / 6, y: p.y + size / 2))
            ctx.strokePath()
        case .nearest:
            // AutoCAD 的最近点记号：沙漏形（两个三角对顶）。
            ctx.move(to: CGPoint(x: p.x - size / 2, y: p.y - size / 2))
            ctx.addLine(to: CGPoint(x: p.x + size / 2, y: p.y - size / 2))
            ctx.addLine(to: CGPoint(x: p.x - size / 2, y: p.y + size / 2))
            ctx.addLine(to: CGPoint(x: p.x + size / 2, y: p.y + size / 2))
            ctx.closePath()
            ctx.strokePath()
        case .tangent:
            // 圆 + 一条切线：AutoCAD 的切点记号。
            ctx.strokeEllipse(in: CGRect(x: p.x - size / 2, y: p.y - size / 2,
                                         width: size, height: size))
            ctx.move(to: CGPoint(x: p.x - size / 2 - 2, y: p.y + size / 2 + 2))
            ctx.addLine(to: CGPoint(x: p.x + size / 2 + 2, y: p.y + size / 2 + 2))
            ctx.strokePath()
        }
        ctx.restoreGState()

        // Name of the snap, in a chip so it stays legible on any background.
        // Kept deliberately small: it is a label for the marker, not a badge
        // competing with the drawing under it.
        let caption = NSAttributedString(string: snap.label, attributes: [
            .font: NSFont.systemFont(ofSize: 8, weight: .semibold),
            .foregroundColor: color,
        ])
        let textSize = caption.size()
        let chip = CGRect(x: p.x + size * 0.62, y: p.y - size * 0.62 - textSize.height,
                          width: textSize.width + 6, height: textSize.height + 2)
        ctx.saveGState()
        ctx.setFillColor(Theme.canvasBackground.withAlphaComponent(0.88).cgColor)
        ctx.setStrokeColor(color.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1)
        let chipPath = CGPath(roundedRect: chip, cornerWidth: 3.5, cornerHeight: 3.5,
                              transform: nil)
        ctx.addPath(chipPath)
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()
        caption.draw(at: CGPoint(x: chip.minX + 3.5, y: chip.minY + 1.2))
    }

    private func drawAnnotations(_ ctx: CGContext) {
        guard let document, !annotationsHidden else { return }
        let all = document.annotations.enumerated().filter {
            $0.element.space == space && !$0.element.hidden
        }
        if ProcessInfo.processInfo.environment["CADLENS_ANNOT_LOG"] != nil, !all.isEmpty {
            for (index, item) in all.enumerated() {
                let view = item.element.points.map { transform.toView($0) }
                print("[annot] #\(index) \(item.element.kind) n=\(view.count) "
                      + "view=\(view.map { String(format: "(%.1f,%.1f)", $0.x, $0.y) }.joined(separator: " ")) "
                      + "bounds=\(bounds) hidden=\(item.element.hidden)")
            }
        }

        // 视口裁剪 + 上限。工业图可能带着几万条现场标注；CoreText 每条
        // 都要建一次 glyph 图形，50k 条会把启动从 1 秒拖到一分半。
        // - 先把不在视口内的裁掉（平移缩放后只画看得见的）；
        // - 同一屏超过 800 条时只画前 800 条，选中/悬停的永远保留。
        let margin: CGFloat = 120
        let visible = all.filter { _, annotation in
            guard let first = annotation.points.first else { return false }
            var box = CGRect(origin: transform.toView(first), size: .zero)
            for point in annotation.points.dropFirst() {
                box = box.union(CGRect(origin: transform.toView(point), size: .zero))
            }
            box = box.insetBy(dx: -margin, dy: -margin)
            return box.intersects(bounds)
        }
        let limit = 800
        var display = visible
        if visible.count > limit {
            display = Array(visible.prefix(limit))
            if let selected = selectedAnnotation,
               !display.contains(where: { $0.offset == selected }),
               let item = visible.first(where: { $0.offset == selected }) {
                display.append(item)
            }
            if let hovered = hoveredAnnotation,
               !display.contains(where: { $0.offset == hovered }),
               let item = visible.first(where: { $0.offset == hovered }) {
                display.append(item)
            }
        }
        for (index, annotation) in display {
            let selected = index == selectedAnnotation
            let hovered = index == hoveredAnnotation && !selected
            if hovered { drawHoverPlate(annotation, ctx) }
            // The index bubble is a cross-reference to the dock, not part of
            // the drawing: stamping one on every annotation put a ring of
            // numbered circles over the plan that read as the drawing's own
            // detail callouts. Show it only for the selected measurement.
            AnnotationRenderer.draw(annotation, in: ctx, transform: transform,
                                    document: document, selected: selected,
                                    badge: selected ? index + 1 : nil,
                                    hoverTint: hovered ? hoverTint : nil)
        }
    }

    /// 悬停色：删除模式用红（松手就没了），其余用强调色（可以点选）。
    private var hoverTint: NSColor {
        eraseMode ? NSColor.systemRed : Theme.accent
    }

    /// 悬停反馈：在标注外框铺一层淡色 + 一圈虚线。
    ///
    /// 不做成"把标注本身变成红色"——那会让用户以为标注的颜色被改了。铺一层
    /// 底色是"我选中了这一块"，而不是"这条标注长这样"。
    private func drawHoverPlate(_ annotation: Annotation, _ ctx: CGContext) {
        guard !annotation.points.isEmpty else { return }
        let color = hoverTint
        var box = CGRect.null
        for point in annotation.points {
            let view = transform.toView(point)
            box = box.isNull ? CGRect(x: view.x, y: view.y, width: 0, height: 0)
                : box.union(CGRect(x: view.x, y: view.y, width: 0, height: 0))
        }
        guard !box.isNull else { return }
        box = box.insetBy(dx: -12, dy: -10)
        if box.width < 24 { box = box.insetBy(dx: -(24 - box.width) / 2, dy: 0) }
        if box.height < 20 { box = box.insetBy(dx: 0, dy: -(20 - box.height) / 2) }
        ctx.saveGState()
        ctx.setFillColor(color.withAlphaComponent(0.10).cgColor)
        let path = CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setStrokeColor(color.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// 校准时的实时反馈：与成图同一套尺寸图元（界线 + 尺寸线 + 斜线 + 数值），
    /// 而不是一条虚线。用户在校准里看到的就是它将要写进图里的样子，这才是
    /// "校准也有标注交互"。
    private func drawCalibrationPreview(_ ctx: CGContext) {
        guard calibrationHandler != nil else { return }
        for (index, point) in calibrationPoints.enumerated() {
            let v = transform.toView(point)
            ctx.saveGState()
            ctx.setFillColor(Theme.canvasBackground.withAlphaComponent(0.9).cgColor)
            ctx.fillEllipse(in: CGRect(x: v.x - 4.5, y: v.y - 4.5, width: 9, height: 9))
            ctx.setFillColor(AnnotationRenderer.currentInk.cgColor)
            ctx.fillEllipse(in: CGRect(x: v.x - 2.5, y: v.y - 2.5, width: 5, height: 5))
            ctx.restoreGState()
            if index == 0, calibrationPoints.count == 1 {
                drawChip("基准点", at: v, ctx: ctx)
            }
        }
        guard let first = calibrationPoints.first, let hover = measureHover else { return }
        let a = transform.toView(first), b = transform.toView(hover)
        AnnotationRenderer.previewDistance(tool: .aligned, viewPoints: [a, b], in: ctx)
        let length = MeasurementMath.distance(first, hover)
        if let document {
            drawChip(document.formatLength(Double(length)), at: b, ctx: ctx)
        }
    }

    private func drawMeasurePreview(_ ctx: CGContext) {
        // 批量标注的预览：框选后先按外偏位置画出来，等用户点击/回车确认。
        if !pendingBatch.isEmpty, let document {
            if pendingBatchViewRect.width > 1, pendingBatchViewRect.height > 1 {
                ctx.saveGState()
                ctx.setStrokeColor(AnnotationRenderer.currentInk.withAlphaComponent(0.65).cgColor)
                ctx.setLineWidth(1)
                ctx.setLineDash(phase: 0, lengths: [5, 4])
                ctx.stroke(pendingBatchViewRect)
                ctx.restoreGState()
            }
            for annotation in pendingBatch {
                AnnotationRenderer.draw(annotation, in: ctx, transform: transform,
                                        document: document, selected: false)
            }
            return
        }
        guard let tool = activeTool, tool != .batch, !measurePoints.isEmpty else { return }

        // 第三点阶段：直接用最终标注的渲染器画，所见即所得；尺寸线跟着
        // 光标偏移，用户点哪就放哪。
        if awaitingDimensionLine, let document, measurePoints.count == 2 {
            var preview = Annotation(kind: tool, space: space, points: measurePoints)
            preview.labelOffset = dimensionLineOffset(tool: tool,
                                                      points: measurePoints,
                                                      placement: measureHover)
            preview.text = previewLabel(tool: tool, points: measurePoints)
            AnnotationRenderer.draw(preview, in: ctx, transform: transform,
                                    document: document, selected: false)
            let stroke = AnnotationRenderer.currentInk
            for p in measurePoints {
                let v = transform.toView(p)
                ctx.setFillColor(stroke.cgColor)
                ctx.fillEllipse(in: CGRect(x: v.x - 2.5, y: v.y - 2.5, width: 5, height: 5))
            }
            return
        }

        var points = measurePoints
        if let hover = measureHover { points.append(hover) }
        guard points.count >= 2 else { return }
        let viewPoints = points.map { transform.toView($0) }

        // 对齐/线性距离标注用与成图一致的“压在几何上的尺寸线 + 斜线”预览，
        // 矩形标注画矩形框，其余工具沿用虚线橡皮筋。颜色统一走
        // AnnotationRenderer.currentInk：测量中和落定后必须同色，否则像设置没生效。
        let stroke = AnnotationRenderer.currentInk
        let useDimensionPreview = (tool == .aligned || tool == .linear)
        if tool == .rectangle {
            // 矩形标注量的是"框住的那块面积"，预览就必须是那个框。画一条从
            // 起点到指针的对角线，用户看不出这个框最后会盖住哪里，也看不出
            // 长宽分别是哪两条边。
            let a = viewPoints[0], b = viewPoints[1]
            let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                              width: abs(b.x - a.x), height: abs(b.y - a.y))
            ctx.saveGState()
            ctx.setFillColor(stroke.withAlphaComponent(0.07).cgColor)
            ctx.fill(rect)
            ctx.setStrokeColor(stroke.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1.0)
            ctx.setLineDash(phase: 0, lengths: [5, 3])
            ctx.stroke(rect)
            ctx.restoreGState()
        } else if !useDimensionPreview {
            let path = CGMutablePath()
            path.move(to: viewPoints[0])
            for p in viewPoints.dropFirst() { path.addLine(to: p) }

            ctx.saveGState()
            ctx.setStrokeColor(stroke.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1.0)
            ctx.setLineDash(phase: 0, lengths: [5, 3])
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        } else {
            AnnotationRenderer.previewDistance(tool: tool, viewPoints: viewPoints, in: ctx)
        }

        for p in measurePoints {
            let v = transform.toView(p)
            ctx.setFillColor(stroke.cgColor)
            ctx.fillEllipse(in: CGRect(x: v.x - 2.5, y: v.y - 2.5, width: 5, height: 5))
        }

        let label = previewLabel(tool: tool, points: points)
        if !label.isEmpty, let last = points.last {
            drawChip(label, at: transform.toView(last), ctx: ctx)
        }
    }

    private func previewLabel(tool: MeasureKind, points: [CGPoint]) -> String {
        guard let document else { return "" }
        switch tool {
        case .aligned:
            return document.formatLength(MeasurementMath.distance(points[0], points[1]))
        case .linear:
            let dx = abs(points[1].x - points[0].x)
            let dy = abs(points[1].y - points[0].y)
            return document.formatLength(max(dx, dy))
        case .rectangle:
            let width = abs(points[1].x - points[0].x)
            let height = abs(points[1].y - points[0].y)
            return document.formatArea(width * height)
        case .polygon, .continuous:
            return document.formatLength(MeasurementMath.pathLength(points, closed: false))
        case .radius, .circleArea:
            if points.count >= 3, let circle = MeasurementMath.circleThrough(points[0], points[1], points[2]) {
                return tool == .radius
                    ? "R" + document.formatLength(circle.radius)
                    : document.formatArea(.pi * circle.radius * circle.radius)
            }
            return ""
        case .angle:
            if points.count >= 3 {
                return document.formatAngle(MeasurementMath.angle(points[0], vertex: points[1], points[2]))
            }
            return ""
        case .arcLength:
            if points.count >= 3 {
                return document.formatLength(MeasurementMath.arcLength(points[0], points[1], points[2]))
            }
            return ""
        case .sideArea:
            if points.count >= 2 {
                return document.formatLength(MeasurementMath.pathLength(points, closed: false))
            }
            return ""
        default:
            return ""
        }
    }

    func drawChip(_ text: String, at point: CGPoint, ctx: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let padding = CGSize(width: 7, height: 3.5)
        var rect = CGRect(x: point.x + 14, y: point.y + 10,
                          width: size.width + padding.width * 2,
                          height: size.height + padding.height * 2)
        if rect.maxX > bounds.maxX - 4 { rect.origin.x = point.x - rect.width - 14 }
        if rect.maxY > bounds.maxY - 4 { rect.origin.y = point.y - rect.height - 10 }

        ctx.saveGState()
        let path = CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.addPath(path)
        // 与落定标注、预览线同一个墨色：改颜色时即时生效，不必退出工具。
        ctx.setFillColor(AnnotationRenderer.currentInk.withAlphaComponent(0.92).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        (text as NSString).draw(at: CGPoint(x: rect.minX + padding.width,
                                            y: rect.minY + padding.height),
                                withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Cursor

    /// Invisible cursor used while the drawn crosshair is on. The system
    /// crosshair is a few points wide, so leaving it visible put a small second
    /// cross exactly where the two full-width lines meet — the "why are there
    /// two cursors" that the drawing arm of the crosshair is supposed to
    /// replace.
    static let blankCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in true }
        return NSCursor(image: image, hotSpot: .zero)
    }()

    override func resetCursorRects() {
        if settings.showCrosshair {
            // 自绘十字光标在，系统光标就必须消失：鼠标停在中心时那两个
            // 光标叠在一起，看起来像是"十字中间还有个小箭头"。
            addCursorRect(bounds, cursor: Self.blankCursor)
        } else if activeTool != nil || calibrationHandler != nil || eraseMode {
            addCursorRect(bounds, cursor: .crosshair)
        } else {
            addCursorRect(bounds, cursor: .arrow)
        }
    }

    func prompt(for tool: MeasureKind) -> String {
        switch tool {
        case .aligned, .linear: return "选择起点，再选择终点；Esc 取消"
        case .batch: return "框选线段、圆弧或圆，预览后点击/回车放置（QDIM 式）"
        case .rectangle: return "选择两个对角点"
        case .continuous: return "依次选择节点，回车或双击结束"
        case .polygon: return "依次选择顶点，回到起点自动闭合（回车或双击也可结束）"
        case .radius, .circleArea: return "在圆弧上依次选择三点（反算圆心和半径）"
        case .angle: return "选择第一条边端点、顶点、第二条边端点"
        case .arcLength: return "选择起点、弧上一点、终点"
        case .sideArea: return "依次点取墙面各段端点，回车或右键结束，再输入高度"
        case .hatchArea: return "点击闭合填充区域内部"
        case .note: return "点击放置文字注释"
        }
    }
}

extension CanvasView {
    /// Layer visibility, line weight or theme changed: the sheet is drawn
    /// immediately, so a redraw is all that is needed.
    func invalidateTiles() {
        renderer = document.map { CadRenderer(document: $0) }
        hatchView.invalidate()
        rebuildMetalGeometry()
        needsDisplay = true
    }

    /// 深浅色切换：背景、纸面、图元颜色（ACI 7 按底色反算）三样一起换。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        Theme.refreshAppearance()
        invalidateTiles()
    }

    /// Vector rendering path used by export and printing, independent of the
    /// on-screen tile cache so output resolution is not bounded by the window.
    func drawVector(in ctx: CGContext, targetRect: CGRect, sourceViewRect: CGRect? = nil) {
        guard let document else { return }
        let source = sourceViewRect ?? bounds
        let sx = targetRect.width / max(source.width, 1)
        let sy = targetRect.height / max(source.height, 1)
        let scale = transform.scale
        let origin = CGPoint(x: transform.origin.x + source.minX / transform.scale,
                             y: transform.origin.y + source.minY / transform.scale)

        ctx.saveGState()
        ctx.translateBy(x: targetRect.minX, y: targetRect.minY)
        ctx.scaleBy(x: sx, y: sy)
        ctx.translateBy(x: -source.minX, y: -source.minY)
        ctx.setFillColor(Theme.canvasBackground.cgColor)
        ctx.fill(source)

        let worldRect = CGRect(x: origin.x, y: origin.y,
                               width: source.width / transform.scale,
                               height: source.height / transform.scale)
        ctx.clip(to: source)
        ctx.translateBy(x: -source.minX, y: -source.minY)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -origin.x, y: -origin.y)

        if document.isPDF {
            ctx.saveGState()
            if let vectorPage = document.pdfPage(space) {
                // Keep exported PDFs vector rather than resampling the page.
                let box = document.pdfPageBox(space)
                ctx.clip(to: box)
                vectorPage.draw(with: .mediaBox, to: ctx)
            } else if let page = document.pdfPageImage(space: space, pixelsPerUnit: scale * 2) {
                ctx.interpolationQuality = .high
                ctx.draw(page, in: document.pdfPageBox(space))
            }
            ctx.restoreGState()
        }

        let candidates = document.index(for: space).query(worldRect)
        let renderer = CadRenderer(document: document)
        var options = CadRenderer.Options()
        options.showLineweights = settings.showLineweights
        options.minimumPixels = 0.4
        options.lineWidthScale = transform.scale
        renderer.draw(entities: candidates, space: space, in: ctx,
                      worldRect: worldRect, scale: scale, options: options)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.translateBy(x: targetRect.minX, y: targetRect.minY)
        ctx.scaleBy(x: sx, y: sy)
        ctx.translateBy(x: -source.minX, y: -source.minY)
        for annotation in document.annotations where annotation.space == space && !annotation.hidden {
            AnnotationRenderer.draw(annotation, in: ctx, transform: transform,
                                    document: document, selected: false)
        }
        ctx.restoreGState()
    }

    /// 打印"整张图纸"时的取景范围。
    ///
    /// 模型空间用图元的包围盒：图纸边界（EXTMIN/EXTMAX）常常只框住一部分
    /// 内容，按它打印会漏掉画在外面的详图。布局空间用页框，因为布局的
    /// 意义就是一张定好尺寸的纸。
    func printWorldRect(extents: Bool) -> CGRect {
        guard extents, let document else { return visibleWorldRect }
        if space == 0 {
            let box = document.boundsOfModel
            if box.width > 0, box.height > 0 { return box }
        }
        if let box = document.initialViewBox(for: space), box.width > 0, box.height > 0 {
            return box
        }
        return document.boundsOfModel
    }

    /// 按"世界坐标 → 纸面矩形"出图，给打印用。
    ///
    /// 和 `drawVector` 的区别在比例从哪来：导出/截图要的是"你现在看到的"，
    /// 打印要的是 1:100 这种写死的比例。用相机比例打印，同一张图在两台机器
    /// 上会打出两个尺寸——这是图纸不能接受的。
    ///
    /// `pointsPerWorldUnit` 由调用方按纸张与比例算好，这里只管把世界坐标
    /// 映射上去，并把标注文字按同一比例放大到纸上可读的大小。
    func drawWorld(in ctx: CGContext, worldRect: CGRect, to targetRect: CGRect,
                   pointsPerWorldUnit: CGFloat, showLineweights: Bool? = nil,
                   space renderSpace: Int32? = nil) {
        let space = renderSpace ?? self.space
        guard let document, worldRect.width > 0, worldRect.height > 0,
              pointsPerWorldUnit > 0 else { return }
        measureSheetTextHeight()
        // 标注字号在屏幕上锁在全图比例上，纸上则必须锁在打印比例上。
        let previousFit = AnnotationRenderer.fitScale
        AnnotationRenderer.fitScale = pointsPerWorldUnit
        defer { AnnotationRenderer.fitScale = previousFit }

        ctx.saveGState()
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(targetRect)
        ctx.clip(to: targetRect)
        ctx.translateBy(x: targetRect.minX, y: targetRect.minY)
        ctx.scaleBy(x: pointsPerWorldUnit, y: pointsPerWorldUnit)
        ctx.translateBy(x: -worldRect.minX, y: -worldRect.minY)

        let candidates = document.index(for: space).query(worldRect)
        let renderer = CadRenderer(document: document)
        var options = CadRenderer.Options()
        options.showLineweights = showLineweights ?? settings.showLineweights
        options.minimumPixels = 0.35
        options.lineWidthScale = pointsPerWorldUnit
        renderer.draw(entities: candidates, space: space, in: ctx,
                      worldRect: worldRect, scale: pointsPerWorldUnit, options: options)

        let printTransform = ViewTransform(origin: worldRect.origin,
                                           scale: pointsPerWorldUnit)
        for annotation in document.annotations
        where annotation.space == space && !annotation.hidden {
            AnnotationRenderer.draw(annotation, in: ctx, transform: printTransform,
                                    document: document, selected: false)
        }
        ctx.restoreGState()
    }

    /// Offscreen render of the GPU pass. Scripted captures use it because a
    /// CAMetalLayer cannot be read back through the window server.
    func metalSnapshot(pixelScale: CGFloat) -> CGImage? {
        guard usesMetal, let renderer = metalView.renderer else { return nil }
        return renderer.snapshot(viewSize: bounds.size, transform: transform,
                                 pixelScale: pixelScale)
    }

    func vectorImage(pixelWidth: Int, pixelHeight: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ??
                                      CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }
        let ratio = CGFloat(pixelWidth) / max(bounds.width, 1)
        ctx.scaleBy(x: ratio, y: CGFloat(pixelHeight) / max(bounds.height, 1))
        drawVector(in: ctx, targetRect: bounds)
        return ctx.makeImage()
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let canRead = sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return canRead ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL],
              let url = urls.first else { return false }
        (NSApp.delegate as? AppDelegate)?.open(url: url)
        return true
    }
}


extension CanvasView {
    /// 换主题：底图与 Metal 缓冲里都烘着颜色，必须整块重建。
    func themeDidChange() {
        invalidateSheet()
        rebuildMetalGeometry()
        needsDisplay = true
    }
}
