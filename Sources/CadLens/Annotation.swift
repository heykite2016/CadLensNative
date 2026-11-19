import AppKit
import CryptoKit

enum MeasureKind: String, Codable, CaseIterable {
    case aligned, linear, continuous, batch, rectangle, polygon
    case circleArea, hatchArea, radius, angle, arcLength, sideArea, note

    var title: String {
        switch self {
        case .aligned: return "对齐"
        case .linear: return "线性"
        case .continuous: return "连续"
        case .batch: return "快速标注"
        case .rectangle: return "矩形"
        case .polygon: return "多边形"
        case .circleArea: return "圆面积"
        case .hatchArea: return "填充"
        case .radius: return "半径"
        case .angle: return "角度"
        case .arcLength: return "弧长"
        case .sideArea: return "侧面积"
        case .note: return "注释"
        }
    }

    /// One-word caption used by the palettes and the command line completion.
    var shortTitle: String { title }

    var symbolName: String {
        switch self {
        case .aligned: return "ruler"
        case .linear: return "arrow.left.and.right"
        case .continuous: return "point.topleft.down.curvedto.point.bottomright.up"
        case .batch: return "square.stack.3d.down.right"
        case .rectangle: return "rectangle.dashed"
        case .polygon: return "hexagon"
        case .circleArea: return "circle.dashed"
        case .hatchArea: return "square.fill.on.square.fill"
        case .radius: return "circle.and.line.horizontal"
        case .angle: return "angle"
        case .arcLength: return "arrow.triangle.2.circlepath"
        case .sideArea: return "square.stack.3d.up"
        case .note: return "text.bubble"
        }
    }

    var isArea: Bool {
        self == .rectangle || self == .polygon || self == .circleArea
            || self == .hatchArea || self == .sideArea
    }

    var isLength: Bool {
        self == .aligned || self == .linear || self == .continuous
            || self == .batch || self == .radius || self == .arcLength
    }

    /// Shown as the group caption in the annotation panel.
    var groupTitle: String {
        if isLength { return "长度" }
        if isArea { return "面积" }
        if self == .angle { return "角度" }
        return "注释"
    }

    /// One line that explains what the number is good for.
    var purpose: String {
        switch self {
        case .aligned: return "两点间实际距离"
        case .linear: return "沿水平或竖直方向的投影距离"
        case .continuous: return "多段连续尺寸的链式累加"
        case .batch: return "QDIM 式框选：预览后一次放置多条尺寸"
        case .rectangle: return "矩形区域的地面/顶面面积"
        case .polygon: return "任意闭合区域的面积，用于房间、吊顶"
        case .circleArea: return "圆或圆弧围合面积"
        case .hatchArea: return "直接取图内填充图案的围合面积"
        case .radius: return "圆弧上三点反算圆心与半径"
        case .angle: return "三点夹角的度数"
        case .arcLength: return "三点确定的圆弧长度"
        case .sideArea: return "长度 × 高度，用于墙面、踢脚线"
        case .note: return "现场文字备注"
        }
    }

    /// Number of clicks needed before the annotation is complete.
    var requiredPoints: Int {
        switch self {
        case .aligned, .linear, .batch, .rectangle: return 2
        case .angle: return 3
        // 半径与圆面积都通过圆弧上的三点反算圆心和半径；半径不需要先知道
        // 圆心在哪儿，现场量弧时也点不到圆心。
        case .radius, .arcLength, .circleArea: return 3
        // 侧面积量的是"一段墙的长度 × 层高"，墙往往由几段折线组成，所以它和
        // 连续尺寸一样是多点工具：点完按回车 / 右键结束，再输入高度。
        case .continuous, .polygon, .sideArea: return Int.max
        // 填充是"在闭合区域里点一下"，不是多点工具。归到 Int.max 会让工具栏
        // 提示和说明窗口都写成"多点，右键结束"，用户会去点轮廓而不是点中间。
        case .hatchArea, .note: return 1
        }
    }

    /// AutoCAD-style command aliases, typed into the command line.
    var aliases: [String] {
        switch self {
        case .aligned: return ["al", "dal", "dimaligned"]
        case .linear: return ["dli", "dimlinear", "ln"]
        case .continuous: return ["dco", "dimcontinue", "co"]
        case .batch: return ["qdim", "batchdim"]
        case .rectangle: return ["rec", "ra", "rectarea"]
        case .polygon: return ["aa", "ar", "area", "pl"]
        case .circleArea: return ["ca", "circlearea"]
        case .hatchArea: return ["ha", "hatch", "fa"]
        case .sideArea: return ["sa", "side"]
        case .radius: return ["dra", "dimradius", "r"]
        case .angle: return ["dan", "dimangle", "ang"]
        case .arcLength: return ["dar", "dimarc", "arc"]
        case .note: return ["t", "text", "tx"]
        }
    }
}

struct Annotation: Codable, Identifiable {
    var id: UUID = UUID()
    var kind: MeasureKind
    var space: Int32
    var points: [CGPoint]
    var value: Double = 0
    var secondaryValue: Double = 0
    /// 闭合图形的周长（图纸单位）。面积与周长是一对：图上只标面积，施工方
    /// 还得自己拿边长算一圈抹灰，所以面积类标注两样都写。0 表示这条标注
    /// 没有周长概念（长度标注、角度标注），或由旧版本存盘而来。
    var perimeter: Double = 0
    /// 圆弧段的加密路径（图纸坐标）。空表示全程直线——绝大多数标注都是这种，
    /// 存一份和 points 重复的路径没有意义。
    var path: [CGPoint] = []
    /// 相邻两个拾取点之间的真实长度（图纸单位）。直线段等于两点距离，圆弧段
    /// 是弧长；渲染器用它标每一段的尺寸，而不是拿弦长糊弄过去。
    var segmentLengths: [Double] = []
    var angle: Double = 0
    var text: String = ""
    /// Free-form remark typed by the user; kept separate from the measured
    /// value so re-measuring never destroys a note.
    var note: String? = nil
    var labelOffset: CGPoint = .zero
    var createdAt: Date = Date()
    /// Per-annotation overrides. `nil` means "follow the drawing settings",
    /// which keeps old sidecar files readable and lets one global style change
    /// update every measurement that was never customised.
    var styleKey: String? = nil
    var colorHex: String? = nil
    /// Text the user typed over the computed value (dimension text override).
    var labelOverride: String? = nil
    var hidden: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, kind, space, points, value, secondaryValue, angle, text, note
        case labelOffset, createdAt, styleKey, colorHex, labelOverride, hidden
        case perimeter, path, segmentLengths
    }

    init(kind: MeasureKind, space: Int32, points: [CGPoint]) {
        self.kind = kind
        self.space = space
        self.points = points
    }

    /// Hand-written so a sidecar written by an earlier build — which has none
    /// of the style fields — still decodes instead of throwing away every
    /// measurement on the drawing.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decode(MeasureKind.self, forKey: .kind)
        space = try container.decodeIfPresent(Int32.self, forKey: .space) ?? 0
        points = try container.decodeIfPresent([CGPoint].self, forKey: .points) ?? []
        value = try container.decodeIfPresent(Double.self, forKey: .value) ?? 0
        secondaryValue = try container.decodeIfPresent(Double.self, forKey: .secondaryValue) ?? 0
        perimeter = try container.decodeIfPresent(Double.self, forKey: .perimeter) ?? 0
        path = try container.decodeIfPresent([CGPoint].self, forKey: .path) ?? []
        segmentLengths = try container.decodeIfPresent([Double].self, forKey: .segmentLengths) ?? []
        angle = try container.decodeIfPresent(Double.self, forKey: .angle) ?? 0
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        note = try container.decodeIfPresent(String.self, forKey: .note)
        labelOffset = try container.decodeIfPresent(CGPoint.self, forKey: .labelOffset) ?? .zero
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        styleKey = try container.decodeIfPresent(String.self, forKey: .styleKey)
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex)
        labelOverride = try container.decodeIfPresent(String.self, forKey: .labelOverride)
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }

    /// The string actually painted on the sheet.
    var displayText: String {
        if let labelOverride, !labelOverride.isEmpty { return labelOverride }
        return text
    }

    var center: CGPoint {
        guard !points.isEmpty else { return .zero }
        var x: CGFloat = 0, y: CGFloat = 0
        for p in points { x += p.x; y += p.y }
        return CGPoint(x: x / CGFloat(points.count), y: y / CGFloat(points.count))
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        for (index, p) in points.enumerated() {
            if hypot(p.x - point.x, p.y - point.y) <= tolerance { return true }
            if index > 0 {
                let a = points[index - 1]
                if MeasurementMath.distanceToSegment(point, a, p) <= tolerance {
                    return true
                }
            }
        }
        if hypot(center.x - point.x, center.y - point.y) <= tolerance * 1.5 { return true }
        return false
    }
}

enum MeasurementMath {
    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

    static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        if lengthSquared < 1e-9 { return distance(p, a) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
        t = max(0, min(1, t))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    static func polygonArea(_ points: [CGPoint]) -> CGFloat {
        guard points.count > 2 else { return 0 }
        var sum: CGFloat = 0
        for i in 0..<points.count {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    /// 带符号面积：外环与洞的环向相反时可以直接相加。仅作为
    /// `netArea(rings:)` 的兜底，不假设所有生产者都按环向标记洞。
    static func signedPolygonArea(_ points: [CGPoint]) -> CGFloat {
        guard points.count > 2 else { return 0 }
        var sum: CGFloat = 0
        for i in 0..<points.count {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    /// 射线法：点是否在环内。环可以是不闭合的顶点数组。
    static func pointInPolygon(_ point: CGPoint, _ ring: [CGPoint]) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.y > point.y) != (b.y > point.y) {
                let x = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
                if point.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// 环内代表点：先取顶点均值；凹多边形均值落在外面时，换连续三点的
    /// 重心。只用于判断“这个环被几个环包住”，不需要严格的最深点。
    static func interiorPoint(_ ring: [CGPoint]) -> CGPoint {
        guard !ring.isEmpty else { return .zero }
        var x: CGFloat = 0, y: CGFloat = 0
        for point in ring { x += point.x; y += point.y }
        let average = CGPoint(x: x / CGFloat(ring.count), y: y / CGFloat(ring.count))
        if pointInPolygon(average, ring) { return average }
        if ring.count >= 3 {
            for i in 0..<ring.count {
                let a = ring[i]
                let b = ring[(i + 1) % ring.count]
                let c = ring[(i + 2) % ring.count]
                let centre = CGPoint(x: (a.x + b.x + c.x) / 3,
                                     y: (a.y + b.y + c.y) / 3)
                if pointInPolygon(centre, ring) { return centre }
            }
        }
        return ring[0]
    }

    /// 多环闭合区域的净面积：偶数层外环加，奇数层洞减。
    ///
    /// 不能把每个环的绝对值直接相加——带柱洞、井道的房间会把洞的面积
    /// 也算进去；也不能只信环向，DXF/DWG 生产者并不总是把洞反向。
    static func netArea(rings: [[CGPoint]]) -> CGFloat {
        guard !rings.isEmpty else { return 0 }
        var total: CGFloat = 0
        for i in rings.indices {
            // 用环上的顶点做探测点，而不是顶点均值：外环的均值可能正好落
            // 在中间的洞里，深度会算反（外环被当成洞减掉）。
            let probe = rings[i].first ?? .zero
            var depth = 0
            for j in rings.indices where j != i {
                if pointInPolygon(probe, rings[j]) { depth += 1 }
            }
            let area = abs(polygonArea(rings[i]))
            total += depth % 2 == 0 ? area : -area
        }
        return max(0, total)
    }

    static func pathLength(_ points: [CGPoint], closed: Bool) -> CGFloat {
        guard points.count > 1 else { return 0 }
        var total: CGFloat = 0
        for i in 1..<points.count { total += distance(points[i - 1], points[i]) }
        if closed, let first = points.first, let last = points.last {
            total += distance(last, first)
        }
        return total
    }

    static func angle(_ a: CGPoint, vertex: CGPoint, _ b: CGPoint) -> CGFloat {
        let v1 = CGPoint(x: a.x - vertex.x, y: a.y - vertex.y)
        let v2 = CGPoint(x: b.x - vertex.x, y: b.y - vertex.y)
        let dot = v1.x * v2.x + v1.y * v2.y
        let m1 = hypot(v1.x, v1.y)
        let m2 = hypot(v2.x, v2.y)
        guard m1 > 1e-9, m2 > 1e-9 else { return 0 }
        return acos(max(-1, min(1, dot / (m1 * m2))))
    }

    /// Circle through three points; returns nil when they are collinear.
    static func circleThrough(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint)
        -> (center: CGPoint, radius: CGFloat)? {
        let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
        if abs(d) < 1e-9 { return nil }
        let aSq = a.x * a.x + a.y * a.y
        let bSq = b.x * b.x + b.y * b.y
        let cSq = c.x * c.x + c.y * c.y
        let ux = (aSq * (b.y - c.y) + bSq * (c.y - a.y) + cSq * (a.y - b.y)) / d
        let uy = (aSq * (c.x - b.x) + bSq * (a.x - c.x) + cSq * (b.x - a.x)) / d
        let center = CGPoint(x: ux, y: uy)
        return (center, distance(center, a))
    }

    /// Arc length through three points, following the arc that passes b.
    static func arcLength(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        guard let circle = circleThrough(a, b, c) else { return distance(a, c) }
        let startAngle = atan2(a.y - circle.center.y, a.x - circle.center.x)
        let midAngle = atan2(b.y - circle.center.y, b.x - circle.center.x)
        let endAngle = atan2(c.y - circle.center.y, c.x - circle.center.x)
        func normalize(_ x: CGFloat) -> CGFloat {
            var value = x
            while value < 0 { value += 2 * .pi }
            while value >= 2 * .pi { value -= 2 * .pi }
            return value
        }
        let s = normalize(startAngle), m = normalize(midAngle), e = normalize(endAngle)
        let sweepForward = normalize(e - s)
        let midForward = normalize(m - s)
        let sweep = midForward <= sweepForward ? sweepForward : (2 * .pi - sweepForward)
        return circle.radius * sweep
    }
}

enum AnnotationStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let url = base.appendingPathComponent("CadLensNative/annotations",
                                              isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func key(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    static func load(for url: URL) -> [Annotation] {
        let file = directory.appendingPathComponent(key(for: url) + ".json")
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Annotation].self, from: data)) ?? []
    }

    static func clear(for url: URL) {
        let file = directory.appendingPathComponent(key(for: url) + ".json")
        try? FileManager.default.removeItem(at: file)
    }

    static func save(_ annotations: [Annotation], for url: URL) {
        let file = directory.appendingPathComponent(key(for: url) + ".json")
        guard let data = try? JSONEncoder().encode(annotations) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

/// User preferences that survive launches, mirroring the original settings panel.
struct CadSettings: Codable {
    var displayUnit: MeasureUnit = .millimeter
    /// 面积单位独立于长度单位：长度标毫米、面积标平方米是施工图的常态。
    var areaUnit: AreaUnit = .squareMeter
    var precision: Int = 0
    var showLineweights: Bool = true
    var showGrid: Bool = false
    var showCrosshair: Bool = true
    var objectSnap: Bool = true
    var orthoMode: Bool = false
    var dimensionColorIndex: Int = 0
    /// Ink for new dimensions, `#RRGGBB`. Empty means the style default.
    var annotationColorHex: String = ""
    var canvasQuality: Int = 1  // 0 fast, 1 balanced, 2 best
    /// 0 follows the system, 1 forces light, 2 forces dark.
    var appearance: Int = 0
    /// Active dimension style (`AnnotationStyle.rawValue`).
    var annotationStyle: String = AnnotationStyle.architectural.rawValue
    /// 尺寸线端符：`AnnotationMarker.rawValue`，空串表示跟随标注样式。
    var annotationMarker: String = ""
    /// When true annotations scale with the drawing like DIMENSION entities;
    /// when false they keep a constant, readable screen size.
    var annotationScalesWithDrawing: Bool = false
    /// Which object-snap targets are armed. Global: one set applies to
    /// measuring, calibrating and every tool after them.
    var snapModes: SnapModes = .standard

    static let defaultsKey = "CadSettings.v1"

    init() {}

    enum CodingKeys: String, CodingKey {
        case displayUnit, precision, showLineweights, showGrid, showCrosshair
        case objectSnap, orthoMode, dimensionColorIndex, canvasQuality, appearance
        case annotationColorHex
        case annotationStyle, annotationScalesWithDrawing, annotationMarker
        case snapModes
        case areaUnit
    }

    /// Tolerant decoding: a preferences blob written before the style fields
    /// existed must not reset the user's snap and unit choices.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayUnit = try container.decodeIfPresent(MeasureUnit.self, forKey: .displayUnit)
            ?? .millimeter
        areaUnit = try container.decodeIfPresent(AreaUnit.self, forKey: .areaUnit) ?? .squareMeter
        precision = try container.decodeIfPresent(Int.self, forKey: .precision) ?? 0
        showLineweights = try container.decodeIfPresent(Bool.self, forKey: .showLineweights) ?? true
        showGrid = try container.decodeIfPresent(Bool.self, forKey: .showGrid) ?? false
        showCrosshair = try container.decodeIfPresent(Bool.self, forKey: .showCrosshair) ?? true
        objectSnap = try container.decodeIfPresent(Bool.self, forKey: .objectSnap) ?? true
        orthoMode = try container.decodeIfPresent(Bool.self, forKey: .orthoMode) ?? false
        dimensionColorIndex = try container.decodeIfPresent(Int.self, forKey: .dimensionColorIndex) ?? 0
        annotationColorHex = try container.decodeIfPresent(String.self,
                                                           forKey: .annotationColorHex) ?? ""
        canvasQuality = try container.decodeIfPresent(Int.self, forKey: .canvasQuality) ?? 1
        appearance = try container.decodeIfPresent(Int.self, forKey: .appearance) ?? 0
        annotationStyle = try container.decodeIfPresent(String.self, forKey: .annotationStyle)
            ?? AnnotationStyle.architectural.rawValue
        annotationScalesWithDrawing = try container.decodeIfPresent(
            Bool.self, forKey: .annotationScalesWithDrawing) ?? false
        annotationMarker = try container.decodeIfPresent(String.self,
                                                         forKey: .annotationMarker) ?? ""
        snapModes = try container.decodeIfPresent(SnapModes.self, forKey: .snapModes)
            ?? .standard
    }

    static func load() -> CadSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(CadSettings.self, from: data)
        else { return CadSettings() }
        return settings
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: CadSettings.defaultsKey)
    }
}
