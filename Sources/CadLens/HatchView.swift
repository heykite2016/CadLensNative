import AppKit
import QuartzCore

/// Bottom layer of the canvas: the paper, the PDF page and every hatch fill.
///
/// It sits below the GPU pass on purpose. Filled walls and slab patterns are
/// large, opaque areas, and drawing them above the stroke/text layer would
/// swallow the labels that sit inside them.
///
/// Re-rasterising 1600 hatches costs more than the rest of a frame, so the
/// result is cached as a bitmap covering half a viewport of margin on every
/// side. What used to happen next was the problem: the bitmap was blitted
/// through Core Graphics into the view's backing store on *every* frame, and
/// AppKit then re-uploaded all 2560×1600 pixels of that backing store to the
/// GPU. That single upload measured 26 ms per frame — three quarters of the
/// whole interaction cost — to move an image that had not changed at all.
///
/// The fills are now drawn exactly once per raster into a `CALayer`'s
/// `contents`, and panning/zooming only changes that layer's `frame`. Core
/// Animation then moves and scales the existing texture on the GPU, so a pan
/// frame costs nothing for the fills: no Core Graphics pass, no upload. The
/// raster itself is regenerated on the same schedule as before — when the
/// camera settles, or when the viewport leaves the cached region.
final class HatchView: NSView, ThemeAware {

    var document: CadDocument? {
        didSet {
            renderer = document.map { CadRenderer(document: $0) }
            invalidate()
        }
    }

    var space: Int32 = 0 {
        didSet {
            guard space != oldValue else { return }
            invalidate()
        }
    }

    var transform = ViewTransform() {
        didSet {
            guard transform.scale != oldValue.scale
                    || transform.origin != oldValue.origin else { return }
            updatePaper()
        }
    }

    var settings = CadSettings.load() {
        didSet { invalidate() }
    }

    /// While a gesture is running the cached bitmap is stretched instead of
    /// being rebuilt; the sheet re-rasterises as soon as the input settles.
    var isInteracting = false {
        didSet {
            guard isInteracting != oldValue, !isInteracting else { return }
            updatePaper()
        }
    }

    /// Carries the fill raster. Sized in view points to the world rectangle it
    /// covers, so moving the camera is a `frame` assignment and nothing else.
    private let paperLayer = CALayer()

    private var renderer: CadRenderer?
    private var cacheImage: CGImage?
    private var cacheWorld: CGRect = .null
    private var cacheScale: CGFloat = 0

    override var isOpaque: Bool { true }
    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The paper colour is painted by the compositor from the layer's own
        // background colour — one GPU fill, never an upload.
        layer?.backgroundColor = Theme.canvasBackground.cgColor
        layer?.masksToBounds = true
        paperLayer.contentsGravity = .resize
        // `.low` interpolation on a stretched raster is what the old Core
        // Graphics blit did; `.linear` is the layer equivalent.
        paperLayer.magnificationFilter = .linear
        paperLayer.minificationFilter = .linear
        paperLayer.isOpaque = false
        layer?.addSublayer(paperLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func themeDidChange() {
        layer?.backgroundColor = Theme.canvasBackground.cgColor
        cacheImage = nil
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        updatePaper()
    }

    func invalidate() {
        cacheImage = nil
        cacheWorld = .null
        cacheScale = 0
        updatePaper()
    }

    /// Points the paper layer at the cached raster, re-rasterising first when
    /// the cache cannot serve the current camera.
    private func updatePaper() {
        // The single-pass Core Graphics fallback hides this view and paints the
        // fills itself; rasterising 1600 hatches for a layer nobody can see was
        // the whole load-time cost of that mode.
        guard !isHidden else { return }
        guard bounds.width > 1, bounds.height > 1, transform.scale > 0,
              let document else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            paperLayer.contents = nil
            CATransaction.commit()
            return
        }

        let visibleWorld = transform.worldRect(bounds)
        let sameScale = cacheScale > 0
            && abs(cacheScale - transform.scale) <= transform.scale * 1e-9
        let covers = cacheImage != nil && sameScale && cacheWorld.contains(visibleWorld)
        // Mid-gesture a stale raster is reused: a slightly soft fill beats a
        // stalled drag. Once the input settles the exact one is rebuilt.
        if !covers && (cacheImage == nil || !isInteracting) {
            rasterise(document: document, world: visibleWorld)
        }

        guard let image = cacheImage, !cacheWorld.isNull else { return }
        let origin = transform.toView(CGPoint(x: cacheWorld.minX, y: cacheWorld.minY))
        let size = CGSize(width: cacheWorld.width * transform.scale,
                          height: cacheWorld.height * transform.scale)
        guard size.width > 1, size.height > 1 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        paperLayer.contents = image
        paperLayer.frame = CGRect(origin: origin, size: size)
        CATransaction.commit()
    }

    /// World-space reference grid, stroked into the fill raster.
    ///
    /// The spacing rule is the one the overlay used: the smallest 10^n step
    /// that is at least 40 points on screen, so the grid never turns into a
    /// solid wash of lines when the view is zoomed out.
    private func drawGrid(in ctx: CGContext, region: CGRect, pixelsPerUnit: CGFloat) {
        guard settings.showGrid, transform.scale > 0, pixelsPerUnit > 0 else { return }
        var step = 10.0 as CGFloat
        while step * transform.scale < 40 { step *= 10 }

        let startX = (region.minX / step).rounded(.down) * step
        let startY = (region.minY / step).rounded(.down) * step
        let path = CGMutablePath()
        var x = startX
        while x <= region.maxX {
            path.move(to: CGPoint(x: x, y: region.minY))
            path.addLine(to: CGPoint(x: x, y: region.maxY))
            x += step
        }
        var y = startY
        while y <= region.maxY {
            path.move(to: CGPoint(x: region.minX, y: y))
            path.addLine(to: CGPoint(x: region.maxX, y: y))
            y += step
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(Theme.canvasGrid.cgColor)
        // One device pixel, whatever the raster was scaled to.
        ctx.setLineWidth(1 / pixelsPerUnit)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Renders the fills for `world` (plus a quarter-viewport margin) into a
    /// bitmap and stores it as the new cache.
    private func rasterise(document: CadDocument, world: CGRect) {
        let started = CACurrentMediaTime()
        let pixelScale = window?.backingScaleFactor ?? 2
        // A quarter of a viewport of margin on each side: a pan within that
        // distance reuses the cached bitmap instead of re-rasterising.
        var region = world.insetBy(dx: -world.width * 0.25, dy: -world.height * 0.25)
        let pixelsPerUnit = transform.scale * pixelScale
        // Cap the bitmap so a deep zoom cannot ask for a 100 MB texture.
        let limit: CGFloat = 4096
        let widest = max(region.width, region.height) * pixelsPerUnit
        if widest > limit {
            let shrink = (1 - limit / widest) * 0.5
            region = region.insetBy(dx: region.width * shrink, dy: region.height * shrink)
        }
        let width = Int((region.width * pixelsPerUnit).rounded())
        let height = Int((region.height * pixelsPerUnit).rounded())
        guard width > 1, height > 1, width <= 8192, height <= 8192,
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ??
                                      CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return
        }

        ctx.scaleBy(x: CGFloat(width) / region.width, y: CGFloat(height) / region.height)
        ctx.translateBy(x: -region.minX, y: -region.minY)
        ctx.setShouldAntialias(true)

        if document.isPDF, let page = document.pdfPage(space) {
            ctx.interpolationQuality = .high
            page.draw(with: .mediaBox, to: ctx)
        }

        var options = CadRenderer.Options()
        options.drawLines = false
        options.drawText = false
        // A fill rebuild that happens during a gesture drops the sub-pixel
        // patterns; the crisp pass runs as soon as the input settles.
        options.quality = isInteracting ? 0 : 1
        options.lineWidthScale = transform.scale

        let active = renderer ?? CadRenderer(document: document)
        renderer = active
        active.draw(entities: document.index(for: space).query(region), space: space,
                    in: ctx, worldRect: region, scale: transform.scale, options: options)

        // The grid belongs to the paper, not to the pointer overlay. Drawing it
        // into this raster means it rides along with the fill layer for free;
        // keeping it on the overlay cost a full-screen backing-store upload on
        // every frame of every pan, to move a handful of straight lines.
        drawGrid(in: ctx, region: region,
                 pixelsPerUnit: CGFloat(width) / max(region.width, 1e-9))

        cacheImage = ctx.makeImage()
        cacheWorld = region
        cacheScale = transform.scale
        if ProcessInfo.processInfo.environment["CADLENS_FRAME_LOG"] != nil {
            print(String(format: "[hatch] raster %dx%d in %6.2f ms", width, height,
                         (CACurrentMediaTime() - started) * 1000))
        }
    }
}
