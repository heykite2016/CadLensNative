import AppKit

/// Everything a raster request needs, captured on the main thread so the
/// background pass never touches view state.
struct SheetRequest {
    let id: Int
    let transform: ViewTransform
    let size: CGSize
    let space: Int32
    let signature: Int
    let scaleFactor: CGFloat
    let quality: Int
    let showLineweights: Bool
}

extension CanvasView {
    /// Quality/visibility fingerprint of the cached raster. A camera change does
    /// not invalidate the raster (it is blitted through an affine transform);
    /// anything that changes what the pixels look like does.
    func currentSheetSignature() -> Int {
        var hasher = Hasher()
        hasher.combine(space)
        hasher.combine(settings.canvasQuality)
        hasher.combine(settings.showLineweights)
        hasher.combine(Theme.isDark)
        // A change of screen scale needs a new raster at a new pixel density.
        hasher.combine(window?.backingScaleFactor ?? 2)
        return hasher.finalize()
    }

    func sheetRequest(signature: Int) -> SheetRequest {
        let size = bounds.size
        var factor = window?.backingScaleFactor ?? 2
        // Diagnostic: renders the sheet at a lower pixel density so the cost of
        // rasterisation can be separated from the cost of geometry.
        if let override = getenv("CADLENS_SHEET_SCALE"),
           let value = Double(String(cString: override)), value > 0.05 {
            factor = CGFloat(value)
        }
        // Diagnostic switch: stroke everything with the hairline pen, so the
        // cost of real line weights can be measured separately.
        let weights = settings.showLineweights && getenv("CADLENS_NO_LW") == nil
        return SheetRequest(id: 0, transform: transform, size: size,
                            space: space, signature: signature,
                            scaleFactor: factor,
                            quality: settings.canvasQuality,
                            showLineweights: weights)
    }

    /// Draws the cached raster under the current camera and reports whether it
    /// covered the whole canvas.
    ///
    /// Both cameras map world to view, so composing them gives a plain
    /// scale plus translate. Nothing is decimated for this: during a gesture the
    /// pixels are the full-quality ones, merely resampled, and the exact raster
    /// replaces them as soon as the input settles.
    @discardableResult
    func blitSheet(_ image: CGImage, in ctx: CGContext) -> Bool {
        let cached = sheetTransform
        guard cached.scale > 1e-12, sheetPointSize.width > 0 else { return false }
        let ratio = transform.scale / cached.scale
        let dx = (cached.origin.x - transform.origin.x) * transform.scale
        let dy = (cached.origin.y - transform.origin.y) * transform.scale
        let destination = CGRect(x: dx, y: dy,
                                 width: sheetPointSize.width * ratio,
                                 height: sheetPointSize.height * ratio)
        // Only a partial blit leaves canvas showing through; the fill costs a
        // full-surface write, so skip it whenever the raster already covers
        // everything (the common case for a pan-free redraw).
        if !destination.contains(bounds) {
            ctx.saveGState()
            ctx.setFillColor(Theme.canvasBackground.cgColor)
            ctx.fill(bounds)
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.clip(to: bounds)
        ctx.translateBy(x: dx, y: dy)
        ctx.scaleBy(x: ratio, y: ratio)
        // Bilinear while the raster is being resampled, exact pixels when the
        // camera already matches it.
        ctx.interpolationQuality = ratio == 1 ? .none : .low
        let t0 = CACurrentMediaTime()
        ctx.draw(image, in: CGRect(origin: .zero, size: sheetPointSize))
        if getenv("CADLENS_FRAME_LOG") != nil {
            print(String(format: "[blit] %.2f ms  ratio=%.3f  covered=%@",
                         (CACurrentMediaTime() - t0) * 1000, ratio,
                         destination.contains(bounds) ? "yes" : "no"))
        }
        ctx.restoreGState()
        return destination.contains(bounds)
    }

    /// Synchronous raster, used when there is nothing to blit yet. Runs on the
    /// render queue so it can never race a background pass.
    func renderSheetImmediately(_ request: SheetRequest) -> CGImage? {
        var image: CGImage?
        sheetQueue.sync { image = renderSheet(request) }
        return image
    }

    /// Rasterises the sheet at `request.transform`. Must run on `sheetQueue`:
    /// both the renderer's caches and the document display list are only safe
    /// to touch from there.
    func renderSheet(_ request: SheetRequest) -> CGImage? {
        guard let document, request.size.width > 1, request.size.height > 1 else {
            return nil
        }
        let pixelW = Int((request.size.width * request.scaleFactor).rounded())
        let pixelH = Int((request.size.height * request.scaleFactor).rounded())
        guard pixelW > 1, pixelH > 1 else { return nil }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: pixelW, height: pixelH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        if renderer == nil || rendererDocument !== document {
            renderer = CadRenderer(document: document)
            rendererDocument = document
        }
        let active = renderer ?? CadRenderer(document: document)

        let start = CACurrentMediaTime()
        ctx.setFillColor(Theme.canvasBackground.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(pixelW), height: CGFloat(pixelH)))
        // From here on the context is in points, matching the view.
        ctx.scaleBy(x: request.scaleFactor, y: request.scaleFactor)

        var options = CadRenderer.Options(showLineweights: request.showLineweights,
                                          quality: request.quality)
        options.drawHatches = true
        options.lineWidthScale = request.transform.scale
        options.minimumPixels = request.quality >= 2 ? 0.02
                              : request.quality == 1 ? 0.04 : 0.08

        ctx.scaleBy(x: request.transform.scale, y: request.transform.scale)
        ctx.translateBy(x: -request.transform.origin.x,
                        y: -request.transform.origin.y)
        let world = request.transform.worldRect(CGRect(origin: .zero, size: request.size))
        let candidates = document.index(for: request.space).query(world)
        active.draw(entities: candidates, space: request.space, in: ctx,
                    worldRect: world, scale: request.transform.scale,
                    options: options)

        let image = ctx.makeImage()
        if ProcessInfo.processInfo.environment["CADLENS_FRAME_LOG"] != nil {
            print(String(format: "[sheet] %.1f ms  visible=%d  scale=%.5g  %.0fx%.0f",
                         (CACurrentMediaTime() - start) * 1000, candidates.count,
                         request.transform.scale, request.size.width,
                         request.size.height))
        }
        return image
    }

    /// Schedules the full-quality pass for the current camera, debounced so a
    /// continuous gesture issues one render instead of one per mouse tick.
    func scheduleSheetRefresh(delay: TimeInterval = 0.07) {
        sheetWorkItem?.cancel()
        let token = nextSheetRequestID()
        let request = sheetRequest(signature: currentSheetSignature())
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // A cancelled item still runs; a superseded one must not spend a
            // whole raster on a camera the user has already left.
            guard self.isCurrentSheetRequest(token) else { return }
            guard let image = self.renderSheet(request) else { return }
            guard self.isCurrentSheetRequest(token) else { return }
            DispatchQueue.main.async {
                guard self.sheetRequestID == token else { return }
                self.sheetImage = image
                self.sheetTransform = request.transform
                self.sheetPointSize = request.size
                self.sheetSpace = request.space
                self.sheetSignature = request.signature
                self.sheetRenderPending = false
                self.needsDisplay = true
            }
        }
        sheetWorkItem = item
        sheetRenderPending = true
        sheetPendingTransform = transform
        sheetQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func nextSheetRequestID() -> Int {
        sheetLock.lock()
        defer { sheetLock.unlock() }
        sheetRequestID &+= 1
        return sheetRequestID
    }

    func isCurrentSheetRequest(_ token: Int) -> Bool {
        sheetLock.lock()
        defer { sheetLock.unlock() }
        return sheetRequestID == token
    }

    /// Drops the raster so the next draw rebuilds it (document or size change).
    func invalidateSheet() {
        sheetImage = nil
        sheetPointSize = .zero
        sheetSpace = -1
        sheetSignature = 0
        _ = nextSheetRequestID()
        sheetWorkItem?.cancel()
        sheetRenderPending = false
    }

    /// Runs `body` with the render queue held, so display-list mutations cannot
    /// race a raster that is reading it.
    func withSheetQueue(_ body: @escaping () -> Void) {
        sheetQueue.sync(execute: body)
    }
}
