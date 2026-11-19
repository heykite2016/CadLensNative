import AppKit

extension CanvasView {
    // MARK: Events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeInKeyWindow, .inVisibleRect,
                                            .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func cursorUpdate(with event: NSEvent) {
        // 平移时手形光标是唯一该露面的系统光标；其余情况只要自绘十字光标
        // 开着，就把系统光标藏掉——否则工具激活后中心会多出一个细十字。
        if panMode {
            NSCursor.openHand.set()
        } else if settings.showCrosshair {
            Self.blankCursor.set()
        } else if zoomWindowMode || printRegionMode || activeTool != nil {
            NSCursor.crosshair.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        updateCrosshair()
        // The crosshair is a compositor layer, so entering the canvas does not
        // need the overlay's backing store re-uploaded.
        needsDisplayForCameraMove()
    }

    override func mouseMoved(with event: NSEvent) {
        pointerInside = true
        updateCrosshair()
        let viewPoint = convert(event.locationInWindow, from: nil)
        lastCanvasPointer = viewPoint
        let world = transform.toWorld(viewPoint)
        onCursorMoved?(world)
        if calibrationHandler != nil {
            // 校准和测量走同一条捕捉链路。少了这一支，校准时光标既不吸附也
            // 不画捕捉标记，量比例只能靠眼睛猜端点——这正是"校准没有对象
            // 捕捉"的来源：点击时其实调了 constrained，但鼠标移动时从不求
            // 解捕捉，用户全程看不到任何吸附反馈。
            updateCalibrationHover(world)
            needsDisplay = true
        } else if zoomWindowMode || printRegionMode {
            // 选框也要吸附：不吸附就只能靠眼睛对齐图框边线。
            measureHover = settings.objectSnap ? constrained(world) : nil
            if rectPick.armed {
                updateRectPick(to: viewPoint)
            }
            needsDisplay = true
        } else if activeTool != nil {
            // 第三点是在放尺寸线，不是在图上取点：必须跟鼠标像素同步。
            // 这里再走 object snap 会把尺寸线吸到附近的墙端点上，松手后
            // 标注突然跳开——这是"尺寸线和鼠标不同步"的直接原因。
            if awaitingDimensionLine {
                measureHover = world
                snapResult = nil
            } else {
                measureHover = constrained(world)
            }
            needsDisplay = true
        } else if !measurePoints.isEmpty {
            measureHover = constrained(world)
            needsDisplay = true
        } else {
            // 空闲或删除模式：指针压在哪条标注上就说清楚是哪条。删除是一次
            // 不可挽回的动作，选择是点一下就要出结果的动作，两者都需要在按下
            // 之前看到"我现在指着的就是这个"。
            updateAnnotationHover(at: world)
            needsDisplayForCameraMove()
        }
    }

    /// 指针下的标注。只在"没有工具在手"和删除模式下求解：量长度时指针
    /// 压到别的标注上不该亮，那会和捕捉标记抢注意力。
    func updateAnnotationHover(at world: CGPoint) {
        guard !annotationsHidden, activeTool == nil, calibrationHandler == nil,
              !panMode, !zoomWindowMode, !printRegionMode, !isPanning else {
            hoveredAnnotation = nil
            return
        }
        hoveredAnnotation = annotationIndex(at: world, tolerance: 8 / transform.scale)
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        // 打开设置面板/点侧栏颜色时指针会离开画布。多点工具已经落下的点仍要
        // 显示橡皮筋预览，并保留最后的吸附位置；否则改完颜色、单位回画布前
        // 看起来像"设置没生效"，要再点一下才出现。
        if activeTool == nil && calibrationHandler == nil {
            measureHover = nil
            snapResult = nil
        }
        hoveredAnnotation = nil
        updateCrosshair()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)
        let world = transform.toWorld(viewPoint)

        // 批量标注的预览阶段：任意点击就是“确认放置”。
        if !pendingBatch.isEmpty {
            commitPendingBatch()
            return
        }

        // 删除工具：点在标注上即删，点在空白处则拉框。
        if eraseMode {
            if let index = annotationIndex(at: world, tolerance: 8 / transform.scale) {
                // 删完就退出：删除是一次动作，留着模式只会让下一次点击误删。
                deleteAnnotation(at: index)
                eraseMode = false
            } else {
                selectionAnchor = viewPoint
                selectionRect = CGRect(origin: viewPoint, size: .zero)
            }
            return
        }

        if calibrationHandler != nil {
            beginPick(at: viewPoint)
            return
        }

        if zoomWindowMode {
            beginRectPick(at: viewPoint)
            return
        }

        if printRegionMode {
            beginRectPick(at: viewPoint)
            return
        }

        if panMode || event.modifierFlags.contains(.option) || event.buttonNumber == 2 {
            beginPan(at: viewPoint)
            return
        }

        // 批量标注是"快速标注"：拉一个框，框内的线段/圆弧全部自动出尺寸，
        // 不需要一段一段去点端点。
        if activeTool == .batch {
            selectionAnchor = viewPoint
            selectionRect = CGRect(origin: viewPoint, size: .zero)
            return
        }

        if activeTool != nil {
            beginPick(at: viewPoint)
            return
        }

        if event.clickCount >= 2,
           let index = annotationIndex(at: world, tolerance: 8 / transform.scale) {
            selectedAnnotation = index
            editAnnotationText(at: index)
            return
        }

        if let index = annotationIndex(at: world, tolerance: 8 / transform.scale) {
            selectedAnnotation = index
            onSelectionChanged?(document?.annotations[index])
            let annotation = document?.annotations[index]
            if let annotation, labelHit(annotation, at: world) {
                draggingLabel = true
                labelDragStart = world
                labelDragOriginOffset = annotation.labelOffset
            } else {
                beginPan(at: viewPoint)
            }
            needsDisplay = true
            return
        }

        if selectedAnnotation != nil {
            selectedAnnotation = nil
            onSelectionChanged?(nil)
            needsDisplay = true
        }
        beginPan(at: viewPoint)
    }

    /// Right click is "finish" in every drafting application: it ends an
    /// in-progress multi-point measurement, and with nothing in progress it
    /// opens the drawing's context menu.
    override func rightMouseDown(with event: NSEvent) {
        pendingPickView = nil
        if calibrationHandler != nil {
            calibrationHandler = nil
            calibrationPoints.removeAll()
            onPromptChanged?("已取消比例校准")
            needsDisplay = true
            return
        }
        if !pendingBatch.isEmpty {
            commitPendingBatch()
            return
        }
        if awaitingDimensionLine {
            finishMeasurement(placement: measureHover)
            return
        }
        if activeTool != nil || !measurePoints.isEmpty {
            if measurePoints.count >= 2 || activeTool?.requiredPoints == Int.max {
                finishMeasurement()
            } else {
                cancelMeasurement()
            }
            return
        }
        showContextMenu(at: convert(event.locationInWindow, from: nil))
    }

    private func showContextMenu(at point: CGPoint) {
        let menu = NSMenu()
        let fit = NSMenuItem(title: "显示全图", action: #selector(contextFit), keyEquivalent: "")
        fit.target = self
        menu.addItem(fit)
        let previous = NSMenuItem(title: "上一个视图", action: #selector(contextPrevious),
                                  keyEquivalent: "")
        previous.target = self
        menu.addItem(previous)
        menu.addItem(.separator())
        let snapItem = NSMenuItem(title: settings.objectSnap ? "关闭对象捕捉" : "开启对象捕捉",
                                  action: #selector(contextToggleSnap), keyEquivalent: "")
        snapItem.target = self
        menu.addItem(snapItem)
        if selectedAnnotation != nil {
            menu.addItem(.separator())
            let edit = NSMenuItem(title: "编辑标注文字…", action: #selector(contextEdit),
                                  keyEquivalent: "")
            edit.target = self
            menu.addItem(edit)
            let remove = NSMenuItem(title: "删除标注", action: #selector(contextDelete),
                                    keyEquivalent: "")
            remove.target = self
            menu.addItem(remove)
        }
        menu.popUp(positioning: nil, at: point, in: self)
    }

    @objc private func contextFit() { zoomToExtents(animated: true) }
    @objc private func contextPrevious() { zoomPrevious() }
    @objc private func contextToggleSnap() {
        settings.objectSnap.toggle()
        settings.save()
    }
    @objc private func contextEdit() {
        if let index = selectedAnnotation { editAnnotationText(at: index) }
    }
    @objc private func contextDelete() { deleteSelection() }

    /// Dimension text override: what "editing a dimension" means in CAD — the
    /// measurement is kept, only the displayed string changes.
    private func editAnnotationText(at index: Int) {
        guard let document, index < document.annotations.count else { return }
        let annotation = document.annotations[index]
        let alert = NSAlert()
        alert.messageText = "修改标注文字"
        alert.informativeText = "实测值 " + annotation.text + "。留空恢复实测值。"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "加备注…")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = annotation.labelOverride ?? ""
        field.placeholderString = annotation.text
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        if response == .alertThirdButtonReturn {
            promptForNote(at: index)
            return
        }
        guard response == .alertFirstButtonReturn else { return }
        document.annotations[index].labelOverride = field.stringValue.isEmpty
            ? nil : field.stringValue
        commitAnnotationChange()
    }

    private func promptForNote(at index: Int) {
        guard let document, index < document.annotations.count else { return }
        let alert = NSAlert()
        alert.messageText = "备注"
        alert.informativeText = "备注随标注保存，不显示在图上。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = document.annotations[index].note ?? ""
        field.placeholderString = "例如：客厅地面，需现场复核"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        document.annotations[index].note = field.stringValue.isEmpty ? nil : field.stringValue
        commitAnnotationChange()
    }

    private func beginPan(at viewPoint: CGPoint) {
        isPanning = true
        panStartView = viewPoint
        panStartOrigin = transform.origin
        NSCursor.closedHand.push()
    }

    /// With a tool armed, pressing the canvas is ambiguous: it is either a pick
    /// or the start of a pan. Resolving it on mouse-down means one of the two
    /// gestures is impossible — a viewer that turns every press into a point
    /// leaves the user unable to drag the sheet while measuring, which is
    /// exactly how you line a dimension up on a detail that is off-screen.
    /// So the press is only *remembered*; if the pointer travels past the drag
    /// threshold the pick is thrown away and the gesture becomes a pan, and if
    /// it does not, the point is committed on mouse-up.
    private func beginPick(at viewPoint: CGPoint) {
        pendingPickView = viewPoint
    }

    // MARK: 两点选区（窗口缩放 / 打印选区）

    /// 按下的那一点，吸附过再落。捕捉在这里必须走同一条 constrained()：
    /// 打印选区要正好套住图框，差 2mm 纸上就是一道白边。
    private func snappedWorldPoint(_ viewPoint: CGPoint) -> CGPoint {
        let world = transform.toWorld(viewPoint)
        guard settings.objectSnap else { return world }
        return constrained(world)
    }

    private func beginRectPick(at viewPoint: CGPoint) {
        let world = snappedWorldPoint(viewPoint)
        if rectPick.armed {
            // 第二次点击：起点已在，这里就是终点。
            finishRectPick(at: world)
            return
        }
        rectPick.armed = true
        rectPick.startView = viewPoint
        rectPick.startWorld = world
        rectPick.currentWorld = world
        rectPick.rect = CGRect(origin: viewPoint, size: .zero)
        needsDisplay = true
    }

    private func updateRectPick(to viewPoint: CGPoint) {
        guard rectPick.armed else { return }
        let world = snappedWorldPoint(viewPoint)
        rectPick.currentWorld = world
        let current = transform.toView(world)
        rectPick.rect = CGRect(x: min(rectPick.startView.x, current.x),
                               y: min(rectPick.startView.y, current.y),
                               width: abs(current.x - rectPick.startView.x),
                               height: abs(current.y - rectPick.startView.y))
    }

    /// 松手（或第二次点击）时的收尾。
    ///
    /// 拖出矩形就直接用；只是点了一下（没有拖拽）就留着状态等第二个点——
    /// 这正好对上"对角线两个端点"的操作习惯。
    private func finishRectPick(at world: CGPoint? = nil) {
        guard rectPick.armed else { return }
        let dragged = (rectPick.rect?.width ?? 0) > 4 || (rectPick.rect?.height ?? 0) > 4
        // 单击（没拖动）且不是第二次点击：继续等终点。
        guard world != nil || dragged else { return }
        let start = rectPick.startWorld
        let end = world ?? rectPick.currentWorld
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        guard rect.width > 0.5, rect.height > 0.5 else { return }
        rectPick = RectPick()
        needsDisplay = true
        if printRegionMode {
            printRegionMode = false
            onPrintRegionPicked?(rect, space)
        } else if zoomWindowMode {
            zoomWindowMode = false
            pushViewHistory()
            zoom(toWorldRect: rect)
        }
    }

    /// Ends a remembered press. Returns the view point to pick, or nil when the
    /// gesture turned into a pan (or was cancelled).
    private func finishPick() -> CGPoint? {
        defer { pendingPickView = nil }
        return pendingPickView
    }

    override func mouseDragged(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)

        if selectionRect != nil {
            selectionRect = CGRect(x: min(selectionAnchor.x, viewPoint.x),
                                   y: min(selectionAnchor.y, viewPoint.y),
                                   width: abs(viewPoint.x - selectionAnchor.x),
                                   height: abs(viewPoint.y - selectionAnchor.y))
            needsDisplay = true
            return
        }

        if rectPick.rect != nil {
            updateRectPick(to: viewPoint)
            needsDisplay = true
            return
        }

        if draggingLabel, let index = selectedAnnotation,
           let document = document, index < document.annotations.count {
            let world = transform.toWorld(viewPoint)
            // labelOffset 是屏幕像素（renderer 把它加到 view 坐标上），
            // 拖动量的世界坐标必须先乘当前 scale，否则模型空间会放大几千倍。
            document.annotations[index].labelOffset = CGPoint(
                x: labelDragOriginOffset.x + (world.x - labelDragStart.x) * transform.scale,
                y: labelDragOriginOffset.y + (world.y - labelDragStart.y) * transform.scale)
            needsDisplay = true
            return
        }

        // A press that has travelled further than this is a drag of the sheet,
        // not a pick. 4 pt is the same threshold AppKit uses to tell a click
        // from a drag; below it a shaky hand still lands the point.
        if let start = pendingPickView {
            guard hypot(viewPoint.x - start.x, viewPoint.y - start.y) > 4 else { return }
            pendingPickView = nil
            panDidStartFromPick = true
            beginPan(at: start)
        }

        if isPanning {
            let dx = viewPoint.x - panStartView.x
            let dy = viewPoint.y - panStartView.y
            transform.origin = CGPoint(x: panStartOrigin.x - dx / transform.scale,
                                       y: panStartOrigin.y - dy / transform.scale)
            hatchView.transform = transform
            // Keep the fill layer in its "gesture" mode: it follows the camera
            // by moving the cached raster, and only re-rasterises once the drag
            // stops. Without this a pan past the cached margin would rebuild
            // every hatch in the middle of the gesture.
            beginInteraction()
            updateCrosshair()
            // The rubber band is anchored in world space, so it has to be
            // re-solved against the *new* camera while the sheet slides under
            // a stationary pointer — otherwise the preview trails behind the
            // cursor for the whole gesture.
            if calibrationHandler != nil {
                updateCalibrationHover(transform.toWorld(viewPoint))
            } else if activeTool != nil {
                measureHover = constrained(transform.toWorld(viewPoint))
            }
            // Panning moves the paper, the grid and the drawing on layers that
            // follow the camera on the GPU. Only the canvas and the crosshair
            // layers change, so the overlay is left untouched unless it owns
            // world-space content of its own.
            needsDisplayForCameraMove()
        }
    }

    override func mouseUp(with event: NSEvent) {
        if zoomWindowMode || printRegionMode {
            finishRectPick()
            return
        }
        if let rect = selectionRect {
            selectionRect = nil
            needsDisplay = true
            if eraseMode {
                if rect.width > 3 || rect.height > 3, deleteAnnotations(in: rect) {
                    eraseMode = false
                }
            } else if activeTool == .batch, rect.width > 3, rect.height > 3 {
                commitBatchSelection(in: rect)
            }
            return
        }

        // The press never became a drag: it is a pick, and it is placed with the
        // snap solved against the camera as it stands now.
        if let pick = finishPick() {
            let world = transform.toWorld(pick)
            if calibrationHandler != nil {
                handleCalibrationClick(world)
            } else if let tool = activeTool {
                handleToolClick(tool: tool, world: world, event: event)
            }
        }
        if draggingLabel {
            draggingLabel = false
            commitAnnotationChange()
        }
        if isPanning {
            isPanning = false
            panDidStartFromPick = false
            NSCursor.pop()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY * 0.006
            : event.scrollingDeltaY * 0.06
        guard abs(delta) > 0.0001 else { return }
        let anchor = convert(event.locationInWindow, from: nil)
        zoom(by: exp(delta), anchor: anchor)
        onCursorMoved?(transform.toWorld(anchor))
    }

    override func magnify(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil)
        zoom(by: 1 + event.magnification, anchor: anchor)
    }

    override func keyDown(with event: NSEvent) {
        // Tab：在孔径内的多个捕捉点之间循环（AutoCAD 的同类操作）。密集
        // 图里端点只差几像素时，默认“最近/优先级”不一定是你想吸的那个。
        if event.keyCode == 48, !snapOptions.isEmpty,
           activeTool != nil || calibrationHandler != nil {
            guard snapOptions.count > 1 else { return }
            snapOptionIndex = (snapOptionIndex + 1) % snapOptions.count
            let snap = snapOptions[snapOptionIndex]
            snapResult = snap
            measureHover = snap.point
            onPromptChanged?("捕捉：\(snap.label)（Tab 切换 \(snapOptionIndex + 1)/\(snapOptions.count)）")
            needsDisplay = true
            updateCrosshair()
            return
        }
        switch event.keyCode {
        case 53:  // esc
            if printRegionMode {
                printRegionMode = false
                needsDisplay = true
                onPromptChanged?("已取消打印选区")
                return
            }
            if zoomWindowMode {
                zoomWindowMode = false
                needsDisplay = true
                onPromptChanged?("已退出窗口缩放")
                return
            }
            if eraseMode {
                eraseMode = false
                needsDisplay = true
                onPromptChanged?("已退出删除")
                return
            }
            // CAD 的 Esc 只有一个含义：取消当前命令。多点工具点到一半按
            // Esc 也是“不要了”，不是“帮我落一条”。回车/右键才是结束。
            if !pendingBatch.isEmpty {
                pendingBatch.removeAll()
                pendingBatchViewRect = .zero
                activeTool = nil
                onPromptChanged?("已取消快速标注")
                needsDisplay = true
                return
            }
            cancelMeasurement()
        case 36, 76:  // return / enter
            if !pendingBatch.isEmpty {
                commitPendingBatch()
            } else if awaitingDimensionLine {
                finishMeasurement(placement: measureHover)
            } else if activeTool != nil || !measurePoints.isEmpty {
                finishMeasurement()
            } else {
                onRepeatLastTool?()
            }
        case 49:  // space：CAD 里等同回车；空命令时重复上一个工具
            if !pendingBatch.isEmpty {
                commitPendingBatch()
            } else if awaitingDimensionLine {
                finishMeasurement(placement: measureHover)
            } else if activeTool != nil || !measurePoints.isEmpty {
                finishMeasurement()
            } else {
                onRepeatLastTool?()
            }
        case 51, 117:  // delete
            deleteSelection()
        default:
            break
        }
        switch event.charactersIgnoringModifiers {
        case "0":
            zoomToExtents(animated: true)
        case "+", "=":
            zoom(by: 1.25)
        case "-", "_":
            zoom(by: 0.8)
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Measurement commit

    func handleToolClick(tool: MeasureKind, world: CGPoint, event: NSEvent) {
        // 第三点：尺寸线位置。这是 DIMALIGNED/DIMLINEAR 和两点量距最直观的
        // 区别——尺寸线跟着光标走，用户自己决定放哪，而不是自动压在墙上。
        // 放置阶段用原始鼠标点，不吸附：吸附只属于被测量的几何点。
        if awaitingDimensionLine {
            awaitingDimensionLine = false
            finishMeasurement(placement: world)
            return
        }

        let point = constrained(world)

        if tool == .hatchArea {
            commitHatchArea(at: world)
            return
        }

        if tool == .note {
            promptForNote(at: point)
            return
        }

        // 多边形回到起点即闭合：这是 AutoCAD 面积命令的收尾动作，不用再按
        // 回车或双击。判定用捕捉孔径，所以吸附到首点时是零误差命中。
        if tool == .polygon, measurePoints.count >= 3,
           let first = measurePoints.first,
           MeasurementMath.distance(point, first) <= Self.snapAperture / transform.scale {
            measurePoints.append(first)
            measureHover = nil
            finishMeasurement()
            return
        }

        measurePoints.append(point)
        measureHover = point
        needsDisplay = true

        // 对齐/线性：第二点之后不急着落标注，先进入“放置尺寸线”阶段。
        if (tool == .aligned || tool == .linear), measurePoints.count == 2 {
            awaitingDimensionLine = true
            onPromptChanged?("移动光标确定尺寸线位置，点击放置 · 回车默认位置 · Esc 取消")
            return
        }

        let required = tool.requiredPoints
        let complete: Bool
        if required == Int.max {
            complete = event.clickCount >= 2 && measurePoints.count >= 2
        } else {
            complete = measurePoints.count >= required
        }
        if complete { finishMeasurement() }
    }

    func finishMeasurement(placement: CGPoint? = nil) {
        guard let tool = activeTool, let document else {
            measurePoints.removeAll()
            return
        }
        defer {
            measurePoints.removeAll()
            measureHover = nil
            awaitingDimensionLine = false
            needsDisplay = true
            onPromptChanged?(activeTool.map { prompt(for: $0) } ?? "")
        }
        guard measurePoints.count >= 2 else { return }

        if tool == .sideArea {
            promptForHeight()
            return
        }

        // 批量测量是「连续做多段两点距离」：每两点落一条对齐标注，工具保持
        // 激活；现在改为框选→预览→点击/回车放置，Esc 取消。
        let effectiveKind: MeasureKind = tool == .batch ? .aligned : tool
        var annotation = Annotation(kind: effectiveKind, space: space, points: measurePoints)
        switch tool {
        case .aligned, .batch:
            annotation.value = MeasurementMath.distance(measurePoints[0], measurePoints[1])
        case .linear:
            annotation.value = max(abs(measurePoints[1].x - measurePoints[0].x),
                                   abs(measurePoints[1].y - measurePoints[0].y))
        case .continuous:
            let (path, lengths) = densify(measurePoints, closed: false, document: document)
            annotation.path = path
            annotation.segmentLengths = lengths
            annotation.value = lengths.reduce(0, +)
        case .rectangle:
            let rect = CGRect(x: min(measurePoints[0].x, measurePoints[1].x),
                              y: min(measurePoints[0].y, measurePoints[1].y),
                              width: abs(measurePoints[1].x - measurePoints[0].x),
                              height: abs(measurePoints[1].y - measurePoints[0].y))
            annotation.points = [CGPoint(x: rect.minX, y: rect.minY),
                                 CGPoint(x: rect.maxX, y: rect.minY),
                                 CGPoint(x: rect.maxX, y: rect.maxY),
                                 CGPoint(x: rect.minX, y: rect.maxY)]
            annotation.value = rect.width * rect.height
            annotation.secondaryValue = rect.width
            annotation.perimeter = Double(2 * (rect.width + rect.height))
        case .polygon:
            let (path, lengths) = densify(measurePoints, closed: true, document: document)
            annotation.path = path
            annotation.segmentLengths = lengths
            annotation.value = MeasurementMath.polygonArea(path.count >= 3 ? path : measurePoints)
            annotation.secondaryValue = lengths.reduce(0, +)
            annotation.perimeter = annotation.secondaryValue
        case .radius, .circleArea:
            guard measurePoints.count >= 3,
                  let circle = MeasurementMath.circleThrough(measurePoints[0], measurePoints[1],
                                                             measurePoints[2]) else { return }
            annotation.value = tool == .radius
                ? circle.radius
                : .pi * circle.radius * circle.radius
            annotation.secondaryValue = circle.radius
            // 圆的周长只对面积标注有意义；半径标注上印 "C = ..." 是噪声。
            annotation.perimeter = tool == .radius ? 0 : Double(2 * .pi * circle.radius)
            annotation.points = [circle.center] + measurePoints
        case .angle:
            guard measurePoints.count >= 3 else { return }
            annotation.value = MeasurementMath.angle(measurePoints[0], vertex: measurePoints[1],
                                                     measurePoints[2])
            annotation.angle = Double(annotation.value)
        case .arcLength:
            guard measurePoints.count >= 3 else { return }
            annotation.value = MeasurementMath.arcLength(measurePoints[0], measurePoints[1],
                                                          measurePoints[2])
        default:
            break
        }
        // 对齐/线性：把第三点/默认位置换算成 renderer 用的 labelOffset。
        if tool == .aligned || tool == .linear {
            annotation.labelOffset = dimensionLineOffset(tool: tool,
                                                          points: measurePoints,
                                                          placement: placement)
        }
        annotation.text = describe(annotation, document: document)
        add(annotation)
        // 标注画完就退出工具：连续/多边形这类多点工具也走这里（回车、双击、
        // 回到起点闭合都算"画完了"），下一条要重新选工具。
        finishToolAfterCommit()
    }

    /// 尺寸线相对两点连线的偏移。alignment 用法向投影；linear 用水平/竖直
    /// 方向的投影。没有第三点（回车）或第三点贴着几何线时给一个屏幕上的
    /// 默认外偏，保证不会压回墙线。
    func dimensionLineOffset(tool: MeasureKind, points: [CGPoint],
                                     placement: CGPoint?) -> CGPoint {
        guard points.count >= 2 else { return .zero }
        let a = points[0], b = points[1]
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let scale = max(transform.scale, 1e-9)
        let fallback: CGFloat = 30

        // 把“鼠标到几何线的屏幕距离”限制在可读范围内：
        // 太近会和墙线/数字叠在一起，太远会飞出图面。范围内严格跟随鼠标。
        func bounded(_ screen: CGFloat) -> CGFloat {
            let sign: CGFloat = screen < 0 ? -1 : 1
            return sign * min(max(abs(screen), 14), 180)
        }

        if tool == .linear {
            if abs(b.x - a.x) >= abs(b.y - a.y) {
                let dy = placement.map { ($0.y - mid.y) * scale } ?? fallback
                return CGPoint(x: 0, y: bounded(dy))
            }
            let dx = placement.map { ($0.x - mid.x) * scale } ?? fallback
            return CGPoint(x: bounded(dx), y: 0)
        }
        var nx = -(b.y - a.y), ny = b.x - a.x
        let length = max(hypot(nx, ny), 1e-9)
        nx /= length; ny /= length
        let worldOffset = placement.map {
            ($0.x - mid.x) * nx + ($0.y - mid.y) * ny
        }
        // placement 是用户点下的位置；范围内原样跟随，不做“离墙太近就弹到
        // 30px 外”的突跳。世界偏移先乘 scale 变成屏幕像素，再做上下限。
        let screenOffset = bounded((worldOffset ?? fallback) * (placement == nil ? 1 : scale))
        return CGPoint(x: nx * screenOffset, y: ny * screenOffset)
    }

    func cancelMeasurement() {
        awaitingDimensionLine = false
        if !measurePoints.isEmpty {
            measurePoints.removeAll()
            measureHover = nil
            needsDisplay = true
            onPromptChanged?(activeTool.map { prompt(for: $0) } ?? "")
        } else {
            activeTool = nil
        }
    }

    private func promptForHeight() {
        guard let document, measurePoints.count >= 2 else { return }
        // 侧面积的长度是这一串点连起来的长度，不是首末两点的直线距离——三段
        // 折起来的一面墙，用直线距离会少算一个转角。
        let (wallPath, wallLengths) = densify(measurePoints, closed: false, document: document)
        let length = wallLengths.reduce(0) { $0 + CGFloat($1) }
        let alert = NSAlert()
        alert.messageText = "输入侧面积高度"
        alert.informativeText = "当前线段长度 " + document.formatLength(length, unit: true)
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "高度（\(document.displayUnit.suffix)）"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let heightInUnit = Double(field.stringValue), heightInUnit > 0 else { return }
        let heightInDrawing = heightInUnit * document.displayUnit.metersPerUnit
            / document.unitMeters
        var annotation = Annotation(kind: .sideArea, space: space, points: measurePoints)
        annotation.path = wallPath
        annotation.segmentLengths = wallLengths
        annotation.value = length * heightInDrawing
        annotation.secondaryValue = length
        annotation.angle = heightInDrawing
        annotation.text = "S侧 = " + document.formatArea(annotation.value)
        // 长 × 高 的过程放备注里：图上只留结果，复核时点开标注就能看到算式。
        annotation.note = document.formatLength(length) + " × "
            + document.formatLength(heightInDrawing)
        add(annotation)
        measurePoints.removeAll()
        needsDisplay = true
        finishToolAfterCommit()
    }

    private func promptForNote(at point: CGPoint) {
        let alert = NSAlert()
        alert.messageText = "添加注释"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "输入文字"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              !field.stringValue.isEmpty else { return }
        var annotation = Annotation(kind: .note, space: space, points: [point])
        annotation.text = field.stringValue
        add(annotation)
        measurePoints.removeAll()
        needsDisplay = true
        finishToolAfterCommit()
    }

    private func commitHatchArea(at world: CGPoint) {
        guard let document else { return }
        let tolerance = 4 / transform.scale
        let candidates = document.index(for: space).query(
            CGRect(x: world.x - tolerance, y: world.y - tolerance,
                   width: tolerance * 2, height: tolerance * 2))
        for index in candidates {
            let entity = document.entities[Int(index)]
            guard entity.kind == .hatch, document.isLayerVisible(entity),
                  let hatch = document.hatch(for: entity), !hatch.rings.isEmpty else { continue }
            let path = CGMutablePath()
            for ring in hatch.rings {
                let start = Int(ring.pstart)
                let end = min(start + Int(ring.pcount), document.points.count)
                guard start < end else { continue }
                path.move(to: document.points[start])
                for i in (start + 1)..<end { path.addLine(to: document.points[i]) }
                path.closeSubpath()
            }
            guard path.contains(world, using: .evenOdd) else { continue }
            let box = path.boundingBoxOfPath
            var annotation = Annotation(kind: .hatchArea, space: space,
                                        points: [CGPoint(x: box.minX, y: box.minY),
                                                 CGPoint(x: box.maxX, y: box.minY),
                                                 CGPoint(x: box.maxX, y: box.maxY),
                                                 CGPoint(x: box.minX, y: box.maxY)])
            var rings: [[CGPoint]] = []
            var outline: CGFloat = 0
            // 净面积按环的嵌套深度算：外环加、洞减、洞里的岛再加。不能直接
            // 累加绝对值，否则带柱洞的房间会把洞的面积也算进去。
            // 周长仍走所有环：柱边也是要收口的边界。
            for ring in hatch.rings {
                let start = Int(ring.pstart)
                let end = min(start + Int(ring.pcount), document.points.count)
                guard start < end else { continue }
                let ringPoints = Array(document.points[start..<end])
                rings.append(ringPoints)
                outline += MeasurementMath.pathLength(ringPoints, closed: true)
            }
            annotation.value = MeasurementMath.netArea(rings: rings)
            annotation.perimeter = Double(outline)
            // 填充测量没有拾取点可言，文字得在这里生成：`finishMeasurement`
            // 那句 describe 走不到这一支，之前填充量完图上一个字都没有。
            annotation.text = describe(annotation, document: document)
            add(annotation)
            finishToolAfterCommit()
            return
        }
        NSSound.beep()
        onPromptChanged?("此处没有闭合填充区域")
    }

    private func describe(_ annotation: Annotation, document: CadDocument) -> String {
        switch annotation.kind {
        case .aligned, .linear, .continuous, .batch, .arcLength:
            return document.formatLength(annotation.value)
        case .radius:
            // GB/T 50001 11.4.1：半径数字前加 R，不能写 R=；直径用 φ。
            return "R" + document.formatLength(annotation.value)
        case .circleArea, .rectangle, .polygon, .hatchArea:
            // 面积统一写作 "S = 12.34m²"：图纸上的面积就该带上符号，否则一
            // 排数字里分不清哪个是长、哪个是面。周长另起一行用 "C =" 标在
            // 下面——同一个区域的两个量，写成一行读起来像一道乘法算式。
            let area = "S = " + document.formatArea(annotation.value)
            let outline = Self.perimeter(of: annotation)
            guard outline > 0 else { return area }
            return area + "\nC = " + document.formatLength(outline, unit: true)
        case .sideArea:
            return "S侧 = " + document.formatArea(annotation.value)
        case .angle:
            return String(format: "%.1f°", annotation.value * 180 / .pi)
        case .note:
            return annotation.text
        }
    }

    /// 把拾取点展开成"沿弧走"的路径，并给出每两个拾取点之间的真实长度。
    ///
    /// 只对多点工具（连续、多边形、侧面积）有意义：单段尺寸本来就该是一根直
    /// 线，弧长有专门的弧长工具。展开后 points 保持原样（编辑、命中判定还按
    /// 用户点的那些点），path 只用于绘制和算值。
    func densify(_ points: [CGPoint], closed: Bool, document: CadDocument)
        -> ([CGPoint], [Double]) {
        guard points.count >= 2 else { return (points, []) }
        let tolerance = max(4 / transform.scale, 1e-9)
        var path: [CGPoint] = [points[0]]
        var lengths: [Double] = []
        let pairs = closed ? points.count : points.count - 1
        for index in 0..<pairs {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            if let arc = document.arcPath(from: a, to: b, tolerance: tolerance) {
                path.append(contentsOf: arc.dropFirst())
                lengths.append(Double(MeasurementMath.pathLength(arc, closed: false)))
            } else {
                path.append(b)
                lengths.append(Double(MeasurementMath.distance(a, b)))
            }
        }
        return (path, lengths)
    }

    /// 闭合图形的周长（图纸单位）。旧版本存盘的标注没有 perimeter 字段，
    /// 这里按点重算一遍，免得打开老图纸时面积标注只剩一半信息。
    static func perimeter(of annotation: Annotation) -> Double {
        if annotation.perimeter > 0 { return annotation.perimeter }
        switch annotation.kind {
        case .rectangle:
            guard annotation.points.count == 4 else { return 0 }
            let width = MeasurementMath.distance(annotation.points[0], annotation.points[1])
            let height = MeasurementMath.distance(annotation.points[1], annotation.points[2])
            return Double(2 * (width + height))
        case .polygon, .hatchArea:
            guard annotation.points.count >= 3 else { return 0 }
            return Double(MeasurementMath.pathLength(annotation.points, closed: true))
        case .circleArea:
            return 2 * .pi * annotation.secondaryValue
        default:
            return 0
        }
    }

    /// 单位或精度改了之后，已经落在图上的标注要跟着改口：设置里把面积切
    /// 成 ft²，图上却还印着 m²，这张图就自相矛盾了。
    func refreshAnnotationTexts() {
        guard let document else { return }
        var changed = false
        for index in document.annotations.indices {
            var annotation = document.annotations[index]
            let text = describe(annotation, document: document)
            if text != annotation.text {
                annotation.text = text
                document.annotations[index] = annotation
                changed = true
            }
        }
        if changed {
            // 文本变了要落盘并通知侧栏，否则设置关掉后重启又变回旧单位。
            AnnotationStore.save(document.annotations, for: document.url)
            onAnnotationsChanged?()
            needsDisplay = true
        }
    }

    // MARK: Annotation mutation

    func add(_ annotation: Annotation) {
        guard let document else { return }
        document.annotations.append(annotation)
        selectedAnnotation = document.annotations.count - 1
        registerUndo(.add(annotation))
        commitAnnotationChange()
        onSelectionChanged?(annotation)
    }

    func deleteAnnotation(at index: Int) {
        guard let document, index < document.annotations.count else { return }
        let removed = document.annotations.remove(at: index)
        selectedAnnotation = nil
        registerUndo(.remove(removed))
        commitAnnotationChange()
        onSelectionChanged?(nil)
        needsDisplay = true
        onPromptChanged?("已删除 1 条标注 · ⌘Z 可撤销")
    }

    /// 框选删除：只删"完全落进框里"的标注。半在框内的标注往往是用户想留
    /// 下的，按框删掉它是这类工具最常见的误删来源。
    @discardableResult
    func deleteAnnotations(in viewRect: CGRect) -> Bool {
        guard let document else { return false }
        let box = worldRect(from: viewRect)
        let doomed = document.annotations.indices.filter { index in
            let annotation = document.annotations[index]
            guard annotation.space == space, !annotation.hidden else { return false }
            return annotation.points.allSatisfy { box.contains($0) }
        }
        guard !doomed.isEmpty else {
            NSSound.beep()
            onPromptChanged?("框内没有完全框选的标注")
            return false
        }
        let removed = doomed.map { document.annotations[$0] }
        for index in doomed.reversed() { document.annotations.remove(at: index) }
        selectedAnnotation = nil
        // 一条撤销把整框删掉的标注一起还原。
        undoManager?.registerUndo(withTarget: self) { canvas in
            canvas.document?.annotations.append(contentsOf: removed)
            canvas.commitAnnotationChange()
        }
        commitAnnotationChange()
        onSelectionChanged?(nil)
        needsDisplay = true
        onPromptChanged?("已删除 \(removed.count) 条标注 · ⌘Z 可撤销")
        return true
    }

    private func worldRect(from viewRect: CGRect) -> CGRect {
        let a = transform.toWorld(CGPoint(x: viewRect.minX, y: viewRect.minY))
        let b = transform.toWorld(CGPoint(x: viewRect.maxX, y: viewRect.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// 快速标注：把框内的直线段、多段线各段、圆弧、圆一次性量完。
    func commitBatchSelection(in viewRect: CGRect) {
        guard let document else { return }
        let box = worldRect(from: viewRect)
        let candidates = document.index(for: space).query(box)
        let shortest = 6 / transform.scale     // 屏幕上短到看不见的段不标
        let maxDimensions = 24                 // 一框 24 条，避免糊满图面
        var created: [Annotation] = []
        var seen = Set<String>()
        var truncated = false

        func key(_ a: CGPoint, _ b: CGPoint) -> String {
            let x1 = Int((a.x * 100).rounded()), y1 = Int((a.y * 100).rounded())
            let x2 = Int((b.x * 100).rounded()), y2 = Int((b.y * 100).rounded())
            return "\(min(x1, x2)),\(min(y1, y2))-\(max(x1, x2)),\(max(y1, y2))"
        }
        func append(_ points: [CGPoint], _ kind: MeasureKind, _ value: CGFloat) {
            guard created.count < maxDimensions else {
                truncated = true
                return
            }
            let identifier = key(points[0], points[1])
            guard seen.insert(identifier).inserted else { return }
            var annotation = Annotation(kind: kind, space: space, points: points)
            annotation.value = Double(value)
            switch kind {
            case .arcLength:
                annotation.text = document.formatLength(annotation.value)
            case .radius:
                annotation.text = "R" + document.formatLength(annotation.value)
            default:
                annotation.text = document.formatLength(annotation.value)
            }
            created.append(annotation)
        }

        for index in candidates {
            guard created.count < maxDimensions else {
                truncated = true
                break
            }
            let entity = document.entities[Int(index)]
            guard document.isLayerVisible(entity), !entity.isDimensionInk else { continue }
            switch entity.kind {
            case .line, .polyline, .solid:
                let slice = document.points(for: entity)
                guard slice.count >= 2 else { continue }
                for i in (slice.startIndex + 1)..<slice.endIndex {
                    let a = slice[i - 1], b = slice[i]
                    let length = MeasurementMath.distance(a, b)
                    guard length >= shortest else { continue }
                    // 窗口选择语义：只有两个端点都在框内的段才标。之前只看
                    // 中点，一条横穿整张图的墙也会被抽出来，一框就生成几十
                    // 条贯穿全图的尺寸线——这正是“批量很怪”的来源。
                    guard box.contains(a), box.contains(b) else { continue }
                    append([a, b], .aligned, length)
                }
            case .arc:
                let radius = CGFloat(entity.r)
                guard radius >= shortest else { continue }
                var sweep = CGFloat(entity.a1 - entity.a0)
                while sweep <= 0 { sweep += 2 * .pi }
                let start = CGFloat(entity.a0)
                let centre = CGPoint(x: entity.cx, y: entity.cy)
                let points = [start, start + sweep / 2, start + sweep].map {
                    CGPoint(x: centre.x + radius * cos($0), y: centre.y + radius * sin($0))
                }
                guard points.allSatisfy({ box.contains($0) }) else { continue }
                append(points, .arcLength, radius * sweep)
            case .circle:
                let radius = CGFloat(entity.r)
                guard radius >= shortest else { continue }
                let centre = CGPoint(x: entity.cx, y: entity.cy)
                // 圆完整落在框内才标；只包住圆心会把半径线甩到框外。
                let circleBox = CGRect(x: centre.x - radius, y: centre.y - radius,
                                       width: radius * 2, height: radius * 2)
                guard box.contains(circleBox) else { continue }
                append([centre, CGPoint(x: centre.x + radius, y: centre.y)],
                       .radius, radius)
            case .text, .hatch, .ellipse, .point:
                break
            }
        }

        guard !created.isEmpty else {
            NSSound.beep()
            onPromptChanged?("框内没有可标注的线段或圆弧")
            return
        }
        // 保持与 CAD 一致：框选到哪些线段就标哪些，不做自动合并；
        // 同一条墙/门窗需要一条尺寸时，由用户框小一点或手工只选该段。
        // 框选后不立刻落图：先把这批尺寸按“离框中心向外”的方向偏出去，
        // 预览给用户看。点击/回车确认，Esc 取消。原先是 mouse-up 就落图，
        // 几十条尺寸一起压在墙线上，既看不清也没法撤。
        for index in created.indices {
            created[index].labelOffset = batchOutwardOffset(created[index], box: box)
        }
        pendingBatch = created
        pendingBatchViewRect = viewRect
        selectedAnnotation = nil
        needsDisplay = true
        let limitNote = truncated ? "（已到 \(maxDimensions) 条上限，请缩小框选范围）" : ""
        onPromptChanged?("快速标注：预览 \(created.count) 条尺寸\(limitNote) · 点击/回车放置 · Esc 取消")
    }

    /// 批量尺寸统一朝框外偏一点，避免全部压在被量图元上。每段用自己的
    /// 法向，取“背离框中心”的那一侧；具体方向仍由用户之后拖文字调整。
    private func batchOutwardOffset(_ annotation: Annotation, box: CGRect) -> CGPoint {
        guard annotation.points.count >= 2 else { return .zero }
        let a = annotation.points[0]
        let b = annotation.points[annotation.points.count - 1]
        var nx = -(b.y - a.y), ny = b.x - a.x
        let length = max(hypot(nx, ny), 1e-9)
        nx /= length; ny /= length
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        if (mid.x - box.midX) * nx + (mid.y - box.midY) * ny < 0 {
            nx = -nx; ny = -ny
        }
        // labelOffset 是屏幕像素，不是世界坐标；固定外偏 30px。
        return CGPoint(x: nx * 30, y: ny * 30)
    }

    /// 批量预览转正：只有这里才真正写进 document、注册撤销、落盘。
    func commitPendingBatch() {
        guard let document, !pendingBatch.isEmpty else { return }
        let created = pendingBatch
        pendingBatch.removeAll()
        pendingBatchViewRect = .zero
        document.annotations.append(contentsOf: created)
        registerUndo(.addMany(created))
        selectedAnnotation = nil
        commitAnnotationChange()
        onSelectionChanged?(nil)
        // 先收工再写提示：退出工具会把命令行刷成空串，顺序反过来这条战果
        // 就被自己抹掉了。
        finishToolAfterCommit()
        onPromptChanged?("快速标注：新增 \(created.count) 条尺寸 · ⌘Z 可撤销")
    }

    func deleteSelection() {
        guard let document, let index = selectedAnnotation,
              index < document.annotations.count else { return }
        let removed = document.annotations.remove(at: index)
        selectedAnnotation = nil
        registerUndo(.remove(removed))
        commitAnnotationChange()
        onSelectionChanged?(nil)
        needsDisplay = true
    }

    enum UndoAction {
        case add(Annotation)
        case addMany([Annotation])
        case remove(Annotation)
    }

    func registerUndo(_ action: UndoAction) {
        undoManager?.registerUndo(withTarget: self) { canvas in
            switch action {
            case .add(let annotation):
                if let index = canvas.document?.annotations.firstIndex(where: { $0.id == annotation.id }) {
                    canvas.document?.annotations.remove(at: index)
                    canvas.commitAnnotationChange()
                    canvas.registerUndo(.remove(annotation))
                }
            case .addMany(let annotations):
                let ids = Set(annotations.map(\.id))
                canvas.document?.annotations.removeAll { ids.contains($0.id) }
                canvas.commitAnnotationChange()
                canvas.registerUndo(.addMany(annotations))
            case .remove(let annotation):
                canvas.document?.annotations.append(annotation)
                canvas.commitAnnotationChange()
                canvas.registerUndo(.add(annotation))
            }
        }
    }

    func commitAnnotationChange() {
        guard let document else { return }
        AnnotationStore.save(document.annotations, for: document.url)
        onAnnotationsChanged?()
        needsDisplay = true
    }

    /// 从标注清单跳到图纸上的那一条：选中它，并把视野移到它身上。
    ///
    /// 只在"看不清"时才缩放：已经放大到那段墙上时把镜头缩回去，等于把用户
    /// 刚才调好的视距丢掉——看图的人双击清单，要的是"在哪"，不是"重新取景"。
    func revealAnnotation(at index: Int) {
        guard let document, index >= 0, index < document.annotations.count else { return }
        let annotation = document.annotations[index]
        selectedAnnotation = index
        needsDisplay = true
        onSelectionChanged?(annotation)

        var box = CGRect(origin: annotation.points.first ?? annotation.center, size: .zero)
        for point in annotation.points {
            box = box.union(CGRect(origin: point, size: .zero))
        }
        let centre = annotation.center
        box = box.insetBy(dx: -abs(box.width) * 0.15 - 4, dy: -abs(box.height) * 0.15 - 4)
        let needed = max(bounds.width / max(box.width, 1e-6),
                         bounds.height / max(box.height, 1e-6))
        pushViewHistory()
        let target = min(max(transform.scale, needed * 0.35), needed)
        apply(transform: ViewTransform(origin: CGPoint(x: centre.x - bounds.midX / target,
                                                       y: centre.y - bounds.midY / target),
                                       scale: target))
    }

    private func annotationIndex(at world: CGPoint, tolerance: CGFloat) -> Int? {
        guard let document else { return nil }
        let view = transform.toView(world)
        // 标注线画在测量点的外法向十几到三十几像素处，尺寸文字压在线的正中：
        // 这两处在世界坐标里根本没有对应的点，只判 `points` 就永远点不中——
        // 这正是"点尺寸线删不掉、只有点回墙面才删得掉"的原因。所以再补一次
        // 屏幕空间的判定。
        let margin: CGFloat = 60
        for (index, annotation) in document.annotations.enumerated().reversed()
        where annotation.space == space {
            // 先做一次廉价屏幕包围盒剔除：几万条标注时，不能每次鼠标移动
            // 都对所有标注跑 hypot + 线段距离。
            guard let first = annotation.points.first else { continue }
            var box = CGRect(origin: transform.toView(first), size: .zero)
            for point in annotation.points.dropFirst() {
                box = box.union(CGRect(origin: transform.toView(point), size: .zero))
            }
            box = box.insetBy(dx: -margin, dy: -margin)
            if !box.contains(view) { continue }
            if annotation.hitTest(world, tolerance: tolerance) { return index }
            if detailHit(annotation, at: view) { return index }
        }
        return nil
    }

    /// 屏幕空间的"标注自己画出来的东西"：尺寸线所在的那条带、以及文字块。
    private func detailHit(_ annotation: Annotation, at view: CGPoint) -> Bool {
        let p = annotation.points.map { transform.toView($0) }
        guard p.count >= 2 else {
            return hypot(view.x - transform.toView(annotation.center).x,
                         view.y - transform.toView(annotation.center).y) <= 18
        }
        // 文字：标注中心 + 手工拖动量，留 18px 半径（一段 3~4 个字的宽度）。
        let label = CGPoint(x: transform.toView(annotation.center).x + annotation.labelOffset.x,
                            y: transform.toView(annotation.center).y + annotation.labelOffset.y)
        if hypot(view.x - label.x, view.y - label.y) <= 18 { return true }

        // 尺寸线：与测量点连线平行、往外偏 6~46px 的一条带。内边界留 6px，
        // 免得贴着墙点一下就删了标注；外边界 46px 覆盖最大的字号。
        let dx = p[1].x - p[0].x, dy = p[1].y - p[0].y
        let length = hypot(dx, dy)
        guard length > 1 else { return false }
        let nx = -dy / length, ny = dx / length
        let rel = CGPoint(x: view.x - p[0].x, y: view.y - p[0].y)
        let along = rel.x * dx / length + rel.y * dy / length
        let across = abs(rel.x * nx + rel.y * ny)
        guard along >= -4, along <= length + 4 else { return false }
        return across >= 4 && across <= 46
    }

    private func labelHit(_ annotation: Annotation, at world: CGPoint) -> Bool {
        let center = annotation.center
        let scale = max(transform.scale, 1e-9)
        // labelOffset 是像素；换算回世界坐标再和鼠标世界点比较。
        let label = CGPoint(x: center.x + annotation.labelOffset.x / scale,
                            y: center.y + annotation.labelOffset.y / scale)
        let tolerance = 24 / scale
        return abs(world.x - label.x) < tolerance && abs(world.y - label.y) < tolerance
    }

    // MARK: Snapping

    /// One aperture for every tool. 16 pt, not 11: a person aims at the corner
    /// they can see, and on a high-DPI sheet the visible gap between "on the
    /// endpoint" and "a few pixels off" is wider than a small aperture
    /// forgives. A wider net is safe because the engine ranks by meaning first
    /// and distance second.
    static let snapAperture: CGFloat = 16

    /// Snapping is global: one master switch (`settings.objectSnap`) and one set
    /// of armed targets (`settings.snapModes`) shared by measuring, calibrating
    /// and every tool after them — the reference viewer's running osnap.
    @discardableResult
    func snapPoint(for world: CGPoint, from reference: CGPoint?) -> CGPoint {
        guard settings.objectSnap, let document else {
            snapResult = nil
            snapOptions = []
            return world
        }
        let tickLength = AnnotationRenderer.sheetTextHeight > 0
            ? AnnotationRenderer.sheetTextHeight * 1.1 : 0
        let engine = SnapEngine(document: document, space: space,
                                modes: settings.snapModes,
                                dimensionTickLength: tickLength)
        let options = engine.findSnapCandidates(near: world,
                                                tolerance: Self.snapAperture / transform.scale,
                                                from: reference)
        snapOptions = options
        snapOptionIndex = 0
        guard let snap = options.first else {
            snapResult = nil
            return world
        }
        snapResult = snap
        return snap.point
    }

    /// Applies snapping, then ortho and polar constraints around the previous
    /// measurement point.
    func constrained(_ world: CGPoint) -> CGPoint {
        // 闭合点优先于一切：多边形走到第三步以后，回到起点就是"要闭合了"，
        // 这个点可能是空格处随手点的，不在任何图元上，所以 SnapEngine 的候选
        // 里根本没有它。不单独补一个目标，用户就只能靠肉眼把最后一下点回原处。
        if activeTool == .polygon, measurePoints.count >= 3, let first = measurePoints.first,
           MeasurementMath.distance(world, first) <= Self.snapAperture / transform.scale {
            snapResult = SnapResult(point: first, kind: .endpoint, title: "闭合")
            return first
        }

        var point = snapPoint(for: world, from: measurePoints.last)
        // 捕捉命中时，落点必须是捕捉点，正交/极轴不能再改它。否则屏幕上
        // 标着“端点”，实际落点却被推到上一点的水平线上——这比不捕捉更坏。
        // 没有捕捉时正交才约束光标方向，和 CAD 的优先级一致。
        let snapped = snapResult != nil
        // Ortho locks a *direction from the previous pick*, which is what a
        // drafting aid is for. Applying it to a two-corner tool collapses the
        // rectangle to a line (area 0) and skews a three-point circle, so it is
        // restricted to the tools that actually walk a chain of picks.
        let orthoApplies = activeTool.map { tool in
            tool == .aligned || tool == .linear || tool == .continuous
                || tool == .batch || tool == .polygon
        } ?? true
        if settings.orthoMode, !snapped, orthoApplies, let last = measurePoints.last {
            if abs(point.x - last.x) > abs(point.y - last.y) {
                point.y = last.y
            } else {
                point.x = last.x
            }
        }
        if !snapped, NSApp.currentEvent?.modifierFlags.contains(.shift) == true,
           orthoApplies, let last = measurePoints.last {
            let angle = atan2(point.y - last.y, point.x - last.x)
            let snapped = (angle / (.pi / 12)).rounded() * (.pi / 12)
            let distance = hypot(point.x - last.x, point.y - last.y)
            point = CGPoint(x: last.x + cos(snapped) * distance,
                            y: last.y + sin(snapped) * distance)
        }
        return point
    }

    /// Calibration snaps exactly like measuring — same aperture, same armed
    /// targets, same marker — but never applies ortho: locking the direction of
    /// a scale reference would silently shorten a diagonal wall and scale the
    /// whole drawing wrong.
    func calibrationConstrained(_ world: CGPoint) -> CGPoint {
        // 起点传 nil：垂足/切点是"从上一个点出发"的关系，只在测量过程中开启，
        // 校准时只提供端点/中点/圆心/交点。
        snapPoint(for: world, from: nil)
    }

    /// Live feedback while calibrating: the snapped point, the rubber-band
    /// dimension to it and the running length in the command line.
    func updateCalibrationHover(_ world: CGPoint) {
        let point = calibrationConstrained(world)
        measureHover = point
        let readout: String
        if let first = calibrationPoints.first {
            let length = MeasurementMath.distance(first, point)
            let text = document?.formatLength(Double(length)) ?? String(format: "%.0f", length)
            readout = "第二点 · 当前 " + text
            if calibrationReadout != readout {
                calibrationReadout = readout
                onPromptChanged?("比例校准：" + readout + " · 点击确定，右键取消")
            }
        } else {
            readout = settings.objectSnap
                ? "点击已知长度的第一个点 · 可捕捉端点/交点/中点"
                : "点击已知长度的第一个点 · 对象捕捉已关闭，按 F3 开启"
            if calibrationReadout != readout {
                calibrationReadout = readout
                onPromptChanged?("比例校准：" + readout)
            }
        }
    }
}
