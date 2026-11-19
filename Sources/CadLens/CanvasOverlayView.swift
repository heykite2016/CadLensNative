import AppKit
import QuartzCore

/// Top layer of the canvas: the measurement annotations, the snap marker and
/// the pointer crosshair.
///
/// It is a separate view rather than part of `CanvasView`'s own drawing so the
/// canvas can host the GPU layer without also owning translucent overlay
/// content, which AppKit renders differently for layer-backed views.
///
/// The crosshair lives in three shape sublayers instead of being stroked into
/// this view's backing store. Painting it meant AppKit re-uploaded the whole
/// 2560×1600 backing store of this layer on every frame of a drag — 11 ms on
/// this GPU — just to move a pair of straight lines. As layers, moving them is
/// a compositor operation: no Core Graphics pass, no upload, no matter how
/// often the pointer moves.
final class CanvasOverlayView: NSView {

    weak var canvas: CanvasView?

    /// 十字线：虚线，且在中心取景框处断开。CAD 的十字光标不是一根贯穿屏幕的
    /// 实线——虚线才不会和图纸自己的线抢注意力，断开的那一小段就是"点会落在
    /// 这里"。
    private let horizontalBar = CAShapeLayer()
    private let verticalBar = CAShapeLayer()
    /// 中心取景框：实线小方框，比捕捉方框小一圈。
    private let pickBox = CAShapeLayer()
    /// 每条线底下再压一层反向色描边：光标压在同色图元上时仍有轮廓，相当于
    /// CAD 的 XOR 反色光标在图层版上的静态近似。
    private let horizontalHalo = CAShapeLayer()
    private let verticalHalo = CAShapeLayer()
    private let pickBoxHalo = CAShapeLayer()
    /// 光标颜色按画布明暗取反，缓存键必须带画布 tone：切深/浅画布时系统外观
    /// 没变，只按 appearance.name 缓存会让光标沿用旧色，在白底上消失。
    private var cachedTint: CGColor?
    private var cachedHalo: CGColor?
    private var cachedTintKey: String?
    private var installed = false

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for layer in [horizontalBar, verticalBar, pickBox,
                      horizontalHalo, verticalHalo, pickBoxHalo] {
            layer.fillColor = nil
            layer.isHidden = true
            layer.contentsScale = window?.backingScaleFactor ?? 2
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Pointer events belong to the canvas underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        canvas?.updateCrosshair()
    }

    /// Places the crosshair at `point` in view coordinates, or hides it when
    /// `nil`. `pixelScale` keeps the strokes one device pixel wide so they look
    /// exactly like the 0.5 pt stroke they replace.
    func setCrosshair(at point: CGPoint?, pixelScale: CGFloat) {
        // `wantsLayer = true` only flags the view; `layer` is still nil in
        // `init`, so sublayers attached there were silently dropped and the
        // crosshair never appeared. Install them once the layer actually
        // exists, which is when this is first called.
        if let root = layer, !installed {
            // 先铺描边层再铺主线，主线才压在轮廓之上。
            root.addSublayer(horizontalHalo)
            root.addSublayer(verticalHalo)
            root.addSublayer(pickBoxHalo)
            root.addSublayer(horizontalBar)
            root.addSublayer(verticalBar)
            root.addSublayer(pickBox)
            installed = true
        }
        guard let point, bounds.width > 1, bounds.height > 1 else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for layer in [horizontalBar, verticalBar, pickBox,
                          horizontalHalo, verticalHalo, pickBoxHalo] {
                layer.isHidden = true
            }
            CATransaction.commit()
            return
        }
        let thickness = 1 / max(pixelScale, 1)
        // 缓存键必须包含画布明暗：单独切黑/白画布不改变窗口 appearance，
        // 只按 appearance.name 缓存会留下上一张底色的反色，光标在白底上
        // 变成白线就看不见了。
        let tintKey = "\(String(describing: window?.effectiveAppearance.name))|\(Theme.isDark)"
        if cachedTint == nil || tintKey != cachedTintKey {
            cachedTint = Theme.crosshair.withAlphaComponent(0.92).cgColor
            cachedHalo = Theme.crosshairHalo.cgColor
            cachedTintKey = tintKey
        }
        let colour = cachedTint
        let haloColour = cachedHalo
        let half = CanvasView.pickBoxSize / 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Sublayers default to a contents scale of 1. A stroke one device pixel
        // wide is half a point at 2x, so at scale 1 it rounded away to nothing
        // and the crosshair was invisible however correct its path was.
        for layer in [horizontalBar, verticalBar, pickBox] {
            layer.contentsScale = pixelScale
            layer.strokeColor = colour
            layer.lineWidth = thickness
            layer.frame = bounds
        }
        // 轮廓层略粗，先画；主线细一档压在上面。
        for layer in [horizontalHalo, verticalHalo, pickBoxHalo] {
            layer.contentsScale = pixelScale
            layer.strokeColor = haloColour
            layer.lineWidth = thickness + 2 / max(pixelScale, 1)
            layer.frame = bounds
        }
        horizontalBar.lineDashPattern = [6, 4]
        verticalBar.lineDashPattern = [6, 4]
        pickBox.lineDashPattern = nil
        horizontalHalo.lineDashPattern = [6, 4]
        verticalHalo.lineDashPattern = [6, 4]
        pickBoxHalo.lineDashPattern = nil

        // 路径在 layer 坐标系里画（与视图同坐标系），中心留出取景框的空档。
        let h = CGMutablePath()
        if point.x - half > 0 {
            h.move(to: CGPoint(x: 0, y: point.y))
            h.addLine(to: CGPoint(x: point.x - half, y: point.y))
        }
        if point.x + half < bounds.width {
            h.move(to: CGPoint(x: point.x + half, y: point.y))
            h.addLine(to: CGPoint(x: bounds.width, y: point.y))
        }
        let v = CGMutablePath()
        if point.y - half > 0 {
            v.move(to: CGPoint(x: point.x, y: 0))
            v.addLine(to: CGPoint(x: point.x, y: point.y - half))
        }
        if point.y + half < bounds.height {
            v.move(to: CGPoint(x: point.x, y: point.y + half))
            v.addLine(to: CGPoint(x: point.x, y: bounds.height))
        }
        horizontalBar.path = h
        verticalBar.path = v
        let boxPath = CGPath(rect: CGRect(x: point.x - half, y: point.y - half,
                                          width: half * 2, height: half * 2),
                             transform: nil)
        pickBox.path = boxPath
        horizontalHalo.path = h
        verticalHalo.path = v
        pickBoxHalo.path = boxPath
        for layer in [horizontalHalo, verticalHalo, pickBoxHalo,
                      horizontalBar, verticalBar, pickBox] {
            layer.isHidden = false
        }
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let canvas else { return }
        let started = CACurrentMediaTime()
        canvas.drawOverlay(in: ctx)
        if ProcessInfo.processInfo.environment["CADLENS_FRAME_LOG"] != nil {
            print(String(format: "[overlay] %6.2f ms",
                         (CACurrentMediaTime() - started) * 1000))
        }
    }
}
