import AppKit
import Metal
import QuartzCore
import simd

/// GPU renderer for the drawing itself.
///
/// Strokes are uploaded once as a list of world-space segments and glyphs are
/// drawn from a raster atlas, so panning and zooming only change a uniform: a
/// 100k-entity sheet redraws at display rate instead of being re-stroked and
/// re-typeset on the CPU for each frame.
///
/// Hatch patterns and the measurement overlays stay on the Core Graphics layer
/// above this one, where they can use real pattern and clipping machinery.
final class MetalCanvasRenderer {

    struct Segment {
        var p0: SIMD2<Float>
        var p1: SIMD2<Float>
        /// Unit normal of `p1 - p0`, precomputed when the segment is uploaded.
        ///
        /// Deriving it here rather than in the vertex shader is what makes the
        /// pass affordable: every segment used to run `precise::length` plus a
        /// divide on all four of its vertices, and `precise::length` forces an
        /// IEEE-exact square root that costs hundreds of cycles on an Intel
        /// integrated GPU. The normal only depends on the geometry, which is
        /// rebuilt once per camera bucket, so paying for it once per segment
        /// instead of once per vertex removes the entire vertex bottleneck.
        /// Packed into the padding that used to sit between `color` and `clip`,
        /// so the buffer does not grow by a single byte.
        var normal: SIMD2<Float>
        var width: Float
        var color: UInt32
        /// World-space clip rect (minx, miny, maxx, maxy) of the paper-space
        /// viewport this stroke was composed into. -1/-1/-1/-1 means no clip.
        var clip: SIMD4<Float> = SIMD4<Float>(repeating: -1)

        init(p0: SIMD2<Float>, p1: SIMD2<Float>, width: Float, color: UInt32,
             clip: SIMD4<Float>) {
            self.p0 = p0
            self.p1 = p1
            self.width = width
            self.color = color
            self.clip = clip
            let dx = p1.x - p0.x, dy = p1.y - p0.y
            let length = (dx * dx + dy * dy).squareRoot()
            // A zero-length segment draws nothing either way; keep the value
            // finite so the quad never degenerates into NaN coordinates.
            self.normal = length > 1e-20
                ? SIMD2<Float>(-dy / length, dx / length)
                : SIMD2<Float>(0, 1)
        }
    }

    struct TextQuad {
        var uv: SIMD4<Float>
        var p0: SIMD2<Float>
        var dx: SIMD2<Float>
        var dy: SIMD2<Float>
        var color: UInt32
        var page: UInt32
        var clip: SIMD4<Float> = SIMD4<Float>(repeating: -1)
    }

    struct Uniforms {
        var origin: SIMD2<Float>
        var viewport: SIMD2<Float>
        var scale: Float
        var hairline: Float
        /// Backing scale, so line weights authored in points stay one point.
        var pixelScale: Float
    }

    private struct TextGroup {
        var page: Int
        var start: Int
        var count: Int
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let linePipeline: MTLRenderPipelineState
    private let textPipeline: MTLRenderPipelineState
    private let atlas: GlyphAtlas

    private var segmentBuffer: MTLBuffer?
    private var segmentCount = 0
    /// Camera scale the stroke buffer was tessellated for. Simplify keeps
    /// roughly 0.35 screen pixels of error, so a buffer built for one scale is
    /// only valid within a factor of ~2: at ten times the scale the chords are
    /// ten pixels off, which turns every arc into a straight line and every
    /// small closed polyline into a single diagonal.
    private var builtStrokeScale: CGFloat = 0
    /// World rect the stroke buffer covers. Panning past it needs a rebuild
    /// just as much as zooming does.
    private var builtVisibleRect: CGRect = .null

    private var textBuffer: MTLBuffer?
    private var textCount = 0
    private var textGroups: [TextGroup] = []

    /// Geometry is only rebuilt when the camera scale drifts far enough that
    /// the glyph rasters would have to be stretched.
    private var builtScale: CGFloat = 0
    private var builtPixelScale: CGFloat = 0
    private var hasTextGeometry = false

    private(set) var isAvailable = false
    /// `ProcessInfo.environment` rebuilds the whole environment dictionary on
    /// every read. Reading it per entity cost seconds on a 389k-entity layout,
    /// so the diagnostics are resolved once.
    private static let lodDisabled =
        ProcessInfo.processInfo.environment["CADLENS_NO_LOD"] != nil
    static let frameLogging =
        ProcessInfo.processInfo.environment["CADLENS_FRAME_LOG"] != nil
    /// Milliseconds the last `draw` spent blocked in `nextDrawable()`.
    private(set) var lastDrawableWaitMS = 0.0

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.atlas = GlyphAtlas(device: device)

        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct Segment {
            float2 p0;
            float2 p1;
            float2 normal;
            float width;
            uint color;
            float4 clip;
        };

        struct TextQuad {
            float4 uv;
            float2 p0;
            float2 dx;
            float2 dy;
            uint color;
            uint page;
            float4 clip;
        };

        struct Uniforms {
            float2 origin;
            float2 viewport;
            float scale;
            float hairline;
            float pixelScale;
        };

        struct VertexOut {
            float4 position [[position]];
            float4 color;
            float lane;
            float halfWidth;
            float4 clip;
        };

        struct TextOut {
            float4 position [[position]];
            float4 color;
            float2 uv;
            float4 clip;
        };

        // World-space viewport clip -> framebuffer pixel rectangle.
        // The vertex stage works in bottom-up screen coordinates while the
        // fragment [[position]] is top-down, hence the viewport.y flip.
        static inline float4 clipToPixels(float4 world, float2 origin,
                                          float scale, float viewportY) {
            if (!(world.z > world.x && world.w > world.y)) {
                return float4(-1.0, -1.0, -1.0, -1.0);
            }
            return float4((world.x - origin.x) * scale,
                          viewportY - (world.w - origin.y) * scale,
                          (world.z - origin.x) * scale,
                          viewportY - (world.y - origin.y) * scale);
        }

        static inline bool clippedOut(float4 position, float4 clip) {
            if (!(clip.z > clip.x)) return false;
            return position.x < clip.x || position.x > clip.z
                || position.y < clip.y || position.y > clip.w;
        }

        static inline float4 unpackColor(uint c) {
            return float4(float((c >> 16) & 0xFF) / 255.0,
                          float((c >> 8) & 0xFF) / 255.0,
                          float(c & 0xFF) / 255.0, 1.0);
        }

        // AppKit view space is bottom-up (y grows upward), and Metal's NDC
        // y = -1 is the bottom of the target. Map them directly; the old
        // `1.0 - ...` mirrored every line and glyph vertically on screen.
        // The screenshot harness used to hide it by flipping the snapshot.
        static inline float4 toClip(float2 screen, float2 viewport) {
            return float4(screen.x / viewport.x * 2.0 - 1.0,
                          screen.y / viewport.y * 2.0 - 1.0, 0.0, 1.0);
        }

        vertex VertexOut lineVertex(uint vid [[vertex_id]],
                                    uint iid [[instance_id]],
                                    device const Segment *segments [[buffer(0)]],
                                    constant Uniforms &uniforms [[buffer(1)]]) {
            Segment s = segments[iid];
            float2 a = (s.p0 - uniforms.origin) * uniforms.scale;
            float2 b = (s.p1 - uniforms.origin) * uniforms.scale;

            // One extra pixel of coverage on each side is resolved by the
            // fragment shader, which fades the edge instead of relying on
            // multisampling: 4x MSAA on a million sub-pixel quads is exactly
            // the load that makes a CAD pan stutter.
            float halfWidth = max(s.width * uniforms.pixelScale, uniforms.hairline)
                              * 0.5 + 0.5;
            float2 base = (vid & 1) == 0 ? a : b;
            float side = (vid & 2) == 0 ? 1.0 : -1.0;
            float2 position = base + s.normal * (halfWidth * side);

            VertexOut out;
            out.position = toClip(position, uniforms.viewport);
            out.color = unpackColor(s.color);
            out.lane = side * halfWidth;
            out.halfWidth = halfWidth;
            out.clip = clipToPixels(s.clip, uniforms.origin, uniforms.scale,
                                    uniforms.viewport.y);
            return out;
        }

        fragment float4 lineFragment(VertexOut in [[stage_in]]) {
            if (clippedOut(in.position, in.clip)) discard_fragment();
            // Distance from the centre line, in pixels.
            float alpha = clamp(in.halfWidth - fabs(in.lane), 0.0, 1.0);
            if (alpha <= 0.002) discard_fragment();
            return float4(in.color.rgb * alpha, alpha);
        }

        vertex TextOut textVertex(uint vid [[vertex_id]],
                                  uint iid [[instance_id]],
                                  device const TextQuad *quads [[buffer(0)]],
                                  constant Uniforms &uniforms [[buffer(1)]]) {
            TextQuad q = quads[iid];
            float2 corner = float2((vid & 1) == 0 ? 0.0 : 1.0,
                                   (vid & 2) == 0 ? 0.0 : 1.0);
            float2 world = q.p0 + q.dx * corner.x + q.dy * corner.y;
            float2 screen = (world - uniforms.origin) * uniforms.scale;

            TextOut out;
            out.position = toClip(screen, uniforms.viewport);
            out.color = unpackColor(q.color);
            out.uv = q.uv.xy + float2(corner.x * q.uv.z, (1.0 - corner.y) * q.uv.w);
            out.clip = clipToPixels(q.clip, uniforms.origin, uniforms.scale,
                                    uniforms.viewport.y);
            return out;
        }

        fragment float4 textFragment(TextOut in [[stage_in]],
                                     texture2d<float> atlas [[texture(0)]]) {
            if (clippedOut(in.position, in.clip)) discard_fragment();
            constexpr sampler texSampler(filter::linear, address::clamp_to_edge);
            float alpha = atlas.sample(texSampler, in.uv).r;
            if (alpha <= 0.004) discard_fragment();
            // Premultiplied so the glyph edge keeps the drawing colour instead
            // of fading towards the background.
            return float4(in.color.rgb * alpha, alpha);
        }
        """

        guard let library = try? device.makeLibrary(source: source, options: nil),
              let lineVertex = library.makeFunction(name: "lineVertex"),
              let lineFragment = library.makeFunction(name: "lineFragment"),
              let textVertex = library.makeFunction(name: "textVertex"),
              let textFragment = library.makeFunction(name: "textFragment") else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.rasterSampleCount = 1
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.vertexFunction = lineVertex
        descriptor.fragmentFunction = lineFragment
        let lineAttachment = descriptor.colorAttachments[0]!
        lineAttachment.isBlendingEnabled = true
        lineAttachment.rgbBlendOperation = .add
        lineAttachment.alphaBlendOperation = .add
        lineAttachment.sourceRGBBlendFactor = .one
        lineAttachment.sourceAlphaBlendFactor = .one
        lineAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        lineAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let linePipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
        else { return nil }

        let textDescriptor = MTLRenderPipelineDescriptor()
        textDescriptor.rasterSampleCount = 1
        textDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        textDescriptor.vertexFunction = textVertex
        textDescriptor.fragmentFunction = textFragment
        let attachment = textDescriptor.colorAttachments[0]!
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let textPipeline = try? device.makeRenderPipelineState(descriptor: textDescriptor)
        else { return nil }

        self.linePipeline = linePipeline
        self.textPipeline = textPipeline
        self.isAvailable = true
    }

    // MARK: Geometry upload

    /// World-space viewport clip carried by a composed layout entity.
    /// -1/-1/-1/-1 is the "no clip" sentinel understood by the shaders.
    private func clipVector(_ entity: Entity) -> SIMD4<Float> {
        guard entity.hasClip else { return SIMD4<Float>(repeating: -1) }
        return SIMD4<Float>(Float(entity.clip.minX), Float(entity.clip.minY),
                            Float(entity.clip.maxX), Float(entity.clip.maxY))
    }

    /// Cheap CPU-side rejection of strokes that lie entirely outside their
    /// paper-space viewport. The fragment shader still clips at pixel level;
    /// this only avoids uploading geometry that cannot be visible at all.
    private func clipAllows(_ p0: CGPoint, _ p1: CGPoint, _ clip: CGRect?) -> Bool {
        guard let clip else { return true }
        if max(p0.x, p1.x) < clip.minX || min(p0.x, p1.x) > clip.maxX { return false }
        if max(p0.y, p1.y) < clip.minY || min(p0.y, p1.y) > clip.maxY { return false }
        return true
    }

    private func packed(_ entity: Entity) -> UInt32 {
        let theme = Theme.aciColor(entity.aci, rgb: entity.rgb)
        let rgb = theme.usingColorSpace(.sRGB) ?? theme
        let r = UInt32(max(0, min(255, Int(rgb.redComponent * 255))))
        let g = UInt32(max(0, min(255, Int(rgb.greenComponent * 255))))
        let b = UInt32(max(0, min(255, Int(rgb.blueComponent * 255))))
        return r << 16 | g << 8 | b
    }

    /// Uploads every stroke of one space. Widths are expressed in points, the
    /// shader scales them against `hairline` so thin CAD line weights survive.
    ///
    /// Curves are tessellated against their on-screen size: a full circle at
    /// 30 pixels across needs a dozen segments, not a hundred, and a sheet with
    /// 700k segments is one that will not pan at 60 fps.
    func build(document: CadDocument, space: Int32, showLineweights: Bool,
               scale: CGFloat, visible: CGRect = .null) {
        let started = CACurrentMediaTime()
        var segments: [Segment] = []
        // 50 万线段的图在 fit/extents 时会反复扩容；预留一个与实体数同量级
        // 的上限，避免多次 48 字节 Segment 数组拷贝。
        segments.reserveCapacity(min(max(document.entities.count, 1 << 16), 1_000_000))
        let viewScale = scale > 0 ? scale : 1

        // `Theme.aciColor` resolves a dynamic system colour and the packed
        // conversion goes through ColorSync; doing that per entity cost 7.8 s
        // on a 389k-entity layout. A drawing only uses a handful of ACI/RGB
        // pairs, so one dictionary lookup replaces the conversion.
        var colorCache: [UInt32: UInt32] = [:]
        colorCache.reserveCapacity(256)
        for entity in document.entities where entity.space == space {
            guard document.isLayerVisible(entity) else { continue }
            // A composed layout holds one projected copy of the model per
            // viewport, so a ten-sheet tab is ten drawings deep. Tessellating
            // all of them for every scale step is what made the rebuild too
            // expensive to run at all — the buffer then stayed at whatever
            // detail the fit-all view needed. Cull to the visible world rect
            // (plus margin) instead, exactly like the CG renderer's query.
            if !visible.isNull, !entity.box.isNull,
               !cadBoxesOverlap(entity.box, visible) {
                continue
            }
            // CadView.cpp culls anything thinner than `minimumScreenEdge`
            // (entityMinimumPixels * 0.75). Without it the fit-all view of a
            // ten-sheet layout spends its whole rebuild tessellating 389k
            // entities that land inside a single pixel.
            if !visible.isNull, !entity.box.isNull {
                let budget = 0.7 / viewScale
                if entity.box.width < budget && entity.box.height < budget {
                    continue
                }
            }
            let colorKey = UInt32(entity.aci) << 24 | entity.rgb
            let color: UInt32
            if let cached = colorCache[colorKey] {
                color = cached
            } else {
                color = packed(entity)
                colorCache[colorKey] = color
            }
            let width = showLineweights
                ? Float(Theme.lineWidth(entity.resolvedLineweight(layers: document.layers)))
                : 1.25
            let clip = clipVector(entity)
            let clipRect: CGRect? = entity.hasClip ? entity.clip : nil

            // The reference reader flattens circles, arcs and ellipses into
            // world-space point lists at import time; drawCadEntities() then
            // only ever strokes a polyline. Re-sampling them here from angles
            // is what used to put GPU arc endpoints somewhere else than the
            // CG path and the composed layout viewports.
            if (entity.kind == .circle || entity.kind == .arc || entity.kind == .ellipse)
                && entity.pcount >= 2 {
                appendPointList(entity, in: document, width: width, color: color,
                                clip: clip, clipRect: clipRect, scale: viewScale,
                                into: &segments)
                continue
            }

            switch entity.kind {
            case .line, .polyline:
                appendPointList(entity, in: document, width: width, color: color,
                                clip: clip, clipRect: clipRect, scale: viewScale,
                                into: &segments)
            case .circle:
                appendArc(&segments, cx: entity.cx, cy: entity.cy, r: entity.r,
                          from: 0, to: .pi * 2, width: width, color: color,
                          scale: viewScale, clip: clip)
            case .arc:
                var end = entity.a1
                while end < entity.a0 { end += 2 * .pi }
                appendArc(&segments, cx: entity.cx, cy: entity.cy, r: entity.r,
                          from: entity.a0, to: min(end, entity.a0 + 2 * .pi),
                          width: width, color: color, scale: viewScale, clip: clip)
            case .ellipse:
                appendEllipse(&segments, entity, width: width, color: color,
                              scale: viewScale, clip: clip)
            default:
                continue
            }
        }

        segmentCount = segments.count
        builtStrokeScale = viewScale
        builtVisibleRect = visible
        if ProcessInfo.processInfo.environment["CADLENS_FRAME_LOG"] != nil {
            print(String(format: "[segs] %d segments  scale=%.5g  %6.1f ms",
                         segmentCount, viewScale, (CACurrentMediaTime() - started) * 1000))
        }
        guard !segments.isEmpty else {
            segmentBuffer = nil
            return
        }
        segmentBuffer = device.makeBuffer(bytes: segments,
                                          length: MemoryLayout<Segment>.stride * segments.count,
                                          options: .storageModeShared)
    }

    /// The stroke buffer is tessellated for one camera scale. Zooming more than
    /// about half a step away from it leaves the chords visibly wrong: arcs
    /// flatten into their chords and small closed polylines collapse into a
    /// single diagonal, which reads as "the drawing is garbled".
    func needsStrokeRebuild(scale: CGFloat, visible: CGRect = .null) -> Bool {
        guard scale > 0, builtStrokeScale > 0, segmentCount > 0 else { return true }
        let ratio = scale / builtStrokeScale
        if ratio > 1.5 || ratio < 0.66 { return true }
        if !visible.isNull, !builtVisibleRect.isNull,
           !builtVisibleRect.contains(visible) {
            return true
        }
        return false
    }

    var hasStrokeGeometry: Bool { segmentCount > 0 }

    /// 只读：切布局回归自测用，确认几何是按新布局的 scale 重建的。
    var geometryBuiltScale: CGFloat { builtScale }

    /// 丢掉已经上传的全部几何。
    ///
    /// 渲染器活得比图纸长：关掉图纸后 `document` 变成 nil，`build` 直接
    /// 返回，`segmentBuffer` 里那张图的线段却还在——`present` 每帧照旧把
    /// 它画出来，于是空画布上留着一整张"残影"。关图、换图之前必须显式清
    /// 一次，把缓冲和"已构建"的标记一起复位，否则下一次 `needsRebuild`
    /// 还会以为当前的缓冲有效。
    func clear() {
        segmentBuffer = nil
        segmentCount = 0
        builtStrokeScale = 0
        builtVisibleRect = .null
        textBuffer = nil
        textCount = 0
        textGroups = []
        builtScale = 0
        builtPixelScale = 0
        hasTextGeometry = false
    }

    /// Uploads the import-time sampled geometry shared by polylines and every
    /// flattened curve. Closed point lists get their closing edge here, and
    /// viewport clip rectangles are applied per segment exactly as in the CG
    /// renderer.
    private func appendPointList(_ entity: Entity, in document: CadDocument,
                                 width: Float, color: UInt32, clip: SIMD4<Float>,
                                 clipRect: CGRect?, scale: CGFloat,
                                 into segments: inout [Segment]) {
        let points = document.points(for: entity)
        guard points.count >= 2 else { return }
        // 90% 的图元就是两点直线：跳过 RDP 容差循环和索引运算。
        if points.count == 2 {
            emitSegment(points[points.startIndex], points[points.index(after: points.startIndex)],
                        width: width, color: color, clip: clip, clipRect: clipRect,
                        into: &segments)
            return
        }
        // Import-time π/24 sampling (7.5° per chord) is the real accuracy
        // ceiling, so the tolerance only has to be tight enough not to throw
        // those samples away. At 0.35 px a small quarter arc collapsed to two
        // chords — mathematically inside the tolerance, but on screen it reads
        // as a slash instead of a door swing. 0.15 px keeps the import samples
        // for everything that is actually visible.
        let tolerance = Self.lodDisabled ? 0 : 0.15 / max(scale, 1e-9)
        // A composed layout reaches 8.3 million sample points across its
        // viewport copies. cadSimplify() runs RDP (several passes plus an
        // allocating copy of each entity) and took 7.5 s per rebuild, which is
        // why the buffer could never follow the camera. A single greedy pass
        // over the slice keeps the same 0.35 px error bound — every emitted
        // chord has its skipped samples inside the tolerance band — and needs
        // no intermediate storage.
        let end = points.endIndex
        let last = points.index(before: end)
        var anchor = points.startIndex
        var index = points.index(after: anchor)
        if tolerance <= 0 {
            while index < end {
                emitSegment(points[points.index(before: index)], points[index],
                            width: width, color: color, clip: clip, clipRect: clipRect,
                            into: &segments)
                index = points.index(after: index)
            }
            return
        }
        let toleranceSquared = tolerance * tolerance
        while index < end {
            guard index > points.index(after: anchor) else {
                index = points.index(after: index)
                continue
            }
            let point = points[index]
            let previous = points[points.index(before: index)]
            let ax = points[anchor].x, ay = points[anchor].y
            let bx = previous.x - ax, by = previous.y - ay
            let lengthSquared = bx * bx + by * by
            var deviation = 0.0
            if lengthSquared > 1e-12 {
                let px = point.x - ax, py = point.y - ay
                var t = (px * bx + py * by) / lengthSquared
                t = max(0, min(1, t))
                let ex = point.x - (ax + t * bx)
                let ey = point.y - (ay + t * by)
                deviation = ex * ex + ey * ey
            }
            if deviation <= toleranceSquared {
                index = points.index(after: index)
                continue
            }
            // Emit up to the previous sample and restart the walk there: the
            // violating sample then gets tested against the new anchor, so a
            // corner is never cut and a long straight run stays one segment.
            emitSegment(points[anchor], previous, width: width, color: color,
                        clip: clip, clipRect: clipRect, into: &segments)
            anchor = points.index(before: index)
        }
        emitSegment(points[anchor], points[last], width: width, color: color,
                    clip: clip, clipRect: clipRect, into: &segments)
        if entity.isClosed, points.count > 2 {
            emitSegment(points[last], points[points.startIndex], width: width,
                        color: color, clip: clip, clipRect: clipRect,
                        into: &segments)
        }
    }

    private func emitSegment(_ a: CGPoint, _ b: CGPoint, width: Float, color: UInt32,
                             clip: SIMD4<Float>, clipRect: CGRect?,
                             into segments: inout [Segment]) {
        guard clipAllows(a, b, clipRect) else { return }
        segments.append(Segment(p0: SIMD2(Float(a.x), Float(a.y)),
                                p1: SIMD2(Float(b.x), Float(b.y)),
                                width: width, color: color, clip: clip))
    }

    private func appendArc(_ segments: inout [Segment], cx: Double, cy: Double, r: Double,
                           from a0: Double, to a1: Double, width: Float, color: UInt32,
                           scale: CGFloat, clip: SIMD4<Float>) {
        guard r > 1e-9, a1 > a0 else { return }
        let span = a1 - a0
        // Roughly one segment per four pixels of arc; capped so a huge radius
        // still stops somewhere.
        let radiusPixels = r * Double(scale)
        let steps = max(4, min(384, Int((radiusPixels * span / 4).rounded(.up))))
        var previous = SIMD2<Float>(Float(cx + r * cos(a0)), Float(cy + r * sin(a0)))
        for i in 1...steps {
            let angle = a0 + span * Double(i) / Double(steps)
            let current = SIMD2<Float>(Float(cx + r * cos(angle)), Float(cy + r * sin(angle)))
            segments.append(Segment(p0: previous, p1: current, width: width,
                                    color: color, clip: clip))
            previous = current
        }
    }

    private func appendEllipse(_ segments: inout [Segment], _ entity: Entity,
                               width: Float, color: UInt32, scale: CGFloat,
                               clip: SIMD4<Float>) {
        let major = (entity.mx * entity.mx + entity.my * entity.my).squareRoot()
        guard major > 1e-9 else { return }
        let minor = major * entity.ratio
        let rotation = atan2(entity.my, entity.mx)
        let span = entity.a1 - entity.a0
        let pixels = major * Double(scale) * abs(span)
        let steps = max(8, min(256, Int((pixels / 4).rounded(.up))))
        var previous: SIMD2<Float>?
        for i in 0...steps {
            let t = entity.a0 + span * Double(i) / Double(steps)
            let x = major * cos(t), y = minor * sin(t)
            let p = SIMD2<Float>(Float(entity.cx + x * cos(rotation) - y * sin(rotation)),
                                 Float(entity.cy + x * sin(rotation) + y * cos(rotation)))
            if let previous { segments.append(Segment(p0: previous, p1: p, width: width,
                                                      color: color, clip: clip)) }
            previous = p
        }
    }

    /// True when the glyph atlas would have to be rebuilt for this camera.
    func needsRebuild(scale: CGFloat, pixelScale: CGFloat) -> Bool {
        guard hasTextGeometry else { return true }
        guard scale > 0, builtScale > 0 else { return true }
        if abs(pixelScale - builtPixelScale) > 0.01 { return true }
        let ratio = scale / builtScale
        // Wide hysteresis: curve tessellation and glyph rasters stay usable
        // until the view is stretched by more than a third, and rebuilding in
        // the middle of a zoom gesture costs more than it is worth.
        return ratio > 1.34 || ratio < 0.72
    }

    /// Lays out every label in the space into glyph quads. Runs only when the
    /// camera scale changed enough to matter, never per frame.
    func buildText(document: CadDocument, space: Int32, scale: CGFloat,
                   pixelScale: CGFloat, quality: Int = 1) {
        builtScale = scale
        builtPixelScale = pixelScale
        hasTextGeometry = true

        var quads: [TextQuad] = []
        quads.reserveCapacity(4096)
        guard scale > 0 else {
            textCount = 0
            textGroups = []
            textBuffer = nil
            return
        }

        // Reference CadView.cpp::drawCadEntities quality tiers: labels are kept
        // down to 0.45/0.70/1.50 logical pixels, ranked by on-screen height and
        // capped by a budget. The old 5.5 physical-pixel cutoff erased most
        // door/window numbers on a fitted sheet and made layout viewports look
        // empty even though the model tab had the same text.
        let minimumPixels: CGFloat = quality >= 2 ? 0.45 : quality == 1 ? 0.70 : 1.50
        let textLimit = quality >= 2 ? 5000 : quality == 1 ? 4000 : 2200
        var candidates: [(Entity, CGFloat)] = []
        candidates.reserveCapacity(4096)
        for entity in document.entities where entity.space == space {
            guard entity.kind == .text, !entity.text.isEmpty,
                  document.isLayerVisible(entity) else { continue }
            let logicalHeight = entity.h * scale
            guard logicalHeight >= minimumPixels, logicalHeight <= 4000 else { continue }
            candidates.append((entity, logicalHeight))
        }
        candidates.sort { $0.1 > $1.1 }
        if candidates.count > textLimit { candidates.removeSubrange(textLimit...) }

        for (entity, _) in candidates {
            let clip = clipVector(entity)
            let pixelHeight = entity.h * scale * pixelScale

            let fontSize = CGFloat(entity.h)
            guard fontSize > 1e-9 else { continue }
            let bucket = GlyphAtlas.bucket(for: pixelHeight)
            // Pixels of raster to world units.
            let unit = fontSize / CGFloat(bucket)
            let widthFactor = abs(entity.ws) > 0.01 ? CGFloat(entity.ws) : 1
            let rotation = CGFloat(entity.rot)
            let cosR = cos(rotation), sinR = sin(rotation)
            let color = packed(entity)
            let centerX = CGFloat(entity.cx), centerY = CGFloat(entity.cy)

            let lines = entity.text.components(separatedBy: "\n")
            // Same 1.2 em spacing and full-block justification used by the CG
            // text pass; the two renderers must agree on where a label sits.
            let lineHeight = fontSize * 1.2
            let first = atlas.line(lines[0])
            let ascent = first.ascent * fontSize
            let blockHeight = CGFloat(lines.count - 1) * lineHeight
                + (first.ascent + first.descent) * fontSize

            var baseline: CGFloat
            switch entity.valign {
            case 1: baseline = blockHeight - ascent
            case 2: baseline = blockHeight * 0.5 - ascent
            case 3: baseline = -ascent
            default: baseline = 0
            }

            for (index, text) in lines.enumerated() {
                let line = atlas.line(text)
                guard !line.items.isEmpty else { continue }
                let lineWidth = line.width * fontSize * widthFactor
                var startX: CGFloat
                switch entity.halign {
                case 1: startX = -lineWidth * 0.5
                case 2: startX = -lineWidth
                default: startX = 0
                }
                let baseY = baseline - CGFloat(index) * lineHeight

                for item in line.items {
                    let entry = atlas.entry(font: item.font, size: bucket, glyph: item.glyph)
                    guard entry.page >= 0 else { continue }
                    // Run positions are absolute along the line, not advances.
                    let penX = startX + item.x * fontSize * widthFactor
                    let x0 = penX + CGFloat(entry.bearing.x) * unit * widthFactor
                    let y0 = baseY + CGFloat(entry.bearing.y) * unit
                    let quadWidth = CGFloat(entry.size.x) * unit * widthFactor
                    let quadHeight = CGFloat(entry.size.y) * unit

                    // World-space footprint of the raster, rotated about the
                    // insertion point.
                    let localX = centerX + x0 * cosR - y0 * sinR
                    let localY = centerY + x0 * sinR + y0 * cosR
                    quads.append(TextQuad(
                        uv: entry.uv,
                        p0: SIMD2(Float(localX), Float(localY)),
                        dx: SIMD2(Float(quadWidth * cosR), Float(quadWidth * sinR)),
                        dy: SIMD2(Float(-quadHeight * sinR), Float(quadHeight * cosR)),
                        color: color,
                        page: UInt32(entry.page),
                        clip: clip))
                }
            }
        }

        textCount = quads.count
        guard !quads.isEmpty else {
            textBuffer = nil
            textGroups = []
            return
        }
        quads.sort { $0.page < $1.page }

        textGroups.removeAll(keepingCapacity: true)
        var start = 0
        var page = quads[0].page
        for i in 1...quads.count {
            if i == quads.count || quads[i].page != page {
                textGroups.append(TextGroup(page: Int(page), start: start, count: i - start))
                if i < quads.count {
                    start = i
                    page = quads[i].page
                }
            }
        }
        textBuffer = device.makeBuffer(bytes: quads,
                                       length: MemoryLayout<TextQuad>.stride * quads.count,
                                       options: .storageModeShared)
    }

    // MARK: Draw

    func draw(layer: CAMetalLayer, transform: ViewTransform, viewSize: CGSize,
              pixelScale: CGFloat) {
        lastDrawableWaitMS = 0
        guard isAvailable, viewSize.width > 1, viewSize.height > 1 else { return }
        let waitedFrom = CACurrentMediaTime()
        guard let drawable = prepareDrawable(layer: layer, viewSize: viewSize,
                                             pixelScale: pixelScale) else { return }
        lastDrawableWaitMS = (CACurrentMediaTime() - waitedFrom) * 1000

        let drawableSize = CGSize(width: viewSize.width * pixelScale,
                                  height: viewSize.height * pixelScale)
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        // The GPU layer sits ABOVE the hatch/paper layer. Clearing to an
        // opaque canvas colour would hide every SOLID, hatch and PDF page
        // underneath and leave the drawing as a bare wireframe. Clear to
        // premultiplied transparent instead; HatchView owns the background.
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0, green: 0, blue: 0, alpha: 0)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        encode(encoder, transform: transform, drawableSize: drawableSize,
               pixelScale: pixelScale)

        encoder.endEncoding()
        if ProcessInfo.processInfo.environment["CADLENS_FRAME_LOG"] != nil {
            let queued = CACurrentMediaTime()
            let segments = segmentCount
            let quads = textCount
            commandBuffer.addCompletedHandler { buffer in
                let gpu = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
                let latency = (CACurrentMediaTime() - queued) * 1000
                print(String(format: "[gpu]  %6.2f ms  gpu %6.2f ms  segments=%d quads=%d",
                             latency, gpu, segments, quads))
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func encode(_ encoder: MTLRenderCommandEncoder, transform: ViewTransform,
                        drawableSize: CGSize, pixelScale: CGFloat) {
        var uniforms = Uniforms(origin: SIMD2(Float(transform.origin.x),
                                              Float(transform.origin.y)),
                                viewport: SIMD2(Float(drawableSize.width),
                                                Float(drawableSize.height)),
                                scale: Float(transform.scale * pixelScale),
                                hairline: Float(max(1.0, pixelScale * 0.6)),
                                pixelScale: Float(pixelScale))

        if let buffer = segmentBuffer, segmentCount > 0 {
            encoder.setRenderPipelineState(linePipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: segmentCount)
        }

        if let buffer = textBuffer, textCount > 0, !textGroups.isEmpty {
            encoder.setRenderPipelineState(textPipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            let stride = MemoryLayout<TextQuad>.stride
            for group in textGroups where group.page < atlas.pages.count {
                encoder.setVertexBuffer(buffer, offset: group.start * stride, index: 0)
                encoder.setFragmentTexture(atlas.pages[group.page], index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                       instanceCount: group.count)
            }
        }
    }

    /// Renders one frame offscreen and hands back an image. Used by the export
    /// paths and the scripted screenshot harness, neither of which can read a
    /// CAMetalLayer back through the window server.
    func snapshot(viewSize: CGSize, transform: ViewTransform,
                  pixelScale: CGFloat) -> CGImage? {
        guard isAvailable, viewSize.width > 1, viewSize.height > 1 else { return nil }
        let width = Int((viewSize.width * pixelScale).rounded())
        let height = Int((viewSize.height * pixelScale).rounded())
        guard width > 1, height > 1 else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        guard let target = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        // Transparent so the image can be composited over the Core Graphics
        // pass, which owns the background, the hatches and the annotations.
        // Premultiplied: a transparent pixel must be black, not the paper
        // colour, or it would paint over everything underneath it.
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0,
                                                            blue: 0, alpha: 0)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        else { return nil }
        encode(encoder, transform: transform,
               drawableSize: CGSize(width: width, height: height), pixelScale: pixelScale)
        encoder.endEncoding()
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: target)
            blit.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: width * 4,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: colorSpace, bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    private func prepareDrawable(layer: CAMetalLayer, viewSize: CGSize,
                                 pixelScale: CGFloat) -> CAMetalDrawable? {
        let drawableSize = CGSize(width: viewSize.width * pixelScale,
                                  height: viewSize.height * pixelScale)
        if layer.drawableSize != drawableSize {
            layer.drawableSize = drawableSize
        }
        return layer.nextDrawable()
    }
}

/// Hosts the Metal layer underneath the Core Graphics overlay.
final class MetalCanvasView: NSView {
    let renderer = MetalCanvasRenderer()
    private var metalLayer: CAMetalLayer?

    /// Milliseconds the last frame spent blocked inside `nextDrawable()`, i.e.
    /// waiting for a free drawable from the swap chain. Reported per frame so a
    /// "slow" interaction frame can be told apart from a GPU-bound one.
    private(set) var lastDrawableWaitMS = 0.0
    /// Milliseconds the last frame spent encoding draw commands.
    private(set) var lastEncodeMS = 0.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = makeBackingLayer()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        // Transparent so the hatch/paper layer below stays visible.
        metalLayer.isOpaque = false
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2
        self.metalLayer = metalLayer
        return metalLayer
    }

    func present(transform: ViewTransform) {
        guard let metalLayer, let renderer else { return }
        let pixelScale = window?.backingScaleFactor ?? 2
        // Assigning `contentsScale` opens a new CALayer transaction every time;
        // it only ever changes when the window moves between displays.
        if metalLayer.contentsScale != pixelScale {
            metalLayer.contentsScale = pixelScale
        }
        let started = CACurrentMediaTime()
        renderer.draw(layer: metalLayer, transform: transform, viewSize: bounds.size,
                      pixelScale: pixelScale)
        lastDrawableWaitMS = renderer.lastDrawableWaitMS
        lastEncodeMS = (CACurrentMediaTime() - started) * 1000 - lastDrawableWaitMS
    }
}
