import AppKit
import CoreText

struct ViewTransform: Equatable {
    var origin: CGPoint = .zero
    var scale: CGFloat = 1

    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - origin.x) * scale, y: (p.y - origin.y) * scale)
    }

    func toWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + p.x / scale, y: origin.y + p.y / scale)
    }

    func worldRect(_ viewRect: CGRect) -> CGRect {
        CGRect(x: origin.x + viewRect.minX / scale,
               y: origin.y + viewRect.minY / scale,
               width: viewRect.width / scale,
               height: viewRect.height / scale)
    }
}

/// Batched Core Graphics renderer. Entities sharing colour and line weight are
/// merged into a single path so a dense tile costs a handful of strokes rather
/// than one draw call per entity.
final class CadRenderer {
    struct Options {
        var showLineweights = true
        var quality = 1
        /// Reference CadView.cpp::entityMinimumPixels: 0.02 (High), 0.04
        /// (Balanced), 0.08 (Performance). The old 0.55 dropped every door
        /// swing, fixture and dimension tick smaller than half a pixel, which
        /// reads as a sparse, hole-riddled sheet.
        var minimumPixels: CGFloat = 0.04
        /// Strokes can be handed to the GPU pass; the Core Graphics pass then
        /// only paints hatches and text on top.
        var drawLines = true
        var drawOverlay = true
        /// Labels can be handed to the glyph atlas on the GPU pass; the Core
        /// Graphics pass then only paints hatches.
        var drawText = true
        /// Hatches live on their own layer below the GPU pass so a filled wall
        /// never covers the labels drawn on top of it.
        var drawHatches = true

        /// World units that correspond to one screen point. Line weights are
        /// authored in points, so they must be divided by this before being
        /// applied in the (world space) drawing context.
        var lineWidthScale: CGFloat = 1

        /// Multiplies every pen width. The on-screen pass keeps 1; it exists so
        /// export and diagnostics can request heavier ink, and so the stroke
        /// cost can be measured against a fixed geometry.
        var lineWidthMultiplier: CGFloat = 1

        /// Reference CadView.cpp::drawCadEntities quality tiers. A 6 px cutoff
        /// silently erased every dimension and door number on a fitted sheet;
        /// the product draws labels down to ~1 px and caps the count instead.
        var minimumTextPixels: CGFloat {
            quality >= 2 ? 0.45 : quality == 1 ? 0.70 : 1.50
        }
        var textLimit: Int {
            quality >= 2 ? 5000 : quality == 1 ? 4000 : 2200
        }
    }

    private unowned let document: CadDocument
    private var colorCache: [UInt32: NSColor] = [:]

    /// World-space HATCH pattern segments. The reference generates these once
    /// per group in drawing coordinates (CadView.cpp::hatchPatternLinesForGroup)
    /// and reuses them for pan, zoom and cached interaction frames; generating
    /// them in screen space makes the pattern density jump during a gesture.
    private struct HatchSegment {
        let p0: CGPoint, p1: CGPoint
        let isDot: Bool
    }
    private var hatchLineCache: [Int: [HatchSegment]] = [:]

    // MARK: Per-frame reuse
    //
    // Everything below exists because a CAD viewer re-renders on every pan and
    // zoom tick. Building a CGPath out of entity data is not free — on a
    // 189 k-entity sheet it was 136 ms per frame for strokes and 447 ms for
    // labels — yet the result only depends on the entity, never on the camera
    // (except for polyline simplification, which is why the geometry cache is
    // keyed by LOD bucket). Caching turns those two passes into a lookup plus
    // an element copy.

    /// Local-space pen path per text entity. Scale-independent: the camera is
    /// applied by the context, not baked into the path.
    private var textPathCache: [Int32: CGPath] = [:]
    /// World-space version of the same path, placement baked in.
    private var textWorldCache: [Int32: CGPath] = [:]
    /// Text entities whose string has no SHX coverage; remembered so the
    /// fallback decision is not re-made for every frame.
    private var textNotDrawable: Set<Int32> = []
    /// World-space path per entity, valid for `geometryBucket` only.
    private var geometryCache: [Int32: CGPath] = [:]
    /// Quarter-octave bucket of log2(scale). Polylines are simplified to a
    /// 0.35 px tolerance, so geometry may only be reused while the bucket
    /// holds; eight steps per octave keeps the tolerance within 4.4 %, well
    /// below one screen pixel.
    private var geometryBucket = Int.min
    private var lastTextCount = 0
    /// Per-frame tally of which text path was used, for CADLENS_PROFILE.
    private var shxDrawn = 0
    private var faceDrawn = 0
    /// Geometry-cache accounting, for CADLENS_PROFILE only.
    private var geometryHits = 0
    private var geometryMisses = 0

    init(document: CadDocument) {
        self.document = document
    }

    private func color(rgb: UInt32, aci: UInt8) -> NSColor {
        let key = UInt32(aci) << 24 | rgb
        if let cached = colorCache[key] { return cached }
        let value = Theme.aciColor(aci, rgb: rgb)
        colorCache[key] = value
        return value
    }

    struct StyleKey: Hashable {
        var colorBits: UInt32
        var width: Int16
    }

    /// Quantised paper-space viewport clip, used as a grouping key so each
    /// viewport's projected copies are rasterised under their own CG clip.
    private struct ClipKey: Hashable {
        let a: Int, b: Int, c: Int, d: Int
        let enabled: Bool
        init(_ rect: CGRect) {
            enabled = rect.width > 0 && rect.height > 0
            a = enabled ? Int((rect.minX * 1000).rounded()) : 0
            b = enabled ? Int((rect.minY * 1000).rounded()) : 0
            c = enabled ? Int((rect.maxX * 1000).rounded()) : 0
            d = enabled ? Int((rect.maxY * 1000).rounded()) : 0
        }
        var rect: CGRect? {
            guard enabled else { return nil }
            return CGRect(x: Double(a) / 1000, y: Double(b) / 1000,
                          width: Double(c - a) / 1000, height: Double(d - b) / 1000)
        }
    }

    func draw(entities indices: [Int32], space: Int32, in ctx: CGContext,
              worldRect: CGRect, scale: CGFloat, options: Options) {
        guard scale > 0 else { return }
        // Every drawing pass goes through here — the on-screen CG layer, the
        // headless/export contexts and the hatch compositor — so anti-aliasing
        // is switched on once, for all of them. Without it a hairline stroke
        // falls on a single pixel row and breaks up into dashes, and every
        // circle/arc edge shows staircase steps.
        let antialias = getenv("CADLENS_NO_AA") == nil
        ctx.setShouldAntialias(antialias)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldSmoothFonts(true)
        ctx.interpolationQuality = .high
        // Fast path: the model tab and paper-only drawings have no clipped
        // entities, so skip the grouping pass entirely (it is O(entities) on
        // a hot path that HatchView re-runs whenever its cache is rebuilt).
        var hasClip = false
        for index in indices {
            let i = Int(index)
            if i >= 0, i < document.entities.count,
               document.entities[i].space == space, document.entities[i].hasClip {
                hasClip = true
                break
            }
        }
        if !hasClip {
            drawBody(indices, space: space, in: ctx, worldRect: worldRect,
                     scale: scale, options: options)
            return
        }
        // A composed layout carries one clip rect per viewport. Grouping by it
        // keeps fills, strokes, hatch patterns and labels inside their window
        // instead of leaking onto neighbouring sheets.
        var groups: [ClipKey: [Int32]] = [:]
        for index in indices {
            let i = Int(index)
            guard i >= 0, i < document.entities.count else { continue }
            let entity = document.entities[i]
            guard entity.space == space else { continue }
            groups[ClipKey(entity.clip), default: []].append(index)
        }
        for (key, group) in groups {
            ctx.saveGState()
            if let rect = key.rect { ctx.clip(to: rect) }
            drawBody(group, space: space, in: ctx, worldRect: worldRect,
                     scale: scale, options: options)
            ctx.restoreGState()
        }
    }

    private func drawBody(_ indices: [Int32], space: Int32, in ctx: CGContext,
                         worldRect: CGRect, scale: CGFloat, options: Options) {
        // Stage timer, off unless CADLENS_PROFILE is set. Kept in the shipping
        // code because "which pass ate the frame" is the first question every
        // time a drawing feels slow, and re-adding it costs an hour.
        let profiling = ProcessInfo.processInfo.environment["CADLENS_PROFILE"] != nil
        var stamp = CACurrentMediaTime()
        var phase = [String: Double]()
        func mark(_ name: String) {
            guard profiling else { return }
            let now = CACurrentMediaTime()
            phase[name, default: 0] += (now - stamp) * 1000
            stamp = now
        }
        var strokePaths: [StyleKey: CGMutablePath] = [:]
        var textEntities: [Int32] = []
        var hatchEntities: [Int32] = []
        // One fill per area, never merged by colour. CadView.cpp::paintHatches
        // fills each hatch group separately, and a SOLID is drawn with its own
        // brush. Merging two independent areas into one even-odd/winding path
        // makes their overlapping regions cancel out — the "islands are wrong
        // / walls full of holes / fills look ragged" defect. Only the boundary
        // and island loops of the SAME hatch may share one fill rule.
        struct FillWork {
            let path: CGMutablePath
            let solid: Bool
            let rule: CGPathFillRule
            let color: NSColor
        }
        var fills: [FillWork] = []
        let minimum = options.minimumPixels / scale
        // A change of LOD bucket invalidates every simplified polyline; keep
        // the storage but drop the contents so the next frame refills it.
        let bucket = Int((log2(max(scale, 1e-9)) * 8).rounded())
        if bucket != geometryBucket {
            geometryBucket = bucket
            geometryCache.removeAll(keepingCapacity: true)
        }
        var omittedSmall = 0, omittedOutside = 0, omittedHidden = 0, drawnPoints = 0
        shxDrawn = 0
        faceDrawn = 0
        geometryHits = 0
        geometryMisses = 0

        // Pass 1: bucket geometry.
        for index in indices where options.drawLines
            || document.entities[Int(index)].kind == .text
            || document.entities[Int(index)].kind == .hatch
            || document.entities[Int(index)].kind == .solid {
            let entity = document.entities[Int(index)]
            guard entity.space == space else { continue }
            // Model space draws EVERY layer: CadView::drawCadEntities never
            // consults layer visibility, only the per-entity invisible flag
            // (already dropped at import). Filtering by layer here made every
            // switched-off / frozen layer vanish from the model tab — whole
            // walls, furniture and dimension lines were missing. Layouts keep
            // the check, because a paper space viewport really does hide the
            // layers it was frozen on (CadView.cpp composeLayoutContent).
            guard entity.flags & EntityFlags.invisible == 0 else {
                omittedHidden += 1
                continue
            }
            if space != 0, !document.isLayerVisible(entity) {
                omittedHidden += 1
                continue
            }
            if entity.kind == .text {
                if options.drawText { textEntities.append(index) }
                continue
            }
            if entity.kind == .hatch {
                if options.drawHatches { hatchEntities.append(index) }
                continue
            }
            // SOLID / TRACE / 3DFACE: the reference always outlines the
            // polygon and fills it only when the filled flag is set
            // (`entity.filled ? brush : NoBrush`). Keeping one fill per solid
            // also stops a reversed vertex order from punching a hole in a
            // same-coloured neighbour.
            if entity.kind == .solid {
                let ink = color(rgb: entity.rgb, aci: entity.aci)
                if entity.flags & EntityFlags.filled != 0 {
                    let fillPath = CGMutablePath()
                    append(entity: entity, to: fillPath, scale: scale)
                    fills.append(FillWork(path: fillPath, solid: true,
                                          rule: .winding, color: ink))
                }
                let width = options.showLineweights
                    ? Int16(clamping: Int((Theme.lineWidth(
                        entity.resolvedLineweight(layers: document.layers)) * 20).rounded()))
                    : 20
                let key = StyleKey(colorBits: UInt32(entity.aci) << 24 | entity.rgb,
                                   width: width)
                let path = strokePaths[key] ?? CGMutablePath()
                strokePaths[key] = path
                path.addPath(geometryPath(index: index, entity: entity, scale: scale))
                continue
            }

            let box = entity.box
            // A POINT carries a degenerate box (width and height are both 0),
            // so the sub-pixel filter would discard every single one of them —
            // this sheet has 1,393. They are drawn at a fixed screen radius, so
            // their world extent says nothing about whether they are visible.
            if entity.kind != .point,
               box.width < minimum && box.height < minimum {
                omittedSmall += 1
                continue
            }
            if entity.kind == .point { drawnPoints += 1 }
            if !cadBoxesOverlap(box, worldRect) && !(entity.kind == .circle || entity.kind == .arc) {
                omittedOutside += 1
                continue
            }

            // Keep 1/20 px precision in the batching key, like the reference's
            // `int(lineWidth * 20)` — an integer point width erased the
            // difference between the 0.05..2.11 mm grades.
            let width = options.showLineweights
                ? Int16(clamping: Int((Theme.lineWidth(
                    entity.resolvedLineweight(layers: document.layers)) * 20).rounded()))
                : 20
            let key = StyleKey(colorBits: UInt32(entity.aci) << 24 | entity.rgb, width: width)
            let path = strokePaths[key] ?? CGMutablePath()
            strokePaths[key] = path
            path.addPath(geometryPath(index: index, entity: entity, scale: scale))
        }

        // Pass 2 setup. Strokes are deferred until after the fills: the
        // reference paints hatches first and then draws every line batch on
        // top (CadView.cpp::drawCadEntities), so an opaque fill can never hide
        // the wall outline or the pattern it belongs to.
        mark("bucket")
        let pointScale = max(options.lineWidthScale, 1e-9)

        ctx.setLineCap(.butt)
        // Miter joins are what a CAD plot looks like at corners, but Core
        // Graphics pays for them per vertex: on a dense polyline a 2.5 px pen
        // costs 60x what a 1.25 px pen costs, because above the hairline path
        // it has to build a real stroke outline and intersect every miter.
        // CADLENS_JOIN exists to measure that cliff.
        switch getenv("CADLENS_JOIN").map({ String(cString: $0) }) {
        case "bevel": ctx.setLineJoin(.bevel)
        case "round": ctx.setLineJoin(.round)
        default: ctx.setLineJoin(.miter)
        }

        // Pass 3: hatches (clip + pattern), then text.
        // Pattern fills are the only raster-unfriendly part; while the user is
        // dragging, small hatches are dropped rather than redrawn every frame.
        var patternHatches: [(path: CGMutablePath, box: CGRect, hatch: HatchPattern,
                              key: Int, color: NSColor)] = []
        // `lineWidthScale` is the camera scale in world units per point, not a
        // quality flag: at a normal fit it is ~0.005 and the old 0.02 cutoff
        // silently discarded every hatch and SOLID on the sheet, leaving a
        // bare wireframe. Only an active low-quality gesture may drop fills,
        // and even then only ones that are truly sub-pixel on screen.
        let skipSmallHatches = options.quality == 0

        for index in hatchEntities {
            let entity = document.entities[Int(index)]
            let box = entity.box
            guard cadBoxesOverlap(box, worldRect) else { continue }
            guard let hatch = document.hatch(for: entity), !hatch.rings.isEmpty,
                  let path = hatchPath(hatch) else { continue }
            if skipSmallHatches, max(box.width, box.height) * scale < 6 { continue }

            // Reference: CadView.cpp::paintHatches. The pattern definition's
            // offset is already an absolute drawing-space vector (libdxfrw
            // folds group 41 scale / group 52 rotation into it), so it is used
            // verbatim — multiplying by hatch.scale here would double-scale it.
            // A pitch below 1.15 screen pixels becomes a flat tone.
            var minimumSpacingPx = Double.infinity
            for line in hatch.lines {
                let spacing = hypot(line.offset.x, line.offset.y) * scale
                if spacing > 1e-9 { minimumSpacingPx = min(minimumSpacingPx, spacing) }
            }
            let dense = hatch.lines.isEmpty || minimumSpacingPx < 1.15
            let ink = color(rgb: entity.rgb, aci: entity.aci)
            if hatch.solid || dense {
                // Style 0/1 (Normal/Outer) use odd-even parity so island
                // loops cut holes; style 2 (Ignore) uses winding so the fill
                // runs straight through them. Same rule as the reference.
                fills.append(FillWork(path: path,
                                      solid: hatch.solid,
                                      rule: hatch.style == 2 ? .winding : .evenOdd,
                                      color: ink))
            } else {
                patternHatches.append((path, box, hatch, Int(entity.hatch), ink))
            }
        }

        for work in fills {
            ctx.saveGState()
            // Solid HATCHes are opaque, like the reference. A translucent
            // fill stacked on another one reads as a dirty grey slab, and
            // double-blending is why the same wall looked different from
            // sheet to sheet. A pattern too fine to resolve collapses to the
            // same opaque canvas/ink tone the reference's patternTone() uses.
            let fillColor = work.solid ? work.color : patternTone(work.color)
            ctx.setFillColor(fillColor.cgColor)
            ctx.addPath(work.path)
            ctx.fillPath(using: work.rule)
            ctx.restoreGState()
        }
        mark("fills")

        // CadView.cpp::globalPatternBudget — one segment budget for the whole
        // frame, split evenly across the pattern groups, instead of a per-hatch
        // cap that multiplied out to tens of millions of segments.
        let patternBudgetPerGroup = max(512, 180_000 / max(1, patternHatches.count))
        for work in patternHatches {
            drawHatchPattern(work.path, box: work.box, hatch: work.hatch,
                             key: work.key, color: work.color,
                             ctx: ctx, worldRect: worldRect, scale: scale,
                             pointScale: pointScale,
                             budget: patternBudgetPerGroup)
        }
        // Pass 4: strokes on top of every fill, then labels.
        // Hairlines never disappear, and thick line weights stay proportional.
        mark("patterns")
        for (key, path) in strokePaths {
            let color = color(rgb: key.colorBits & 0xFFFFFF,
                              aci: UInt8((key.colorBits >> 24) & 0xFF))
            ctx.setStrokeColor(color.cgColor)
            // `key.width` is already the reference's screen-pixel ramp
            // (Theme.lineWidth = clamp(0.55 + mm * 1.35, 1, 4)) stored as
            // int(pixels * 20). Converting it back to world units by dividing
            // by the camera scale is what makes a weight zoom-invariant, the
            // way CadView::lineWidthPixels is.
            let pixels: CGFloat = options.showLineweights
                ? CGFloat(key.width) / 20
                : 1.25
            ctx.setLineWidth(max(pixels, 0.6) * options.lineWidthMultiplier / pointScale)
            ctx.addPath(path)
            ctx.strokePath()
        }
        mark("strokes")

        if ProcessInfo.processInfo.environment["CADLENS_HATCH_LOG"] != nil {
            print(String(format: "[hatch] entities=%d fills=%d patterns=%d",
                         hatchEntities.count, fills.count, patternHatches.count))
            print(String(format: "[draw] input=%d strokes=%zu texts=%d points=%d "
                         + "omittedSmall=%d omittedOutside=%d omittedHidden=%d",
                         indices.count, strokePaths.count, textEntities.count,
                         drawnPoints, omittedSmall, omittedOutside, omittedHidden))
        }
        // Reference: candidates are ranked by on-screen height and truncated to
        // a quality-dependent budget, so the largest/most readable labels
        // survive on a dense sheet instead of an arbitrary document-order cut.
        let ranked = textEntities.compactMap { index -> (Int32, CGFloat)? in
            let pixels = document.entities[Int(index)].h * scale
            guard pixels >= options.minimumTextPixels, pixels <= 4000 else { return nil }
            return (index, pixels)
        }.sorted { $0.1 > $1.1 }
        var faceLabels: [Int32] = []
        var textBatches: [StyleKey: CGMutablePath] = [:]
        for (index, _) in ranked.prefix(options.textLimit) {
            let entity = document.entities[Int(index)]
            // Same rule as the stroke pass above: model space ignores layer
            // visibility entirely (CadView::drawCadEntities only honours the
            // per-entity invisible flag). Checking it here hid every label on a
            // switched-off layer while the walls on that same layer still drew.
            if space != 0, !document.isLayerVisible(entity) { continue }
            if !cadBoxesOverlap(entity.box,
                                worldRect.insetBy(dx: -entity.box.width,
                                                  dy: -entity.box.height)) {
                continue
            }
            guard let world = textWorldPath(entity: entity, index: index) else {
                faceLabels.append(index)
                continue
            }
            // Same batching key as strokes: the pen width in 1/20 screen pixel.
            // Storing the path in world space lets every label that shares ink
            // and weight go down in ONE strokePath instead of one per label —
            // 3198 labels used to mean 3198 CG stroke setups per frame.
            let ink = UInt32(entity.aci) << 24 | entity.rgb
            let penPx = max(0.62, max(entity.h, 1e-6) * 0.02 * scale) * 20
            let key = StyleKey(colorBits: ink,
                               width: Int16(clamping: Int(penPx.rounded())))
            let batch = textBatches[key] ?? CGMutablePath()
            textBatches[key] = batch
            batch.addPath(world)
            shxDrawn += 1
        }
        if !textBatches.isEmpty {
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
        }
        for (key, path) in textBatches {
            ctx.setStrokeColor(color(rgb: key.colorBits & 0xFFFFFF,
                                     aci: UInt8((key.colorBits >> 24) & 0xFF)).cgColor)
            ctx.setLineWidth(CGFloat(key.width) / 20 / pointScale)
            ctx.addPath(path)
            ctx.strokePath()
        }
        for index in faceLabels {
            drawFaceText(entity: document.entities[Int(index)], ctx: ctx, scale: scale)
            faceDrawn += 1
        }
        mark("text")
        if profiling {
            let total = phase.values.reduce(0, +)
            print(String(format: "[prof] total=%.1fms  bucket=%.1f  fills=%.1f  "
                         + "patterns=%.1f  strokes=%.1f  text=%.1f  "
                         + "ents=%d/(%d) batches=%zu texts=%zu/%d(shx=%d face=%d) "
                         + "hatches=%zu scale=%.5g min=%.4g geo=%d/%d cache=%d inst=%d",
                         total, phase["bucket"] ?? 0, phase["fills"] ?? 0,
                         phase["patterns"] ?? 0, phase["strokes"] ?? 0,
                         phase["text"] ?? 0, indices.count,
                         document.entities.count,
                         strokePaths.count, ranked.count, textEntities.count,
                         shxDrawn, faceDrawn, hatchEntities.count,
                         scale, minimum, geometryHits, geometryMisses,
                         geometryCache.count,
                         ObjectIdentifier(self).hashValue % 10000))
        }
    }

    // MARK: Geometry

    /// Cached world-space outline for one entity. Valid for the current LOD
    /// bucket only; `drawBody` empties the table when the bucket changes.
    private func geometryPath(index: Int32, entity: Entity, scale: CGFloat) -> CGPath {
        if let cached = geometryCache[index] {
            geometryHits += 1
            return cached
        }
        geometryMisses += 1
        let path = CGMutablePath()
        append(entity: entity, to: path, scale: scale)
        // Bounded so a pathological sheet cannot grow the table without limit;
        // 400 k covers the densest drawing seen (189 k entities).
        if geometryCache.count < 400_000 { geometryCache[index] = path }
        return path
    }

    private func append(entity: Entity, to path: CGMutablePath, scale: CGFloat) {
        // The reference reader flattens CIRCLE / ARC / ELLIPSE into world-space
        // point lists at import time; drawCadEntities() only ever strokes a
        // polyline. Do the same so the CG path, the GPU path and the composed
        // layout viewports cannot disagree about where a curve ends. The
        // analytic branches below are a fallback only for samples-less data.
        if (entity.kind == .circle || entity.kind == .arc || entity.kind == .ellipse)
            && entity.pcount >= 2 {
            appendPointList(entity, to: path, scale: scale)
            return
        }
        switch entity.kind {
        case .line:
            let slice = document.points(for: entity)
            if slice.count >= 2 {
                path.move(to: slice[slice.startIndex])
                path.addLine(to: slice[slice.startIndex + 1])
            }
        case .polyline:
            appendPointList(entity, to: path, scale: scale)
        case .circle:
            path.addEllipse(in: CGRect(x: entity.cx - entity.r, y: entity.cy - entity.r,
                                       width: entity.r * 2, height: entity.r * 2))
        case .arc:
            // `addArc` joins the current point to the arc start, which would draw
            // a stray chord between unrelated entities sharing a style bucket.
            var end = entity.a1
            while end < entity.a0 { end += 2 * .pi }
            let sweep = min(end - entity.a0, 2 * .pi)
            path.move(to: CGPoint(x: entity.cx + entity.r * cos(entity.a0),
                                  y: entity.cy + entity.r * sin(entity.a0)))
            path.addArc(center: CGPoint(x: entity.cx, y: entity.cy), radius: entity.r,
                        startAngle: entity.a0, endAngle: entity.a0 + sweep,
                        clockwise: false)
        case .ellipse:
            appendEllipse(entity, to: path)
        case .solid:
            let slice = document.points(for: entity)
            guard slice.count >= 3 else { return }
            path.move(to: slice[slice.startIndex])
            for i in (slice.startIndex + 1)..<slice.endIndex { path.addLine(to: slice[i]) }
            path.closeSubpath()
        case .point:
            let r = max(1.5 / scale, 0.5)
            path.addEllipse(in: CGRect(x: entity.cx - r, y: entity.cy - r,
                                       width: r * 2, height: r * 2))
        default:
            break
        }
    }

    /// Strokes the import-time sampled geometry shared by polylines and every
    /// flattened curve. Screen-space decimation matches the GPU path, so a
    /// zoom gesture does not change which vertices survive.
    private func appendPointList(_ entity: Entity, to path: CGMutablePath,
                                 scale: CGFloat) {
        let raw = Array(document.points(for: entity))
        guard raw.count >= 2 else { return }
        let minimumStep = 0.35 / max(scale, 1e-9)
        // Same screen-space RDP as the GPU pass (reference:
        // simplifyScreenPolyline). Keeps the two renderers identical.
        let slice = cadSimplify(raw, tolerance: minimumStep, closed: entity.isClosed)
        guard slice.count >= 2 else { return }
        let minimumSquared = minimumStep * minimumStep
        path.move(to: slice[0])
        var last = slice[0]
        for i in 1..<slice.count {
            let point = slice[i]
            let dx = point.x - last.x, dy = point.y - last.y
            if dx * dx + dy * dy < minimumSquared { continue }
            path.addLine(to: point)
            last = point
        }
        let end = slice[slice.count - 1]
        if last != end { path.addLine(to: end) }
        if entity.isClosed { path.closeSubpath() }
    }

    private func appendEllipse(_ entity: Entity, to path: CGMutablePath) {
        let major = hypot(entity.mx, entity.my)
        guard major > 1e-9 else { return }
        let minor = major * entity.ratio
        let rotation = atan2(entity.my, entity.mx)
        let steps = max(24, min(96, Int(major * 40)))
        let span = entity.a1 - entity.a0
        let full = abs(span) < 1e-9 || abs(abs(span) - 2 * .pi) < 1e-6
        let count = full ? steps : max(6, Int(Double(steps) * abs(span) / (2 * .pi)))
        var first = true
        for i in 0...count {
            let t = entity.a0 + span * Double(i) / Double(count)
            let x = major * cos(t)
            let y = minor * sin(t)
            let p = CGPoint(x: entity.cx + x * cos(rotation) - y * sin(rotation),
                            y: entity.cy + x * sin(rotation) + y * cos(rotation))
            if first { path.move(to: p); first = false } else { path.addLine(to: p) }
        }
        if full { path.closeSubpath() }
    }

    /// CadView.cpp::patternTone — a hatch whose pattern pitch falls below one
    /// screen pixel collapses to an opaque 32% ink / canvas mix. The old code
    /// stacked a 32%-alpha fill instead, which double-blends wherever fills
    /// overlap and shows up as grey blocks.
    private func patternTone(_ ink: NSColor) -> NSColor {
        let canvas = Theme.canvasBackground.usingColorSpace(.sRGB)
        let rgb = ink.usingColorSpace(.sRGB) ?? ink
        guard let base = canvas else { return rgb }
        let coverage: CGFloat = 0.32
        return NSColor(
            srgbRed: base.redComponent * (1 - coverage) + rgb.redComponent * coverage,
            green: base.greenComponent * (1 - coverage) + rgb.greenComponent * coverage,
            blue: base.blueComponent * (1 - coverage) + rgb.blueComponent * coverage,
            alpha: 1)
    }

    /// Boundary loops of a hatch, in world coordinates.
    private func hatchPath(_ hatch: HatchPattern) -> CGMutablePath? {
        let path = CGMutablePath()
        var added = false
        // Only closed boundary loops take part in the fill, exactly like
        // CadView.cpp::hatchPathForGroup (open boundaries are never filled)
        // and a loop needs three vertices to enclose an area.
        for ring in hatch.rings where ring.closed {
            let start = Int(ring.pstart)
            let end = min(start + Int(ring.pcount), document.points.count)
            guard end - start >= 3 else { continue }
            path.move(to: document.points[start])
            for i in (start + 1)..<end { path.addLine(to: document.points[i]) }
            path.closeSubpath()
            added = true
        }
        return added ? path : nil
    }

    /// CadView.cpp::appendHatchPatternLine / hatchPatternLinesForGroup.
    /// Pattern lines are laid out in world coordinates from the definition's
    /// base point and offset vector — never re-anchored to the centre of the
    /// visible region. That keeps the hatch phase fixed under pan/zoom and
    /// makes dash phases, multiple line families and islands line up with the
    /// drawing instead of with the camera.
    private func hatchPatternSegments(_ hatch: HatchPattern, bounds: CGRect,
                                      key: Int) -> [HatchSegment] {
        if let cached = hatchLineCache[key] { return cached }
        var result: [HatchSegment] = []
        let extent = max(bounds.width, bounds.height, 1.0)
        let tolerance = max(1e-12, extent * 2e-11)
        let box = bounds.insetBy(dx: -tolerance, dy: -tolerance)
        // CadView.cpp shares ONE global pattern budget across every hatch group
        // and hands each group a fair share (globalPatternBudget / groups,
        // 60000..180000 total). The old per-hatch 60000 let a single dense fill
        // emit more segments than the whole reference frame: 566 hatches then
        // meant tens of millions of segments and a frozen canvas. Cache a
        // bounded set per hatch and let the caller take its fair slice; 2048
        // was too small and truncated every architectural hatch into a handful
        // of widely spaced lines instead of the dense pattern in the source.
        let budget = 6000
        let corners = [CGPoint(x: box.minX, y: box.minY),
                       CGPoint(x: box.maxX, y: box.minY),
                       CGPoint(x: box.maxX, y: box.maxY),
                       CGPoint(x: box.minX, y: box.maxY)]

        for line in hatch.lines {
            let unit = CGPoint(x: cos(line.angle), y: sin(line.angle))
            let normal = CGPoint(x: -unit.y, y: unit.x)
            let offset = line.offset
            let offsetNormal = offset.x * normal.x + offset.y * normal.y
            if abs(offsetNormal) < max(1e-9, tolerance) { continue }

            var minNormal = Double.infinity, maxNormal = -Double.infinity
            var minAlong = Double.infinity, maxAlong = -Double.infinity
            for c in corners {
                let n = c.x * normal.x + c.y * normal.y
                let a = c.x * unit.x + c.y * unit.y
                minNormal = min(minNormal, n); maxNormal = max(maxNormal, n)
                minAlong = min(minAlong, a); maxAlong = max(maxAlong, a)
            }
            let originNormal = line.origin.x * normal.x + line.origin.y * normal.y
            var firstValue = (minNormal - originNormal) / offsetNormal
            var lastValue = (maxNormal - originNormal) / offsetNormal
            if !firstValue.isFinite || !lastValue.isFinite
                || abs(firstValue) > 1e9 || abs(lastValue) > 1e9 { continue }
            if firstValue > lastValue { swap(&firstValue, &lastValue) }
            let firstLine = Int(floor(firstValue)) - 1
            let lastLine = Int(ceil(lastValue)) + 1
            if lastLine < firstLine || lastLine - firstLine > 4096 { continue }

            var period = 0.0
            for dash in line.dashes { period += abs(dash) }
            for k in firstLine...lastLine {
                let base = CGPoint(x: line.origin.x + offset.x * Double(k),
                                   y: line.origin.y + offset.y * Double(k))
                let baseAlong = base.x * unit.x + base.y * unit.y
                let start = minAlong - baseAlong - 1.0
                let end = maxAlong - baseAlong + 1.0
                func pointAt(_ d: Double) -> CGPoint {
                    CGPoint(x: base.x + unit.x * d, y: base.y + unit.y * d)
                }
                if line.dashes.isEmpty || period <= 1e-9 {
                    let p0 = pointAt(start), p1 = pointAt(end)
                    if hypot(p1.x - p0.x, p1.y - p0.y) >= tolerance {
                        result.append(HatchSegment(p0: p0, p1: p1, isDot: false))
                    }
                } else {
                    let cycles = Int(ceil((end - start) / period)) + 1
                    if cycles > 4096 { continue }
                    var cycleStart = floor(start / period) * period
                    for _ in 0..<cycles {
                        var cursor = cycleStart
                        for dash in line.dashes {
                            let length = abs(dash)
                            if length < 1e-9 {
                                if cursor >= start && cursor <= end {
                                    let p = pointAt(cursor)
                                    result.append(HatchSegment(p0: p, p1: p, isDot: true))
                                }
                            } else if dash > 0 {
                                let dashStart = max(start, cursor)
                                let dashEnd = min(end, cursor + length)
                                if dashEnd - dashStart >= tolerance {
                                    result.append(HatchSegment(p0: pointAt(dashStart),
                                                               p1: pointAt(dashEnd),
                                                               isDot: false))
                                }
                            }
                            cursor += length
                        }
                        cycleStart += period
                    }
                }
                if result.count >= budget { break }
            }
            if result.count >= budget { break }
        }
        if hatchLineCache.count > 4096 { hatchLineCache.removeAll() }
        hatchLineCache[key] = result
        return result
    }

    @discardableResult
    private func drawHatchPattern(_ path: CGMutablePath, box: CGRect,
                                  hatch: HatchPattern, key: Int, color: NSColor,
                                  ctx: CGContext, worldRect: CGRect,
                                  scale: CGFloat, pointScale: CGFloat,
                                  budget: Int) -> Int {
        ctx.saveGState()
        ctx.addPath(path)
        let rule: CGPathFillRule = hatch.style == 2 ? .winding : .evenOdd
        ctx.clip(using: rule)
        // Fair-share slice of the reference's global pattern budget.
        let generated = hatchPatternSegments(hatch, bounds: box, key: key)
        let segments = generated.prefix(max(0, min(budget, generated.count)))
        if segments.isEmpty {
            // Reference: patternTone() — an opaque 32% canvas/ink mix when the
            // pitch is too fine to resolve or the group budget produced no
            // lines. A translucent fill would double-blend and turn grey.
            ctx.setFillColor(patternTone(color).cgColor)
            ctx.addPath(path)
            ctx.fillPath(using: rule)
            ctx.restoreGState()
            return 0
        }
        // A 0.62 px cosmetic pen, identical to the reference QPen.
        let cosmetic = 0.62 / max(scale, 1e-9)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineCap(.round)
        ctx.setLineWidth(cosmetic)
        let lines = CGMutablePath()
        let dots = CGMutablePath()
        let dotRadius = cosmetic * 0.5
        for segment in segments {
            if segment.isDot {
                dots.addEllipse(in: CGRect(x: segment.p0.x - dotRadius,
                                           y: segment.p0.y - dotRadius,
                                           width: dotRadius * 2,
                                           height: dotRadius * 2))
            } else {
                lines.move(to: segment.p0)
                lines.addLine(to: segment.p1)
            }
        }
        ctx.addPath(lines)
        ctx.strokePath()
        ctx.setFillColor(color.cgColor)
        ctx.addPath(dots)
        ctx.fillPath(using: .winding)
        ctx.restoreGState()
        return segments.count
    }

    // MARK: Text

    /// The bundled GB pair (gbenor + gbcbig). Loaded once; nil when the files
    /// are absent, in which case the TrueType path below still draws labels.
    private static let shxLatin = ShxFont.load(bundled: "gbenor.shx", cjk: false)
    private static let shxCJK = ShxFont.load(bundled: "gbcbig.shx", cjk: true)

    private static func isCJK(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        return value > 0x2E7F
    }

    private static func shxFont(for character: Character) -> ShxFont? {
        isCJK(character) ? shxCJK : shxLatin
    }

    /// False when any character in the run has no usable SHX glyph — then the
    /// whole string goes through CoreText so one label never mixes weights.
    private func shxCanDraw(_ text: String) -> Bool {
        for character in text where character != " " {
            guard let font = Self.shxFont(for: character),
                  font.glyph(for: character) != nil else { return false }
        }
        return true
    }

    private func shxAdvance(_ character: Character, height: CGFloat) -> CGFloat {
        guard let font = Self.shxFont(for: character),
              let glyph = font.glyph(for: character) else { return height * 0.5 }
        return glyph.advance * height / font.capHeight
    }

    /// World-space pen path for one label, or nil when the string has no SHX
    /// coverage. Baking the placement into the path is what lets the text pass
    /// merge labels into per-ink batches: the same path is reused for every
    /// frame at this entity's position.
    private func textWorldPath(entity: Entity, index: Int32) -> CGPath? {
        if let cached = textWorldCache[index] { return cached }
        guard !textNotDrawable.contains(index) else { return nil }
        let local: CGPath
        if let cached = textPathCache[index] {
            local = cached
        } else {
            guard let built = buildShxPath(entity) else {
                textNotDrawable.insert(index)
                return nil
            }
            if textPathCache.count < 60_000 { textPathCache[index] = built }
            local = built
        }
        var placement = CGAffineTransform(translationX: CGFloat(entity.cx),
                                          y: CGFloat(entity.cy))
        if abs(entity.rot) > 1e-6 { placement = placement.rotated(by: CGFloat(entity.rot)) }
        if abs(entity.ws - 1) > 0.01 { placement = placement.scaledBy(x: CGFloat(entity.ws), y: 1) }
        let world = CGMutablePath()
        world.addPath(local, transform: placement)
        if textWorldCache.count < 60_000 { textWorldCache[index] = world }
        return world
    }

    /// Builds the pen path for one label in local space, or nil when any
    /// character has no SHX glyph (the caller then uses the text face).
    private func buildShxPath(_ entity: Entity) -> CGPath? {
        let text = entity.text
        guard shxCanDraw(text) else { return nil }
        let height = max(entity.h, 1e-6)
        let lines = text.components(separatedBy: "\n")
        let lineHeight = height * 1.2
        let widths = lines.map { line -> CGFloat in
            line.reduce(0) { $0 + shxAdvance($1, height: height) }
        }

        let blockHeight = CGFloat(max(0, lines.count - 1)) * lineHeight + height
        let firstBaseline: CGFloat
        switch entity.valign {
        case 1: firstBaseline = 0                          // bottom
        case 2: firstBaseline = blockHeight / 2 - height   // middle
        case 3: firstBaseline = -height                    // top
        default: firstBaseline = 0                         // baseline
        }

        let path = CGMutablePath()
        for (index, line) in lines.enumerated() where !line.isEmpty {
            var penX: CGFloat
            switch entity.halign {
            case 1: penX = -widths[index] / 2
            case 2: penX = -widths[index]
            default: penX = 0
            }
            let baseline = firstBaseline - CGFloat(index) * lineHeight
            for character in line {
                guard let font = Self.shxFont(for: character),
                      let glyph = font.glyph(for: character) else {
                    penX += height * 0.5
                    continue
                }
                let em = height / font.capHeight
                for subPath in glyph.subPaths {
                    guard let first = subPath.points.first else { continue }
                    path.move(to: CGPoint(x: penX + first.x * em, y: baseline + first.y * em))
                    for point in subPath.points.dropFirst() {
                        path.addLine(to: CGPoint(x: penX + point.x * em,
                                                 y: baseline + point.y * em))
                    }
                }
                penX += glyph.advance * em
            }
        }
        return path
    }

    /// TrueType fallback for labels the SHX pair cannot spell (a handful of
    /// symbols such as `㎡`). Drawn per label because CoreText owns the layout;
    /// they are rare enough that batching them would not pay for itself.
    private func drawFaceText(entity: Entity, ctx: CGContext, scale: CGFloat) {
        guard !entity.text.isEmpty else { return }
        let color = color(rgb: entity.rgb, aci: entity.aci)
        let fontSize = max(entity.h, 0.02)
        // Normalise the em size against the measured ink height so the drawn
        // label is exactly `entity.h` tall, the way CAD defines text height.
        let font = CadFont.fitted(size: fontSize, text: entity.text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]

        let lines = entity.text.components(separatedBy: "\n")
        // Same block metrics as the GPU glyph pass: line spacing 1.2 em and a
        // justification offset derived from the whole text block, not from a
        // per-line estimate. The reference does exactly this in drawCadText().
        // Line spacing follows the fitted size, not the CAD height: the font has
        // been rescaled so its ink box equals `entity.h`, and 1.2 em of the
        // rescaled face is the spacing the reference uses for MTEXT.
        let lineHeight = font.pointSize * 1.2
        let ascent = font.ascender
        let descent = -font.descender
        let blockHeight = CGFloat(lines.count - 1) * lineHeight + ascent + descent
        let baseline: CGFloat
        switch entity.valign {
        case 1: baseline = blockHeight - ascent
        case 2: baseline = blockHeight * 0.5 - ascent
        case 3: baseline = -ascent
        default: baseline = 0
        }

        ctx.saveGState()
        ctx.translateBy(x: CGFloat(entity.cx), y: CGFloat(entity.cy))
        if abs(entity.rot) > 1e-6 { ctx.rotate(by: CGFloat(entity.rot)) }
        if abs(entity.ws - 1) > 0.01 { ctx.scaleBy(x: CGFloat(entity.ws), y: 1) }

        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics

        for (index, line) in lines.enumerated() {
            guard !line.isEmpty else { continue }
            let attributed = NSAttributedString(string: line, attributes: attributes)
            let size = attributed.size()
            var x: CGFloat = 0
            switch entity.halign {
            case 1: x = -size.width / 2
            case 2: x = -size.width
            default: x = 0
            }
            // `draw(at:)` positions the lower-left corner of the line box, so
            // subtract the descent from the shared baseline.
            let y = baseline - descent - CGFloat(index) * lineHeight
            attributed.draw(at: CGPoint(x: x, y: y))
        }

        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }
}
