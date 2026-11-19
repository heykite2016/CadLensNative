import AppKit
import CadCore
import PDFKit

enum EntityKind: Int32 {
    case line = 1
    case polyline = 2
    case circle = 3
    case arc = 4
    case ellipse = 5
    case text = 6
    case hatch = 7
    case point = 8
    case solid = 9
}

enum EntityFlags {
    static let closed: Int32 = 1 << 0
    static let filled: Int32 = 1 << 1
    static let invisible: Int32 = 1 << 2
    static let mtext: Int32 = 1 << 3
    /// Geometry that a dimension drew for itself (witness lines, the dimension
    /// line and its terminators). Object snap skips it — see SnapEngine.swift.
    static let dimension: Int32 = 1 << 6
}

enum LayerFlags {
    static let off: Int32 = 1 << 0
    static let frozen: Int32 = 1 << 1
    static let locked: Int32 = 1 << 2
}

struct Entity {
    var kind: EntityKind = .line
    var space: Int32 = 0
    var layer: Int32 = -1
    /// Source DWG/DXF handle. Kept for selection, measurement provenance and
    /// diagnostics (the reference carries `sourceHandle` on every entity).
    var handle: UInt64 = 0
    /// Layers of enclosing INSERTs, used by VPLAYER viewport freezes.
    var blockLayers: [Int32] = []
    var flags: Int32 = 0
    var rgb: UInt32 = 0xFFFFFF
    var aci: UInt8 = 7
    var lineweight: Float = 0
    var pstart: Int32 = 0
    var pcount: Int32 = 0
    var cx: Double = 0
    var cy: Double = 0
    var r: Double = 0
    var a0: Double = 0
    var a1: Double = 0
    var mx: Double = 0
    var my: Double = 0
    var ratio: Double = 1
    var rot: Double = 0
    var h: Double = 0
    var ws: Double = 1
    var text: String = ""
    var halign: Int32 = 0
    var valign: Int32 = 0
    var hatch: Int32 = -1
    var box: CGRect = .zero
    /// Paper-space clip of the viewport this entity was composed into.
    /// `.zero` = ordinary model/paper entity with no clipping.
    var clip: CGRect = .zero

    /// BYLAYER / BYBLOCK line weights must resolve to the layer's own weight
    /// (reference: ModelBuilder::baseEntity(), LibreBuilder::commonEntity()).
    /// The C core stores 0 for "inherit", so both renderers fall back here.
    func resolvedLineweight(layers: [CadLayer]) -> Float {
        if lineweight > 0 { return lineweight }
        let index = Int(layer)
        if index >= 0, index < layers.count, layers[index].lineweight > 0 {
            return layers[index].lineweight
        }
        return 0.25
    }

    var isText: Bool { kind == .text }
    var hasClip: Bool { clip.width > 0 && clip.height > 0 }
    var isClosed: Bool { flags & EntityFlags.closed != 0 }
    /// Belongs to a dimension's own drawing (a witness line, its terminator…).
    var isDimensionInk: Bool { flags & EntityFlags.dimension != 0 }
}

struct CadLayer: Identifiable {
    let id: Int32
    var name: String
    var rgb: UInt32
    var aci: UInt8
    var flags: Int32
    var lineweight: Float
    var count: Int

    var isVisible: Bool {
        get { visible }
        set { visible = newValue }
    }
    /// User controlled visibility, persisted per drawing.
    var visible: Bool = true
    var isLocked: Bool { flags & LayerFlags.locked != 0 }
    var isOff: Bool { flags & LayerFlags.off != 0 }
    var isFrozen: Bool { flags & LayerFlags.frozen != 0 }
    var color: NSColor { Theme.aciColor(aci, rgb: rgb) }
}

struct CadSpaceInfo {
    var name: String
    var kind: Int32  // 0 model, 1 paper
    var firstEntity: Int32
    var entityCount: Int32
    var box: CGRect
    var isModel: Bool { kind == 0 }
}
struct CadViewport {
    var space: Int32
    var id: Int32
    var status: Int32
    var center: CGPoint
    var size: CGSize
    var modelCenter: CGPoint
    var modelHeight: Double
    var twist: Double
    var clip: CGRect
    var frozenLayers: Set<Int32>   // VPLAYER: hidden only inside this viewport
}

struct HatchRing {
    var pstart: Int32
    var pcount: Int32
    var closed: Bool
}

struct HatchPattern {
    struct Line {
        var angle: Double
        var origin: CGPoint
        var offset: CGPoint
        var dashes: [Double]
    }
    var rings: [HatchRing]
    var solid: Bool
    var style: Int32
    var angle: Double
    var scale: Double
    var lines: [Line]
}

enum MeasureUnit: Int, CaseIterable, Codable {
    case millimeter = 0
    case centimeter
    case meter
    case kilometer
    case inch
    case foot

    var suffix: String {
        switch self {
        case .millimeter: return "mm"
        case .centimeter: return "cm"
        case .meter: return "m"
        case .kilometer: return "km"
        case .inch: return "in"
        case .foot: return "ft"
        }
    }

    var metersPerUnit: Double {
        switch self {
        case .millimeter: return 0.001
        case .centimeter: return 0.01
        case .meter: return 1
        case .kilometer: return 1000
        case .inch: return 0.0254
        case .foot: return 0.3048
        }
    }
}

/// 面积单位是单独一档，不跟着长度单位走。
///
/// 图上量到的长度用毫米最顺手，可面积写 "7605761mm²" 没人读得出来——同一
/// 张图，长度标 mm、面积标 m² 才是施工图的常规写法。所以面积给了自己一个
/// 下拉框，默认 m²。
enum AreaUnit: Int, CaseIterable, Codable {
    case squareMillimeter = 0
    case squareCentimeter
    case squareMeter
    case hectare
    case squareInch
    case squareFoot

    var suffix: String {
        switch self {
        case .squareMillimeter: return "mm²"
        case .squareCentimeter: return "cm²"
        case .squareMeter: return "m²"
        case .hectare: return "ha"
        case .squareInch: return "in²"
        case .squareFoot: return "ft²"
        }
    }

    /// 一个该单位等于多少平方米。
    var squareMetersPerUnit: Double {
        switch self {
        case .squareMillimeter: return 0.000001
        case .squareCentimeter: return 0.0001
        case .squareMeter: return 1
        case .hectare: return 10000
        case .squareInch: return 0.0254 * 0.0254
        case .squareFoot: return 0.3048 * 0.3048
        }
    }

    /// m²、ha 之后的小数位多给一位：这类单位下的面积数值小，两位小数才够
    /// 分辨；mm²、cm² 动辄七位数，再挂两位小数只是噪声。
    var digits: Int {
        switch self {
        case .squareMeter, .hectare: return 2
        case .squareMillimeter, .squareCentimeter, .squareInch, .squareFoot: return 1
        }
    }
}

final class CadDocument {
    let url: URL
    let fileName: String
    private(set) var formatVersion: String = ""
    private(set) var backend: String = ""
    private(set) var loadMilliseconds: Double = 0
    private(set) var skippedObjects: Int = 0
    /// True when the 900k entity ceiling dropped geometry.
    private(set) var truncatedEntities = false
    /// Distinct external references the drawing inserts but that are not on
    /// disk next to it. Their geometry lives in another file, so it cannot be
    /// drawn — naming them is the only honest way to report the gap.
    private(set) var xrefNames: [String] = []

    /// 图纸插入的每一个外部参照，连同它被插入时的位置（2×3 仿射）。
    /// 几何在另一个文件里，但落位在这个文件里——两样凑齐，才能把缺的文件
    /// 补进来并摆到作者当初放的位置。
    private(set) var xrefInserts: [XrefInsert] = []
    /// 已经在同目录自动找到并合并进来的参照（文件名，用于提示）。
    private(set) var xrefAttached: [String] = []
    /// 参照链深度：A 参照 B、B 又参照 A 的文件不能无限展开。
    private var xrefDepth = 0

    /// PDF pages, when the source is a PDF rather than a CAD drawing.
    private(set) var pdfDocument: PDFDocument?
    private var pdfCache: [String: CGImage] = [:]
    private let pdfLock = NSLock()

    var entities: [Entity] = []
    var points: [CGPoint] = []
    var layers: [CadLayer] = []
    var spaces: [CadSpaceInfo] = []
    var viewports: [CadViewport] = []
    var hatches: [HatchPattern] = []

    /// Camera stored in the drawing's VPORT `*Active` record, in model
    /// coordinates. The first open restores this instead of fitting the entity
    /// extents, which is how a reference viewer reproduces the author's view.
    struct SavedView {
        var center: CGPoint
        var width: CGFloat
        var height: CGFloat
        var twist: CGFloat
    }
    private(set) var savedView: SavedView?

    /// EXTMIN/EXTMAX as stored in the DWG header: the extent the drawing was
    /// saved with. The reference viewer prefers this over a computed union of
    /// entity boxes when it decides how large the drawing is, because the
    /// union is poisoned by stray construction geometry parked far from the
    /// sheet. Nil when the header carries no usable pair.
    private(set) var declaredBox: CGRect?

    // MARK: - Model / layout relationship
    //
    // The model is the single source of geometry. A layout owns only its
    // paper-space entities (frames, title blocks, viewport outlines, paper
    // annotations). What you see *through* a viewport is not a second copy of
    // the drawing: it is a derived display list -- the model entities projected
    // through that viewport's centre, scale and twist, clipped to its paper
    // rectangle. `sourceEntities` stays pristine; `entities` is swapped to the
    // display list of whichever space is active, exactly like the reference
    // viewer's switchSpace(). Because layer visibility is applied by the
    // renderer (not baked into the list), toggling a layer changes the model
    // and every viewport at once. That is what "in sync" means.
    private var sourceEntities: [Entity] = []
    private var sourcePoints: [CGPoint] = []
    private var sourceHatches: [HatchPattern] = []
    private(set) var activeDisplaySpace: Int32 = -1
    private var displayDirty = true

    /// Metres per drawing unit, used for every measurement conversion.
    var unitMeters: Double = 1
    var unitIsCalibrated: Bool = false

    var displayUnit: MeasureUnit = .millimeter
    var precision: Int = 0
    /// 面积自己的单位，与长度单位解耦（见 `AreaUnit`）。
    var areaUnit: AreaUnit = .squareMeter

    /// Per space spatial index, built lazily on first render.
    private var indexes: [Int32: SpatialIndex] = [:]
    private var indexLock = NSLock()

    var annotations: [Annotation] = []
    var annotationsDirty = false

    var isPDF: Bool { pdfDocument != nil }

    init(url: URL) throws {
        self.url = url
        self.fileName = url.lastPathComponent
        if url.pathExtension.lowercased() == "pdf" {
            try loadPDF()
        } else {
            try loadDrawing()
        }
        annotations = AnnotationStore.load(for: url)
    }

    /// 读一份参照文件：只要几何，不挂标注，也不参与"最近打开"。
    private init(xref url: URL, depth: Int) throws {
        self.url = url
        self.fileName = url.lastPathComponent
        self.xrefDepth = depth
        let ext = url.pathExtension.lowercased()
        guard ext == "dwg" || ext == "dxf" else {
            throw CadError.load("参照文件不是 DWG/DXF：\(url.lastPathComponent)")
        }
        try loadDrawing()
    }

    // MARK: CAD

    private func loadDrawing() throws {
        var errorPtr: UnsafeMutablePointer<CChar>?
        guard let handle = url.path.withCString({ cad_doc_load($0, &errorPtr) }) else {
            let message = errorPtr.map { String(cString: $0) } ?? "无法读取图纸"
            if let errorPtr { free(errorPtr) }
            throw CadError.load(message)
        }
        defer { cad_doc_free(handle) }

        formatVersion = String(cString: cad_doc_version(handle))
        backend = String(cString: cad_doc_backend(handle))
        loadMilliseconds = cad_doc_load_ms(handle)
        skippedObjects = Int(cad_doc_skipped(handle))
        truncatedEntities = cad_doc_truncated(handle) != 0
        xrefNames = (0..<Int(cad_doc_xref_count(handle))).compactMap { index in
            var start: Int32 = 0
            var length: Int32 = 0
            cad_doc_xref_name(handle, Int32(index), &start, &length)
            guard length > 0, let base = cad_doc_text(handle) else { return nil }
            let bytes = UnsafeRawBufferPointer(start: base + Int(start),
                                               count: Int(length))
            return String(decoding: bytes, as: UTF8.self)
        }
        unitMeters = cad_doc_unit_meters(handle)
        unitIsCalibrated = cad_doc_calibrated(handle) != 0

        var matrix = [Double](repeating: 0, count: 6)
        for index in 0..<Int(cad_doc_xref_insert_count(handle)) {
            var nameStart: Int32 = 0, nameLen: Int32 = 0
            var pathStart: Int32 = 0, pathLen: Int32 = 0
            var space: Int32 = 0, layer: Int32 = -1
            cad_doc_xref_insert_info(handle, Int32(index), &nameStart, &nameLen,
                                     &pathStart, &pathLen, &space, &layer, &matrix)
            guard let base = cad_doc_text(handle) else { continue }
            func slice(_ start: Int32, _ length: Int32) -> String {
                guard length > 0 else { return "" }
                let bytes = UnsafeRawBufferPointer(start: base + Int(start),
                                                   count: Int(length))
                return String(decoding: bytes, as: UTF8.self)
            }
            xrefInserts.append(XrefInsert(name: slice(nameStart, nameLen),
                                          path: slice(pathStart, pathLen),
                                          space: space, layer: layer,
                                          matrix: matrix))
        }

        let entityCount = Int(cad_doc_entity_count(handle))
        let pointCount = Int(cad_doc_point_count(handle))
        let textBase = cad_doc_text(handle)
        entities.reserveCapacity(entityCount)
        points.reserveCapacity(pointCount)

        if let cPoints = cad_doc_points(handle), pointCount > 0 {
            points = Array(UnsafeBufferPointer(start: cPoints, count: pointCount))
                .map { CGPoint(x: $0.x, y: $0.y) }
        }
        let blockLayerCount = Int(cad_doc_block_layer_count(handle))
        let blockLayerPtr = cad_doc_block_layers(handle)
        if let cEntities = cad_doc_entities(handle) {
            for i in 0..<entityCount {
                let e = cEntities[i]
                var entity = Entity()
                entity.kind = EntityKind(rawValue: e.kind) ?? .line
                entity.space = e.space
                entity.layer = e.layer
                entity.handle = e.handle
                let blockStart = Int(e.block_layer_start)
                let blockLength = Int(e.block_layer_count)
                if let blockLayerPtr, blockStart >= 0, blockLength > 0,
                   blockStart + blockLength <= blockLayerCount {
                    entity.blockLayers = Array(
                        UnsafeBufferPointer(start: blockLayerPtr + blockStart,
                                            count: blockLength))
                }
                entity.flags = e.flags
                entity.rgb = e.rgb & 0xFFFFFF
                entity.aci = e.aci
                entity.lineweight = e.lineweight
                entity.pstart = e.pstart
                entity.pcount = e.pcount
                entity.cx = e.cx
                entity.cy = e.cy
                entity.r = e.r
                entity.a0 = e.a0
                entity.a1 = e.a1
                entity.mx = e.major_x
                entity.my = e.major_y
                entity.ratio = e.ratio
                entity.rot = e.rot
                entity.h = e.h
                entity.ws = e.ws
                entity.halign = e.halign
                entity.valign = e.valign
                entity.hatch = e.hatch
                entity.box = CGRect(x: e.box.minx, y: e.box.miny,
                                    width: max(0, e.box.maxx - e.box.minx),
                                    height: max(0, e.box.maxy - e.box.miny))
                if e.clip.maxx > e.clip.minx, e.clip.maxy > e.clip.miny {
                    entity.clip = CGRect(x: e.clip.minx, y: e.clip.miny,
                                         width: e.clip.maxx - e.clip.minx,
                                         height: e.clip.maxy - e.clip.miny)
                }
                if e.tstart >= 0, let base = textBase {
                    entity.text = String(cString: base + Int(e.tstart))
                }
                entities.append(entity)
            }
        }

        let layerCount = Int(cad_doc_layer_count(handle))
        if let cLayers = cad_doc_layers(handle) {
            for i in 0..<layerCount {
                let l = cLayers[i]
                let name = textBase.map { String(cString: $0 + Int(l.name_start)) } ?? "0"
                layers.append(CadLayer(id: Int32(i),
                                       name: name,
                                       rgb: l.rgb & 0xFFFFFF,
                                       aci: UInt8((l.rgb >> 24) & 0xFF),
                                       flags: l.flags,
                                       lineweight: l.lineweight,
                                       count: 0,
                                       visible: l.flags & LayerFlags.off == 0))
            }
        }

        let spaceCount = Int(cad_doc_space_count(handle))
        if let cSpaces = cad_doc_spaces(handle) {
            for i in 0..<spaceCount {
                let s = cSpaces[i]
                let name = textBase.map { String(cString: $0 + Int(s.name_start)) } ?? "模型"
                spaces.append(CadSpaceInfo(
                    name: name, kind: s.kind,
                    firstEntity: s.first_entity, entityCount: s.entity_count,
                    box: CGRect(x: s.box.minx, y: s.box.miny,
                                width: max(0, s.box.maxx - s.box.minx),
                                height: max(0, s.box.maxy - s.box.miny))))
            }
        }

        let viewportCount = Int(cad_doc_viewport_count(handle))
        let frozenCount = Int(cad_doc_frozen_layer_count(handle))
        let frozenPtr = cad_doc_frozen_layers(handle)
        if let cViewports = cad_doc_viewports(handle) {
            for i in 0..<viewportCount {
                let v = cViewports[i]
                var frozen: Set<Int32> = []
                if let frozenPtr {
                    let start = Int(v.frozen_start)
                    let count = Int(v.frozen_count)
                    if start >= 0, count > 0, start + count <= frozenCount {
                        for k in start..<(start + count) {
                            frozen.insert(frozenPtr[k])
                        }
                    }
                }
                viewports.append(CadViewport(
                    space: v.space, id: v.id, status: v.status,
                    center: CGPoint(x: v.cx, y: v.cy),
                    size: CGSize(width: v.width, height: v.height),
                    modelCenter: CGPoint(x: v.model_cx, y: v.model_cy),
                    modelHeight: v.model_height,
                    twist: v.twist,
                    clip: CGRect(x: v.clip.minx, y: v.clip.miny,
                                 width: v.clip.maxx - v.clip.minx,
                                 height: v.clip.maxy - v.clip.miny),
                    frozenLayers: frozen))
            }
        }

        let savedCamera = cad_doc_saved_view(handle)
        if savedCamera.valid != 0,
           savedCamera.width > 1e-9, savedCamera.height > 1e-9,
           savedCamera.cx.isFinite, savedCamera.cy.isFinite {
            savedView = SavedView(center: CGPoint(x: savedCamera.cx, y: savedCamera.cy),
                                  width: savedCamera.width,
                                  height: savedCamera.height,
                                  twist: savedCamera.twist)
        }

        let declared = cad_doc_declared_box(handle)
        if declared.minx.isFinite, declared.miny.isFinite,
           declared.maxx.isFinite, declared.maxy.isFinite,
           declared.maxx > declared.minx, declared.maxy > declared.miny {
            declaredBox = CGRect(x: declared.minx, y: declared.miny,
                                 width: declared.maxx - declared.minx,
                                 height: declared.maxy - declared.miny)
        }

        let hatchCount = Int(cad_doc_hatch_count(handle))
        let ringCount = Int(cad_doc_ring_count(handle))
        if let cHatches = cad_doc_hatches(handle), let cRings = cad_doc_rings(handle) {
            for i in 0..<hatchCount {
                let h = cHatches[i]
                var pattern = HatchPattern(rings: [], solid: h.solid != 0,
                                           style: h.style, angle: h.angle,
                                           scale: h.scale, lines: [])
                let start = Int(h.ringstart)
                for r in start..<(start + Int(h.ringcount)) where r < ringCount {
                    let ring = cRings[r]
                    pattern.rings.append(HatchRing(pstart: ring.pstart,
                                                   pcount: ring.pcount,
                                                   closed: ring.closed != 0))
                }
                let defCount = min(Int(h.defcount), 8)
                let angles: [Double] = [h.def_angle.0, h.def_angle.1, h.def_angle.2,
                                        h.def_angle.3, h.def_angle.4, h.def_angle.5,
                                        h.def_angle.6, h.def_angle.7]
                let originsX: [Double] = [h.def_x.0, h.def_x.1, h.def_x.2, h.def_x.3,
                                          h.def_x.4, h.def_x.5, h.def_x.6, h.def_x.7]
                let originsY: [Double] = [h.def_y.0, h.def_y.1, h.def_y.2, h.def_y.3,
                                          h.def_y.4, h.def_y.5, h.def_y.6, h.def_y.7]
                let offsetsX: [Double] = [h.def_dx.0, h.def_dx.1, h.def_dx.2, h.def_dx.3,
                                          h.def_dx.4, h.def_dx.5, h.def_dx.6, h.def_dx.7]
                let offsetsY: [Double] = [h.def_dy.0, h.def_dy.1, h.def_dy.2, h.def_dy.3,
                                          h.def_dy.4, h.def_dy.5, h.def_dy.6, h.def_dy.7]
                let dashCounts: [Int32] = [h.def_ndashes.0, h.def_ndashes.1, h.def_ndashes.2,
                                           h.def_ndashes.3, h.def_ndashes.4, h.def_ndashes.5,
                                           h.def_ndashes.6, h.def_ndashes.7]
                var copy = h
                for d in 0..<defCount {
                    // Each pattern family owns its dash run; reading them all
                    // from one shared slice left every family but the first
                    // with an empty pattern (rendered as continuous lines).
                    var patternDashes: [Double] = []
                    let nd = Int(dashCounts[d])
                    if nd > 0 {
                        for k in 0..<nd {
                            patternDashes.append(cad_hatch_dash(&copy, Int32(d), Int32(k)))
                        }
                    }
                    pattern.lines.append(.init(angle: angles[d],
                                               origin: CGPoint(x: originsX[d], y: originsY[d]),
                                               offset: CGPoint(x: offsetsX[d], y: offsetsY[d]),
                                               dashes: patternDashes))
                }
                hatches.append(pattern)
            }
        }

        // Entity counts per layer, for the layer inspector.
        var counts = [Int](repeating: 0, count: max(layers.count, 1))
        for entity in entities {
            let index = Int(entity.layer)
            if index >= 0 && index < counts.count { counts[index] += 1 }
        }
        for i in layers.indices { layers[i].count = counts[i] }

        // 外部参照：同目录能自己找到的直接合并，找不到的留给界面去问。
        autoAttachXrefs()
        if getenv("CADLENS_XREF_LOG") != nil {
            print("[xref] \(fileName): \(xrefInserts.count) inserts, "
                  + "\(xrefAttached.count) attached, entities=\(entities.count)")
            for insert in xrefInserts {
                print("[xref]  name=\(insert.name) path=\(insert.path) "
                      + "attached=\(insert.attached) m=\(insert.matrix)")
            }
        }
    }

    // MARK: PDF

    private func loadPDF() throws {
        let started = CFAbsoluteTimeGetCurrent()
        guard let pdf = PDFDocument(url: url) else {
            throw CadError.load("无法解析 PDF 文件")
        }
        guard pdf.pageCount > 0 else {
            throw CadError.load("PDF 中没有页面")
        }
        pdfDocument = pdf
        backend = "PDFKit"
        formatVersion = "PDF \(pdf.pageCount) 页"
        skippedObjects = 0
        xrefNames = []

        // One space per page so the page selector doubles as pagination.
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            var box = page.bounds(for: .mediaBox)
            if page.rotation % 180 != 0 {
                box = CGRect(x: box.minX, y: box.minY,
                             width: box.height, height: box.width)
            }
            let label = page.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (label?.isEmpty == false ? label! : "第 \(index + 1) 页")
            spaces.append(CadSpaceInfo(name: name, kind: 0,
                                       firstEntity: 0, entityCount: 0,
                                       box: box))
        }

        // A PDF unit is 1/72 inch.
        unitMeters = 0.0254 / 72.0
        unitIsCalibrated = false
        loadMilliseconds = (CFAbsoluteTimeGetCurrent() - started) * 1000
    }

    /// The PDFKit page backing a space, when the source is a PDF.
    func pdfPage(_ space: Int32) -> PDFPage? {
        guard let pdf = pdfDocument, space >= 0, Int(space) < pdf.pageCount else { return nil }
        return pdf.page(at: Int(space))
    }

    /// Box of a PDF page in page coordinates.
    func pdfPageBox(_ space: Int32) -> CGRect {
        guard space >= 0, Int(space) < spaces.count else { return .zero }
        return spaces[Int(space)].box
    }

    /// Rasterises a PDF page for the current zoom level, reusing cached bitmaps
    /// keyed by a quantised scale so panning stays cheap and zooming sharpens.
    func pdfPageImage(space: Int32, pixelsPerUnit: CGFloat,
                      maxPixel: CGFloat = 6144) -> CGImage? {
        guard let pdf = pdfDocument, space >= 0, Int(space) < pdf.pageCount,
              let page = pdf.page(at: Int(space)) else { return nil }

        let box = page.bounds(for: .mediaBox)
        guard box.width > 1, box.height > 1 else { return nil }

        // Quantise to 1/3-stop steps.
        let stepped = max(0.05, exp((log(max(pixelsPerUnit, 0.05)) * 3).rounded() / 3))
        let key = "\(space)|\(Int((stepped * 1000).rounded()))"

        pdfLock.lock()
        if let cached = pdfCache[key] {
            pdfLock.unlock()
            return cached
        }
        pdfLock.unlock()

        let limit = min(maxPixel / box.width, maxPixel / box.height)
        let scale = min(stepped, limit)
        let pixelWidth = max(1, Int((box.width * scale).rounded()))
        let pixelHeight = max(1, Int((box.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)
                                      ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        ctx.scaleBy(x: CGFloat(pixelWidth) / box.width,
                    y: CGFloat(pixelHeight) / box.height)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .mediaBox, to: ctx)
        guard let image = ctx.makeImage() else { return nil }

        pdfLock.lock()
        if pdfCache.count > 8 { pdfCache.removeAll() }
        pdfCache[key] = image
        pdfLock.unlock()
        return image
    }

    func index(for space: Int32) -> SpatialIndex {
        indexLock.lock()
        defer { indexLock.unlock() }
        if let existing = indexes[space] { return existing }
        let index = SpatialIndex(document: self, space: space)
        indexes[space] = index
        return index
    }

    func invalidateIndexes() {
        indexLock.lock()
        indexes.removeAll()
        indexLock.unlock()
    }

    func spaceInfo(_ index: Int32) -> CadSpaceInfo? {
        guard index >= 0 && Int(index) < spaces.count else { return nil }
        return spaces[Int(index)]
    }

    /// Rebuild the active space's display list. Layer visibility is *not*
    /// baked in -- the renderer applies it per frame, so a toggle propagates
    /// to the model tab and to every viewport of every layout simultaneously.
    func activateSpace(_ space: Int32) {
        if sourceEntities.isEmpty {
            sourceEntities = entities
            sourcePoints = points
            sourceHatches = hatches
        }
        if activeDisplaySpace == space && !displayDirty { return }
        activeDisplaySpace = space
        displayDirty = false
        invalidateIndexes()

        if space == 0 {
            entities = sourceEntities.filter { $0.space == 0 }
            points = sourcePoints
            hatches = sourceHatches
            return
        }

        var display = sourceEntities.filter { $0.space == space }
        var projectedPoints: [CGPoint] = []
        var projectedHatches: [HatchPattern] = []
        composeViewports(for: space, into: &display,
                         points: &projectedPoints, hatches: &projectedHatches)
        entities = display
        points = sourcePoints + projectedPoints
        hatches = sourceHatches + projectedHatches
    }

    func invalidateDisplay() {
        displayDirty = true
        invalidateIndexes()
    }

    /// 临时切换显示列表到某个空间，跑完还原。
    ///
    /// `entities` 是"当前空间"的显示列表（纸空间还会把模型透过视口投影进来），
    /// 所以打印别的空间时必须先把它切过去——否则多页预览里只有当前那页有图，
    /// 其余页是白纸。
    func withDisplaySpace<T>(_ space: Int32, _ body: () -> T) -> T {
        let previous = activeDisplaySpace
        if previous == space { return body() }
        activateSpace(space)
        let result = body()
        if previous >= 0 { activateSpace(previous) }
        return result
    }

    /// 整张纸的外框视口（"1:1 铺满整张纸"的那个）不是一扇看向模型的窗，
    /// 合成它只会把整页缩成一张小图。视口 id 在真实图纸里并不唯一，所以
    /// 只能靠"纸面中心与模型中心重合、且视高等于纸高"来认。
    func isOverallPaperViewport(_ viewport: CadViewport) -> Bool {
        let centreDistance = hypot(viewport.center.x - viewport.modelCenter.x,
                                   viewport.center.y - viewport.modelCenter.y)
        return centreDistance <= max(1, viewport.modelHeight) * 1e-9
            && abs(viewport.modelHeight - viewport.size.height)
               <= max(1, viewport.size.height) * 1e-9
    }

    /// 布局真实的纸面范围。
    ///
    /// `LAYOUT.EXTMIN/EXTMAX`（也就是 `spaceInfo.box`）存的是上次保存时的
    /// 视图范围，经常只框住标题栏那一条，比整张图小一大截；拿它去适配相机
    /// 就会把图纸四周裁掉，看着就是"布局显示不全"。纸面范围应该是三者的
    /// 并集：视口在纸上的矩形（真正的绘图区）、纸空间实体（图框、标题栏）、
    /// 以及 EXTMIN/EXTMAX 本身。
    func layoutExtent(_ space: Int32) -> CGRect {
        // 先取视口在纸上的矩形：那是一张图真正的"绘图区"。
        func paperRect(_ viewport: CadViewport) -> CGRect {
            CGRect(x: viewport.center.x - viewport.size.width / 2,
                   y: viewport.center.y - viewport.size.height / 2,
                   width: viewport.size.width, height: viewport.size.height)
        }
        let windows = viewports.filter {
            $0.space == space && $0.size.width > 0.5 && $0.size.height > 0.5
                && !isOverallPaperViewport($0)
        }
        // 还有一类"整页框"：它的矩形把别的视口整块包住，自己并不看模型
        // （西昌那张图里就挂着一个 4874×2206 的残留视口，把适配范围向左边
        // 拉出去两千多单位，整排图框被挤成右下角一条）。按"包住别人且面积
        // 大一个量级"认出来，排除在范围之外。
        let contentWindows = windows.filter { candidate in
            let rect = paperRect(candidate)
            return !windows.contains { other in
                guard other.size != candidate.size || other.center != candidate.center
                else { return false }
                let otherRect = paperRect(other)
                return rect.insetBy(dx: -1, dy: -1).contains(otherRect)
                    && rect.width * rect.height >= otherRect.width * otherRect.height * 2
            }
        }
        var area = CGRect.null
        for viewport in contentWindows.isEmpty ? windows : contentWindows {
            let rect = paperRect(viewport)
            area = area.isNull ? rect : area.union(rect)
        }
        let paper = spaceInfo(space)?.box ?? .null
        guard !area.isNull else {
            // 一个视口都没有（空布局）：只能信纸空间实体和 EXTMIN/EXTMAX。
            var box = paper
            for entity in entities where entity.space == space {
                guard !entity.box.isNull, entity.box.width.isFinite else { continue }
                box = box.isNull ? entity.box : box.union(entity.box)
            }
            return box
        }
        // 只吸收贴着纸面的实体（图框线、标题栏）。纸空间里常年累月会攒下
        // 扔在图纸外很远的杂项文字——把它们的包围盒也算进来，相机就会缩到
        // 把整张图缩成一条。
        let margin = max(area.width, area.height) * 0.25
        let reach = area.insetBy(dx: -margin, dy: -margin)
        for entity in entities where entity.space == space {
            guard !entity.box.isNull, entity.box.width.isFinite,
                  reach.intersects(entity.box) || reach.contains(entity.box) else { continue }
            area = area.union(entity.box)
        }
        // EXTMIN/EXTMAX 常常只是上次保存时的视图范围（有时比图纸小一截），
        // 只有和纸面重叠时才拿来补，避免把范围拉跑。
        if !paper.isNull, paper.intersects(area) { area = area.union(paper) }
        return area
    }

    /// Project the model through each paper-space viewport. The result is a
    /// derived, rebuildable display list -- never persisted as layout geometry.
    /// Every copy keeps the source handle/layer, carries the viewport's clip
    /// rectangle, and is filtered by that viewport's VPLAYER layer freezes.
    private func composeViewports(for space: Int32, into display: inout [Entity],
                                  points out: inout [CGPoint],
                                  hatches outHatches: inout [HatchPattern]) {
        let sources = sourceEntities.filter { $0.space == 0 }
        guard !sources.isEmpty else { return }
        let pointBase = sourcePoints.count
        let hatchBase = sourceHatches.count

        // 先挑出"真正看向模型"的视口：尺寸有效、不是整张纸的外框。
        var candidates: [CadViewport] = []
        for viewport in viewports where viewport.space == space {
            guard viewport.size.width > 0.5, viewport.size.height > 0.5,
                  viewport.modelHeight > 1e-9,
                  !isOverallPaperViewport(viewport) else { continue }
            candidates.append(viewport)
        }
        // 有些图纸（结构图尤其常见）把每个布局的模型视口都存成"关闭"
        // （DXF 68 = 0），可是这些布局在 AutoCAD 里照样显示图形。整张布局
        // 一个"打开"的视口都没有时，退回把它们全部合成——空图框对看图的人
        // 没有意义；有打开的视口时仍然尊重作者的开关。
        // `CADLENS_VIEWPORT_ALL=1` 可以强制全部合成，用于对比排查。
        let revealing = candidates.filter { $0.status != 0 }
        let active = getenv("CADLENS_VIEWPORT_ALL") != nil
            ? candidates
            : (revealing.isEmpty ? candidates : revealing)

        for viewport in active {

            let scale = viewport.size.height / viewport.modelHeight
            let ct = cos(viewport.twist), st = sin(viewport.twist)
            func map(_ x: Double, _ y: Double) -> CGPoint {
                let dx = (x - viewport.modelCenter.x) * scale
                let dy = (y - viewport.modelCenter.y) * scale
                return CGPoint(x: viewport.center.x + dx * ct - dy * st,
                               y: viewport.center.y + dx * st + dy * ct)
            }
            // The visible model window is the paper rectangle rotated back by
            // -twist about the model centre; ignoring rotation silently drops
            // entities near the corners of twisted viewports.
            let halfW = viewport.size.width * 0.5 / scale
            let halfH = viewport.modelHeight * 0.5
            let extentX = abs(halfW * ct) + abs(halfH * st)
            let extentY = abs(halfW * st) + abs(halfH * ct)
            let window = CGRect(x: viewport.modelCenter.x - extentX,
                                y: viewport.modelCenter.y - extentY,
                                width: extentX * 2, height: extentY * 2)
            let clip = viewport.clip.isEmpty
                ? CGRect(x: viewport.center.x - viewport.size.width / 2,
                         y: viewport.center.y - viewport.size.height / 2,
                         width: viewport.size.width, height: viewport.size.height)
                : viewport.clip
            let frozen = viewport.frozenLayers
            var hatchRemap: [Int32: Int32] = [:]

            for src in sources {
                // A viewport cull must keep axis-aligned segments: their box has
                // zero height or width, which `CGRect.intersects` reports as
                // "no overlap" and would drop from every layout viewport.
                if src.box.minX.isFinite, src.box.maxX.isFinite,
                   !cadBoxesOverlap(src.box, window) { continue }
                // Reference CadView.cpp::composeLayoutContent(): a viewport
                // freeze applies to the entity's own layer *and* to every
                // enclosing INSERT layer. Geometry on layer 0 inside a frozen
                // block must disappear inside that viewport only.
                if frozen.contains(src.layer)
                    || src.blockLayers.contains(where: { frozen.contains($0) }) { continue }

                var entity = src
                entity.space = space
                entity.clip = clip

                if src.pcount > 0 {
                    let start = Int(src.pstart)
                    let end = min(start + Int(src.pcount), sourcePoints.count)
                    if end > start {
                        entity.pstart = Int32(pointBase + out.count)
                        for k in start..<end {
                            let p = sourcePoints[k]
                            out.append(map(Double(p.x), Double(p.y)))
                        }
                        entity.pcount = Int32(end - start)
                    }
                }
                let centre = map(src.cx, src.cy)
                entity.cx = Double(centre.x)
                entity.cy = Double(centre.y)
                entity.r = src.r * scale
                entity.a0 = src.a0 + viewport.twist
                entity.a1 = src.a1 + viewport.twist
                let mx = src.mx * scale, my = src.my * scale
                entity.mx = mx * ct - my * st
                entity.my = mx * st + my * ct
                entity.h = src.h * scale
                entity.rot = src.rot + viewport.twist

                // Reference: CadEntity::updateBounds() recomputes bounds from
                // the transformed point list, not from a rotated AABB of the
                // old box. On a twisted viewport the four-corner box can be
                // much larger than the geometry, which over-feeds the spatial
                // index on every frame.
                var minX = Double.infinity, maxX = -Double.infinity
                var minY = Double.infinity, maxY = -Double.infinity
                if entity.pcount > 0 {
                    let from = Int(entity.pstart) - pointBase
                    let to = min(from + Int(entity.pcount), out.count)
                    if from >= 0 && to > from {
                        for k in from..<to {
                            let p = out[k]
                            minX = min(minX, Double(p.x)); maxX = max(maxX, Double(p.x))
                            minY = min(minY, Double(p.y)); maxY = max(maxY, Double(p.y))
                        }
                    }
                }
                if minX > maxX || minY > maxY {
                    let corners = [map(src.box.minX, src.box.minY),
                                   map(src.box.maxX, src.box.maxY),
                                   map(src.box.minX, src.box.maxY),
                                   map(src.box.maxX, src.box.minY)]
                    minX = Double(corners.map(\.x).min() ?? centre.x)
                    maxX = Double(corners.map(\.x).max() ?? centre.x)
                    minY = Double(corners.map(\.y).min() ?? centre.y)
                    maxY = Double(corners.map(\.y).max() ?? centre.y)
                }
                entity.box = CGRect(x: minX, y: minY,
                                    width: max(0, maxX - minX),
                                    height: max(0, maxY - minY))
                // The model window is a conservative AABB (it also covers a
                // twisted viewport's corners). After projection, drop copies
                // whose transformed bounds still miss the actual paper clip;
                // otherwise every large entity is uploaded once per viewport.
                if !cadBoxesOverlap(entity.box, clip) { continue }

                // A hatch definition is shared by all copies inside one
                // viewport but must not be shared across viewports, or two
                // differently clipped copies merge into one fill path.
                if src.hatch >= 0, Int(src.hatch) < sourceHatches.count {
                    if let remapped = hatchRemap[src.hatch] {
                        entity.hatch = remapped
                    } else {
                        var pattern = sourceHatches[Int(src.hatch)]
                        var rings: [HatchRing] = []
                        for ring in pattern.rings {
                            let start = Int(ring.pstart)
                            let end = min(start + Int(ring.pcount), sourcePoints.count)
                            guard end > start else { continue }
                            let newStart = Int32(pointBase + out.count)
                            for k in start..<end {
                                let p = sourcePoints[k]
                                out.append(map(Double(p.x), Double(p.y)))
                            }
                            rings.append(HatchRing(pstart: newStart,
                                                   pcount: Int32(end - start),
                                                   closed: ring.closed))
                        }
                        pattern.rings = rings
                        pattern.scale *= scale
                        pattern.lines = pattern.lines.map { line in
                            let origin = map(line.origin.x, line.origin.y)
                            let shifted = map(line.origin.x + line.offset.x,
                                              line.origin.y + line.offset.y)
                            return HatchPattern.Line(
                                angle: line.angle + viewport.twist,
                                origin: origin,
                                offset: CGPoint(x: shifted.x - origin.x,
                                                y: shifted.y - origin.y),
                                dashes: line.dashes.map { $0 * scale })
                        }
                        let newIndex = Int32(hatchBase + outHatches.count)
                        outHatches.append(pattern)
                        hatchRemap[src.hatch] = newIndex
                        entity.hatch = newIndex
                    }
                }
                display.append(entity)
            }
        }
    }

    func entityIndices(in space: Int32) -> Range<Int> {
        if activeDisplaySpace >= 0 { return 0..<entities.count }
        guard let info = spaceInfo(space) else { return 0..<0 }
        let start = Int(info.firstEntity)
        let end = min(start + Int(info.entityCount), entities.count)
        return start..<max(start, end)
    }

    func points(for entity: Entity) -> ArraySlice<CGPoint> {
        guard entity.pcount > 0 else { return [][...] }
        let start = Int(entity.pstart)
        let end = min(start + Int(entity.pcount), points.count)
        guard start < end else { return [][...] }
        return points[start..<end]
    }

    func hatch(for entity: Entity) -> HatchPattern? {
        guard entity.hatch >= 0, Int(entity.hatch) < hatches.count else { return nil }
        return hatches[Int(entity.hatch)]
    }

    var boundsOfModel: CGRect {
        spaces.first?.box ?? .zero
    }

    /// Model space is usually where a drawing starts, but exporters sometimes
    /// keep every entity in a paper-space layout, which would open on a blank
    /// canvas; the first space that actually holds geometry wins.
    var defaultSpaceIndex: Int {
        if let index = spaces.firstIndex(where: { $0.entityCount > 0 }) {
            return index
        }
        return 0
    }

    /// Bounding box that holds the bulk of the geometry. Real drawings often
    /// carry a handful of strays millions of units away (moved blocks, leftover
    /// construction lines); fitting those makes the actual sheet unreadable, so
    /// the initial view uses the 2–98% percentile of the entity extents instead.
    func contentBox(for space: Int32) -> CGRect? {
        var xs: [CGFloat] = []
        var ys: [CGFloat] = []
        xs.reserveCapacity(entities.count)
        ys.reserveCapacity(entities.count)
        // The camera is framed by the sheet itself, not by the model content
        // seen through its viewports. Projected copies are clipped to the sheet
        // anyway, but including their bounds in the percentile would pull the
        // fit away from the paper frame and crop the first/last cards.
        for entity in entities where entity.space == space && !entity.hasClip {
            let box = entity.box
            // A segment has a degenerate box; excluding it here lost the sheet
            // edges that only horizontal / vertical lines define.
            guard box.width.isFinite, box.height.isFinite,
                  box.minX.isFinite, box.minY.isFinite else { continue }
            xs.append(box.minX)
            xs.append(box.maxX)
            ys.append(box.minY)
            ys.append(box.maxY)
        }
        guard xs.count >= 24 else { return nil }
        xs.sort()
        ys.sort()
        func percentile(_ values: [CGFloat], _ p: Double) -> CGFloat {
            values[Int(Double(values.count - 1) * p)]
        }
        let minX = percentile(xs, 0.02), maxX = percentile(xs, 0.98)
        let minY = percentile(ys, 0.02), maxY = percentile(ys, 0.98)
        guard maxX > minX, maxY > minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Camera hint for the first open. Port of cadInitialViewBounds()
    /// (CadModel.cpp:2299) with the basis box supplied by the drawing rather
    /// than guessed.
    ///
    /// The grid is laid over, in order: the camera the designer saved
    /// (VPORT *Active), then the declared extent (header EXTMIN/EXTMAX), then
    /// the union of entity boxes. That ordering matters because of a failure
    /// mode the reference itself has: on this site plan the header extent —
    /// and therefore the union — spans 8.7 km, because stray construction
    /// geometry was left in model space, while the sheet is 122 m. A grid over
    /// 8.7 km puts the entire plan inside one of 1024 cells, so "largest
    /// cluster" returns a 272 m cell and the plan lands at a tenth of the
    /// window. The saved camera is 122 m and is the designer's own answer to
    /// "what should the first screen show", so it is the right basis; the
    /// cluster pass then tightens it to the densest block of the sheet.
    ///
    /// Independent x/y percentiles are not a substitute: a drawing whose plan
    /// sits in one half of the sheet and whose dimensions sit in the other
    /// pulls the percentile box across empty space, so the plan lands in a
    /// corner.
    func initialViewBox(for space: Int32) -> CGRect? {
        // Paper space is framed by LAYOUT.EXTMIN/EXTMAX (see CadCore), which
        // is the designer's own sheet window; the reference never clusters a
        // layout, so neither do we.
        guard space == 0 else { return contentBox(for: space) }

        var basis: CGRect?
        if let saved = savedView, saved.width > 0, saved.height > 0,
           saved.center.x.isFinite, saved.center.y.isFinite {
            basis = CGRect(x: saved.center.x - saved.width / 2,
                           y: saved.center.y - saved.height / 2,
                           width: saved.width, height: saved.height)
        }
        if basis == nil { basis = declaredBox }
        if basis == nil {
            var union = CGRect.null
            for i in entityIndices(in: space) {
                let b = entities[i].box
                guard b.width.isFinite, b.height.isFinite,
                      b.minX.isFinite, b.minY.isFinite else { continue }
                union = union.isNull ? b : union.union(b)
            }
            basis = union.isNull ? nil : union
        }
        guard var bounds = basis, bounds.width > 0, bounds.height > 0 else {
            return contentBox(for: space)
        }
        bounds = bounds.standardized

        let gridSize = 32
        let minimumEntityCount = 64
        let cellCount = gridSize * gridSize
        var cellCounts = [Int32](repeating: 0, count: cellCount)
        var validEntities = 0
        for i in entityIndices(in: space) {
            let b = entities[i].box
            guard b.width.isFinite, b.height.isFinite,
                  b.minX.isFinite, b.minY.isFinite else { continue }
            let center = CGPoint(x: b.midX, y: b.midY)
            guard bounds.contains(center) else { continue }
            let fx = min(max((center.x - bounds.minX) / bounds.width, 0), 1)
            let fy = min(max((center.y - bounds.minY) / bounds.height, 0), 1)
            let column = min(Int(fx * CGFloat(gridSize)), gridSize - 1)
            let row = min(Int(fy * CGFloat(gridSize)), gridSize - 1)
            cellCounts[row * gridSize + column] += 1
            validEntities += 1
        }
        guard validEntities >= minimumEntityCount else { return bounds }

        var visited = [Bool](repeating: false, count: cellCount)
        var bestCount = 0
        var best = (minCol: 0, maxCol: 0, minRow: 0, maxRow: 0)
        let neighbours = [(-1, -1), (0, -1), (1, -1), (-1, 0),
                          (1, 0), (-1, 1), (0, 1), (1, 1)]
        var pending: [Int] = []
        pending.reserveCapacity(cellCount)
        for start in 0..<cellCount where cellCounts[start] > 0 && !visited[start] {
            pending.removeAll(keepingCapacity: true)
            pending.append(start)
            visited[start] = true
            var count = 0
            var minCol = gridSize, maxCol = -1, minRow = gridSize, maxRow = -1
            var head = 0
            while head < pending.count {
                let cell = pending[head]; head += 1
                let column = cell % gridSize
                let row = cell / gridSize
                count += Int(cellCounts[cell])
                minCol = min(minCol, column); maxCol = max(maxCol, column)
                minRow = min(minRow, row); maxRow = max(maxRow, row)
                for (dc, dr) in neighbours {
                    let nextColumn = column + dc
                    let nextRow = row + dr
                    guard nextColumn >= 0, nextColumn < gridSize,
                          nextRow >= 0, nextRow < gridSize else { continue }
                    let next = nextRow * gridSize + nextColumn
                    if !visited[next], cellCounts[next] > 0 {
                        visited[next] = true
                        pending.append(next)
                    }
                }
            }
            if count > bestCount {
                bestCount = count
                best = (minCol, maxCol, minRow, maxRow)
            }
        }
        guard bestCount > 0 else { return bounds }

        let cellWidth = bounds.width / CGFloat(gridSize)
        let cellHeight = bounds.height / CGFloat(gridSize)
        var focus = CGRect(
            x: bounds.minX + CGFloat(best.minCol) * cellWidth,
            y: bounds.minY + CGFloat(best.minRow) * cellHeight,
            width: CGFloat(best.maxCol - best.minCol + 1) * cellWidth,
            height: CGFloat(best.maxRow - best.minRow + 1) * cellHeight)
        focus = focus.insetBy(dx: -focus.width * 0.06, dy: -focus.height * 0.06)
        return focus.intersection(bounds)
    }

    func isLayerVisible(_ entity: Entity) -> Bool {        guard entity.flags & EntityFlags.invisible == 0 else { return false }
        let index = Int(entity.layer)
        if index >= 0 && index < layers.count {
            let layer = layers[index]
            guard layer.visible, !layer.isFrozen else { return false }
        }
        return true
    }

    // MARK: Arc-aware paths

    /// 如果这两个点都落在同一段圆弧上，就返回沿弧从 a 到 b 的加密点（含端点）；
    /// 否则返回 nil，调用方继续按直线处理。
    ///
    /// 墙、梁、弧形阳台的边都是圆弧，两点一连量出来的是弦长——差的那一截在
    /// 现场是要按实际弧长下料的。判据用两点到圆心的距离，因为点在弧上时线段
    /// 会从弧内部穿过，用线段求交不可靠。
    func arcPath(from a: CGPoint, to b: CGPoint, tolerance: CGFloat) -> [CGPoint]? {
        guard tolerance > 0 else { return nil }
        let box = CGRect(x: min(a.x, b.x) - tolerance, y: min(a.y, b.y) - tolerance,
                         width: abs(b.x - a.x) + tolerance * 2,
                         height: abs(b.y - a.y) + tolerance * 2)
        for index in index(for: activeDisplaySpace).query(box) {
            let entity = entities[Int(index)]
            guard entity.kind == .arc || entity.kind == .circle,
                  entity.r > 1e-9, isLayerVisible(entity) else { continue }
            let center = CGPoint(x: CGFloat(entity.cx), y: CGFloat(entity.cy))
            let radius = CGFloat(entity.r)
            let da = abs(hypot(a.x - center.x, a.y - center.y) - radius)
            let db = abs(hypot(b.x - center.x, b.y - center.y) - radius)
            guard da <= tolerance, db <= tolerance else { continue }
            var start = atan2(a.y - center.y, a.x - center.x)
            var end = atan2(b.y - center.y, b.x - center.x)
            var sweep: CGFloat
            if entity.kind == .arc {
                // DXF 圆弧从 a0 逆时针到 a1。
                let base = CGFloat(entity.a0)
                let span = normalised(CGFloat(entity.a1) - base)
                start = normalised(start - base)
                end = normalised(end - base)
                guard start <= span + 1e-6, end <= span + 1e-6 else { continue }
                sweep = end - start
                if sweep < 0 { sweep += 2 * .pi }
                start += base
            } else {
                // 圆没有方向，取两点之间的短弧。
                sweep = end - start
                while sweep <= -.pi { sweep += 2 * .pi }
                while sweep > .pi { sweep -= 2 * .pi }
            }
            guard abs(sweep) > 1e-4 else { continue }
            let steps = max(2, Int(abs(sweep) / (6 * .pi / 180)) + 1)
            var path: [CGPoint] = []
            path.reserveCapacity(steps + 1)
            for step in 0...steps {
                let t = start + sweep * CGFloat(step) / CGFloat(steps)
                path.append(CGPoint(x: center.x + cos(t) * radius,
                                    y: center.y + sin(t) * radius))
            }
            // 端点用用户点的那两个坐标收口：捕捉误差不该在标注上留下小台阶。
            path[0] = a
            path[path.count - 1] = b
            return path
        }
        return nil
    }

    private func normalised(_ angle: CGFloat) -> CGFloat {
        var value = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if value < 0 { value += 2 * .pi }
        return value
    }

    // MARK: Measurement formatting

    var metersPerDrawingUnit: Double { unitMeters }

    func lengthValue(_ drawingLength: Double) -> Double {
        let meters = drawingLength * unitMeters
        return meters / displayUnit.metersPerUnit
    }

    /// 线性尺寸只印数字，不带单位。
    ///
    /// 一张图里几百个尺寸，每个后面都缀一个 "mm" 是噪声：单位在图纸标题栏
    /// 和设置里说一次就够了。面积和周长是另一回事——"S = 12.13" 和
    /// "S = 12.13m²" 是两个不同的结论，所以那两个量必须带单位。
    func formatLength(_ drawingLength: Double, precision override: Int? = nil,
                      unit: Bool = false) -> String {
        let value = lengthValue(drawingLength)
        let digits = override ?? precision
        let number = String(format: "%.\(digits)f", value)
        // 默认 mm 不注单位（GB 11.2.2）；一旦用户把显示单位切到 m/cm/ft，
        // 就必须带单位，否则 3.6 会被读成 3.6mm。
        let needsUnit = unit || displayUnit != .millimeter
        return needsUnit ? number + displayUnit.suffix : number
    }

    /// 面积换算：图纸单位² → m² → 用户选定的面积单位。
    func areaValue(_ drawingArea: Double) -> Double {
        let squareMeters = drawingArea * unitMeters * unitMeters
        return squareMeters / areaUnit.squareMetersPerUnit
    }

    func formatArea(_ drawingArea: Double, precision override: Int? = nil) -> String {
        let value = areaValue(drawingArea)
        let digits = override ?? areaUnit.digits
        return String(format: "%.\(digits)f%@", value, areaUnit.suffix)
    }

    func formatAngle(_ radians: Double) -> String {
        let degrees = abs(radians) * 180.0 / .pi
        return String(format: "%.1f°", degrees)
    }
}

/// 一次外部参照插入：参照名、文件路径、落位矩阵。
struct XrefInsert {
    var name: String
    var path: String
    var space: Int32
    var layer: Int32
    /// [m11, m12, m21, m22, dx, dy]，x' = m11·x + m21·y + dx
    var matrix: [Double]
    var attached = false
    var resolvedURL: URL?

    /// 图层前缀用的短名：图纸里存的是 "xref/plan.dwg" 或完整路径，取文件名
    /// 去掉扩展名，与 AutoCAD 的 "参照名|图层名" 命名习惯一致。
    var shortName: String {
        let raw = path.isEmpty ? name : path
        let file = (raw as NSString).lastPathComponent
        let base = (file as NSString).deletingPathExtension
        return base.isEmpty ? name : base
    }

    var displayPath: String { path.isEmpty ? name : path }
}

/// 外部参照（XREF）的落地：找文件、合并几何、报告缺口。
///
/// 参照不是"另一种图元"——图纸里那几处 INSERT 什么都没画，几何全在另一个
/// 文件里。所以唯一能做的补救是把参照文件当成一份完整图纸读进来，再把它的
/// 模型空间图元按插入矩阵搬过来，图层名加上"参照名|"前缀（AutoCAD 的惯例），
/// 这样图层开关仍然管得住参照内容。
extension CadDocument {

    /// 还没找到文件的参照。
    var missingXrefs: [XrefInsert] {
        xrefInserts.filter { !$0.attached }
    }

    /// 缺失参照在原数组里的下标，界面回接用户选的文件时要用。
    var missingXrefIndexes: [Int] {
        xrefInserts.indices.filter { !xrefInserts[$0].attached }
    }

    /// 同目录自动补齐。找不到的留在 `xrefInserts` 里，由界面询问用户。
    private func autoAttachXrefs() {
        guard xrefDepth < 3, !xrefInserts.isEmpty else { return }
        let directory = url.deletingLastPathComponent()
        for index in xrefInserts.indices where !xrefInserts[index].attached {
            guard let found = Self.locateXref(xrefInserts[index], in: directory) else { continue }
            attachXref(at: found, index: index)
        }
    }

    /// 依次尝试：图纸里存的路径（可能是绝对路径）→ 相对图纸所在目录 →
    /// 同名不同扩展名 → 目录里大小写不同的同名文件。
    static func locateXref(_ insert: XrefInsert, in directory: URL) -> URL? {
        let manager = FileManager.default
        let stored = (insert.path.isEmpty ? insert.name : insert.path)
            .replacingOccurrences(of: "\\", with: "/")
        var candidates: [String] = [stored]
        let base = (stored as NSString).lastPathComponent
        if base != stored { candidates.append(base) }
        let stem = (base as NSString).deletingPathExtension
        for ext in ["dwg", "dxf"] {
            candidates.append("\(stem).\(ext)")
        }

        for candidate in candidates where !candidate.isEmpty {
            if candidate.hasPrefix("/") {
                if manager.fileExists(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
                continue
            }
            let relative = directory.appendingPathComponent(candidate)
            if manager.fileExists(atPath: relative.path) { return relative }
        }

        // Windows 上画的图常带盘符和反斜杠，目录名大小写也可能与 mac 上不一致。
        guard !stem.isEmpty,
              let listing = try? manager.contentsOfDirectory(atPath: directory.path)
        else { return nil }
        for entry in listing {
            let name = (entry as NSString).deletingPathExtension
            guard name.compare(stem, options: .caseInsensitive) == .orderedSame else { continue }
            return directory.appendingPathComponent(entry)
        }
        return nil
    }

    /// 把用户指定的文件接到某个缺失的参照上。
    @discardableResult
    func attachXref(at fileURL: URL, index: Int) -> Bool {
        guard index >= 0, index < xrefInserts.count else { return false }
        guard let child = try? CadDocument(xref: fileURL, depth: xrefDepth + 1) else { return false }
        merge(child, using: xrefInserts[index])
        xrefInserts[index].attached = true
        xrefInserts[index].resolvedURL = fileURL
        xrefAttached.append(fileURL.lastPathComponent)
        // 嵌套参照缺失也要往上冒，否则用户看不到"里面还有一个没找到"。
        for missing in child.xrefInserts where !missing.attached {
            var copy = missing
            copy.name = "\(xrefInserts[index].shortName)|\(missing.name)"
            xrefInserts.append(copy)
        }
        return true
    }

    /// 合并后重建显示列表：视图、空间索引、侧栏都要重新读一遍几何。
    func xrefsDidChange() {
        invalidateDisplay()
        activateSpace(activeDisplaySpace < 0 ? 0 : activeDisplaySpace)
    }

    /// `sourceEntities` 是懒加载的快照；合并前必须先让它有内容，否则刚合并进来
    /// 的图元会在第一次切空间时被这份空快照覆盖掉。
    private func ensureSourceLoaded() {
        if sourceEntities.isEmpty {
            sourceEntities = entities
            sourcePoints = points
            sourceHatches = hatches
        }
    }

    private func merge(_ child: CadDocument, using insert: XrefInsert) {
        child.ensureSourceLoaded()
        guard !child.sourceEntities.isEmpty || !child.sourcePoints.isEmpty else { return }
        ensureSourceLoaded()

        // 图层：名字加上 "参照名|" 前缀，索引整体后移。
        var layerMap: [Int32: Int32] = [:]
        for layer in child.layers {
            let identifier = Int32(layers.count)
            let copy = CadLayer(id: identifier,
                                name: "\(insert.shortName)|\(layer.name)",
                                rgb: layer.rgb, aci: layer.aci,
                                flags: layer.flags, lineweight: layer.lineweight,
                                count: 0, visible: layer.visible)
            layerMap[layer.id] = identifier
            layers.append(copy)
        }

        let matrix = insert.matrix
        let pointBase = Int32(sourcePoints.count)
        let hatchBase = Int32(sourceHatches.count)
        // 点先整体变换：多段线、填充环、圆弧的采样点都在这儿，一次算完。
        for point in child.sourcePoints {
            sourcePoints.append(Self.apply(matrix, to: point))
        }
        for var hatch in child.sourceHatches {
            for ring in hatch.rings.indices {
                hatch.rings[ring].pstart += pointBase
            }
            sourceHatches.append(hatch)
        }

        let angle = atan2(matrix[1], matrix[0])
        for var entity in child.sourceEntities where entity.space == 0 {
            guard entity.pcount > 0 || entity.kind == .text || entity.kind == .circle
                    || entity.kind == .arc || entity.kind == .ellipse || entity.kind == .point
            else { continue }
            if entity.pcount > 0 { entity.pstart += pointBase }
            if entity.hatch >= 0 { entity.hatch += hatchBase }
            if let mapped = layerMap[entity.layer] { entity.layer = mapped } else { entity.layer = -1 }
            if !entity.blockLayers.isEmpty {
                entity.blockLayers = entity.blockLayers.map { layerMap[$0] ?? -1 }
            }
            entity.space = insert.space
            Self.transform(&entity, matrix: matrix, angle: angle)
            sourceEntities.append(entity)
        }
        invalidateDisplay()
    }

    private static func apply(_ m: [Double], to point: CGPoint) -> CGPoint {
        CGPoint(x: m[0] * point.x + m[2] * point.y + m[4],
                y: m[1] * point.x + m[3] * point.y + m[5])
    }

    /// 标量几何（圆心、半径、圆弧角、文字角度/字高、包围盒）跟着矩阵走。
    /// 点集已在调用前统一变换过，这里不能再碰，否则会被变换两次。
    private static func transform(_ entity: inout Entity, matrix: [Double], angle: Double) {
        let scale = hypot(matrix[0], matrix[1])
        let determinant = matrix[0] * matrix[3] - matrix[1] * matrix[2]

        let centre = apply(matrix, to: CGPoint(x: entity.cx, y: entity.cy))
        entity.cx = centre.x
        entity.cy = centre.y
        if entity.r != 0 { entity.r *= scale }
        // 镜像会把圆弧的起止角翻过来，不换的话弧就画在补角上。
        if determinant < 0 {
            let a0 = entity.a0, a1 = entity.a1
            entity.a0 = angle - a1
            entity.a1 = angle - a0
        } else {
            entity.a0 += angle
            entity.a1 += angle
        }
        if entity.mx != 0 || entity.my != 0 {
            let major = CGPoint(x: matrix[0] * entity.mx + matrix[2] * entity.my,
                                y: matrix[1] * entity.mx + matrix[3] * entity.my)
            entity.mx = major.x
            entity.my = major.y
        }
        entity.rot += angle
        if entity.h != 0 { entity.h *= scale }

        if entity.box.width > 0 || entity.box.height > 0 {
            let corners = [
                CGPoint(x: entity.box.minX, y: entity.box.minY),
                CGPoint(x: entity.box.maxX, y: entity.box.minY),
                CGPoint(x: entity.box.maxX, y: entity.box.maxY),
                CGPoint(x: entity.box.minX, y: entity.box.maxY),
            ].map { apply(matrix, to: $0) }
            let xs = corners.map(\.x), ys = corners.map(\.y)
            entity.box = CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                                width: (xs.max() ?? 0) - (xs.min() ?? 0),
                                height: (ys.max() ?? 0) - (ys.min() ?? 0))
        }
    }
}

enum CadError: LocalizedError {
    case load(String)

    var errorDescription: String? {
        switch self {
        case .load(let message): return message
        }
    }
}
