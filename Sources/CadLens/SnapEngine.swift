import AppKit

/// What the pointer is about to land on.
///
/// The priority order is AutoCAD's documented one — 端点 > 交点 > 中点 > 圆心 >
/// 象限点 > 垂足 > 最近点 — because distance alone is the wrong rule: "最近点"
/// sits within a thousandth of a pixel of the cursor by construction, so a
/// nearest-wins rule means a click aimed at a corner silently lands millimetres
/// away along the wall. 插入点 sits just below 垂足: a text anchor is a real
/// pick point, but a geometric relation beats it.
enum SnapKind: String, CaseIterable, Codable {
    case endpoint, intersection, midpoint, center, perpendicular, tangent, nearest

    var title: String {
        switch self {
        case .endpoint: return "端点"
        case .intersection: return "交点"
        case .midpoint: return "中点"
        case .center: return "圆心"
        case .perpendicular: return "垂足"
        case .tangent: return "切点"
        case .nearest: return "最近点"
        }
    }

    /// 垂足和切点是对"从上一个点出发"才有意义的捕捉：没有起点就无从谈起
    /// 垂直和相切。它们只在测量/标注过程中参与解算。
    var needsReference: Bool { self == .perpendicular || self == .tangent }

    /// Higher wins. Ties are broken by distance.
    var priority: Int {
        switch self {
        case .endpoint: return 100
        case .intersection: return 95
        case .midpoint: return 90
        case .center: return 85
        case .perpendicular: return 75
        case .tangent: return 70
        // 最近点永远排在最后：它离光标最近是构造出来的，不能拿距离去和端点
        // 争——"瞄墙角却落在墙上偏了一厘米"就是这么来的。只有附近没有别的
        // 目标时它才接手，负责把点吸到线上。
        case .nearest: return 60
        }
    }
}

/// Which of the eight targets are armed. Persisted with the rest of the
/// settings, and global — one set applies to measuring, calibrating and every
/// tool that comes later, exactly like AutoCAD's running object snap.
struct SnapModes: Codable, Equatable {
    var endpoint = true
    var midpoint = true
    var center = true
    var intersection = true
    /// 垂足/切点只在有起点（测量过程中）时参与解算，见 `SnapKind.needsReference`。
    var perpendicular = true
    var tangent = true
    /// 最近点：把落点吸到线上（墙中线、梁边这类没有端点可用的地方）。
    var nearest = true

    func isEnabled(_ kind: SnapKind) -> Bool {
        switch kind {
        case .endpoint: return endpoint
        case .midpoint: return midpoint
        case .center: return center
        case .intersection: return intersection
        case .perpendicular: return perpendicular
        case .tangent: return tangent
        case .nearest: return nearest
        }
    }

    mutating func set(_ kind: SnapKind, _ on: Bool) {
        switch kind {
        case .endpoint: endpoint = on
        case .midpoint: midpoint = on
        case .center: center = on
        case .intersection: intersection = on
        case .perpendicular: perpendicular = on
        case .tangent: tangent = on
        case .nearest: nearest = on
        }
    }

    var anyEnabled: Bool { SnapKind.allCases.contains { isEnabled($0) } }

    /// 只留端点/中点/圆心/交点：不想让垂足、切点插手时的那一档。
    static var basic: SnapModes {
        var modes = SnapModes()
        modes.perpendicular = false
        modes.tangent = false
        modes.nearest = false
        return modes
    }

    /// The default set. Kept as `standard` so preferences written by earlier
    /// builds still decode.
    static var standard: SnapModes { SnapModes() }

    /// Hand-written so a preference blob from the build that also carried
    /// 象限点/插入点/最近点 still decodes instead of resetting every toggle.
    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try container.decodeIfPresent(Bool.self, forKey: .endpoint) ?? true
        midpoint = try container.decodeIfPresent(Bool.self, forKey: .midpoint) ?? true
        center = try container.decodeIfPresent(Bool.self, forKey: .center) ?? true
        intersection = try container.decodeIfPresent(Bool.self, forKey: .intersection) ?? true
        perpendicular = try container.decodeIfPresent(Bool.self, forKey: .perpendicular) ?? true
        tangent = try container.decodeIfPresent(Bool.self, forKey: .tangent) ?? true
        nearest = try container.decodeIfPresent(Bool.self, forKey: .nearest) ?? true
    }
}

struct SnapResult {
    var point: CGPoint
    var kind: SnapKind
    /// 少数捕捉目标不属于那六种标准类型（例如多边形的闭合点），单独的标题
    /// 比硬塞进 `SnapKind` 干净：那六种是用户的开关项，多一个就多一栏菜单。
    var title: String?
    var label: String { title ?? kind.title }
}

/// Running object snap, resolved against the spatial index around the cursor.
///
/// Modelled on the reference implementation (`SnapEngine::findSnap`): a search
/// square of the snap aperture, every enabled target family inside it, then
/// priority-then-distance selection. Geometry that a dimension drew for itself
/// is skipped outright — see `EntityFlags.dimension`.
struct SnapEngine {
    let document: CadDocument
    let space: Int32
    let modes: SnapModes
    /// 尺寸标注的短斜线/箭头长度上限（世界单位）。图纸自带标注不是完全
    /// 不参与捕捉：长尺寸线、界线可以吸；只有这些短墨迹的端点要跳过，
    /// 否则它们离墙角只有几个像素，量出来差一个斜杠。
    var dimensionTickLength: CGFloat = 0

    func findSnap(near world: CGPoint, tolerance: CGFloat,
                  from reference: CGPoint? = nil) -> SnapResult? {
        findSnapCandidates(near: world, tolerance: tolerance, from: reference).first
    }

    /// 同一孔径内的全部候选，按“语义优先级 → 距离”排序。Tab 循环捕捉
    /// 需要它：密集图里两个端点只差几个像素，谁都无法替用户决定是哪个。
    func findSnapCandidates(near world: CGPoint, tolerance: CGFloat,
                            from reference: CGPoint? = nil) -> [SnapResult] {
        guard modes.anyEnabled, tolerance > 0 else { return [] }
        let rect = CGRect(x: world.x - tolerance, y: world.y - tolerance,
                          width: tolerance * 2, height: tolerance * 2)
        let candidates = document.index(for: space).query(rect)

        var found: [(result: SnapResult, rank: Int, distance: CGFloat)] = []
        // Segments close enough to the cursor to take part in an intersection
        // test, together with the entity they came from (a segment never
        // intersects its own neighbour usefully — they share a vertex).
        var nearby: [(a: CGPoint, b: CGPoint, entity: Int)] = []
        nearby.reserveCapacity(256)

        func consider(_ point: CGPoint, _ kind: SnapKind) {
            guard modes.isEnabled(kind) else { return }
            // 垂足/切点需要一个起点才成立；没有起点时它们静默不参与，
            // 免得光标停在任意一条线上就冒出"垂足"。
            guard !kind.needsReference || reference != nil else { return }
            let distance = hypot(point.x - world.x, point.y - world.y)
            guard distance <= tolerance else { return }
            found.append((SnapResult(point: point, kind: kind), kind.priority, distance))
        }

        func considerSegment(_ a: CGPoint, _ b: CGPoint, _ entityIndex: Int) {
            let dx = b.x - a.x, dy = b.y - a.y
            let length = hypot(dx, dy)
            guard length > 1e-9 else { return }

            consider(a, .endpoint)
            consider(b, .endpoint)
            // A midpoint is only meaningful on a segment a person can see as a
            // segment. Tessellated curves are sampled at a fraction of a point,
            // so their "midpoints" would carpet the whole arc.
            if length > tolerance * 2 {
                consider(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), .midpoint)
            }

            if modes.perpendicular, length > tolerance * 2, let reference {
                // 垂足 is the perpendicular from the *previous pick*, which is
                // what makes it different from 最近点: the user picks a corner
                // and then wants the square-on point on the far wall.
                let foot = closestPointOnSegment(reference, a, b)
                if foot.t > 1e-5, foot.t < 1 - 1e-5 {
                    consider(foot.point, .perpendicular)
                }
            }

            if modes.nearest, length > tolerance * 2 {
                let foot = closestPointOnSegment(world, a, b)
                if foot.t > 1e-4, foot.t < 1 - 1e-4 {
                    consider(foot.point, .nearest)
                }
            }

            if modes.intersection {
                let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                 width: abs(dx), height: abs(dy))
                if box.insetBy(dx: -tolerance, dy: -tolerance).contains(world) {
                    nearby.append((a, b, entityIndex))
                }
            }
        }

        for index in candidates {
            let entityIndex = Int(index)
            guard entityIndex >= 0, entityIndex < document.entities.count else { continue }
            let entity = document.entities[entityIndex]
            guard document.isLayerVisible(entity) else { continue }
            // 图纸自带的标注只跳过“短墨迹”（45° 斜线、箭头等）的端点；
            // 长尺寸线/界线仍然可以捕捉。早先整块 *D 匿名块都不参与，用户
            // 想吸标注界线也吸不到。
            let dimensionInk = entity.isDimensionInk

            switch entity.kind {
            case .point:
                consider(CGPoint(x: entity.cx, y: entity.cy), .endpoint)
            case .text:
                // 文字的插入点不是几何点，测量时吸附到它只会把尺寸挪歪。
                break
            case .circle, .arc:
                consider(CGPoint(x: entity.cx, y: entity.cy), .center)
                if modes.nearest, entity.r > 1e-9 {
                    // 圆周上的最近点：从圆心朝光标的半径方向落一点。弧还要
                    // 落在它自己的张角范围内，否则会吸到一段并不存在的圆上。
                    let angle = atan2(Double(world.y - entity.cy), Double(world.x - entity.cx))
                    let onArc: Bool
                    if entity.kind == .circle {
                        onArc = true
                    } else {
                        let base = Double(entity.a0)
                        var span = (Double(entity.a1) - base)
                        while span <= 0 { span += 2 * .pi }
                        var delta = angle - base
                        while delta < 0 { delta += 2 * .pi }
                        onArc = delta <= span + 1e-6
                    }
                    if onArc {
                        consider(CGPoint(x: entity.cx + entity.r * cos(angle),
                                         y: entity.cy + entity.r * sin(angle)), .nearest)
                    }
                }
                if modes.tangent, entity.r > 0, let reference {
                    // 从起点向圆引切线：切点 = 圆心 + r·(方向 ± 张角)，张角
                    // acos(r/d)。点在圆内时无切线，自然跳过。
                    let dx = reference.x - entity.cx, dy = reference.y - entity.cy
                    let distance = hypot(dx, dy)
                    if distance > entity.r + 1e-9 {
                        let base = atan2(dy, dx)
                        let spread = acos(min(1, entity.r / distance))
                        for sign in [-1.0, 1.0] as [CGFloat] {
                            let angle = base + sign * spread
                            consider(CGPoint(x: entity.cx + entity.r * cos(angle),
                                             y: entity.cy + entity.r * sin(angle)), .tangent)
                        }
                    }
                }
            case .line, .polyline, .solid:
                let slice = document.points(for: entity)
                guard slice.count >= 2 else { continue }
                // Interior vertices are the segment ends of a polygon outline
                // and a drafter does aim at them. A tessellated curve has
                // hundreds of vertices that no one ever picked, so only short
                // polylines get their vertices exposed as 端点.
                let exposeVertices = slice.count <= 32
                for i in (slice.startIndex + 1)..<slice.endIndex {
                    let a = slice[i - 1], b = slice[i]
                    if dimensionInk, dimensionTickLength > 0,
                       hypot(b.x - a.x, b.y - a.y) <= dimensionTickLength {
                        continue
                    }
                    considerSegment(a, b, entityIndex)
                    if exposeVertices, i > slice.startIndex + 1 {
                        consider(a, .endpoint)
                    }
                }
            case .ellipse, .hatch:
                break
            }
        }

        if modes.intersection, nearby.count > 1 {
            let cap = min(nearby.count, 700)
            for a in 0..<cap {
                for b in (a + 1)..<cap {
                    guard nearby[a].entity != nearby[b].entity else { continue }
                    if let point = segmentIntersection(nearby[a].a, nearby[a].b,
                                                       nearby[b].a, nearby[b].b) {
                        consider(point, .intersection)
                    }
                }
            }
        }
        found.sort {
            if $0.rank != $1.rank { return $0.rank > $1.rank }
            return $0.distance < $1.distance
        }
        var unique: [SnapResult] = []
        for item in found {
            if unique.contains(where: {
                hypot($0.point.x - item.result.point.x,
                      $0.point.y - item.result.point.y) < tolerance * 0.01
            }) { continue }
            unique.append(item.result)
            if unique.count >= 32 { break }
        }
        return unique
    }

    private func closestPointOnSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint)
        -> (point: CGPoint, t: CGFloat) {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 1e-12 else { return (a, 0) }
        let raw = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
        let t = max(0, min(1, raw))
        return (CGPoint(x: a.x + t * dx, y: a.y + t * dy), t)
    }

    private func segmentIntersection(_ a1: CGPoint, _ a2: CGPoint,
                                     _ b1: CGPoint, _ b2: CGPoint) -> CGPoint? {
        let rx = a2.x - a1.x, ry = a2.y - a1.y
        let sx = b2.x - b1.x, sy = b2.y - b1.y
        let cross = rx * sy - ry * sx
        guard abs(cross) > 1e-10 else { return nil }   // parallel or collinear
        let qpx = b1.x - a1.x, qpy = b1.y - a1.y
        let t = (qpx * sy - qpy * sx) / cross
        let u = (qpx * ry - qpy * rx) / cross
        guard t > -1e-8, t < 1 + 1e-8, u > -1e-8, u < 1 + 1e-8 else { return nil }
        return CGPoint(x: a1.x + rx * t, y: a1.y + ry * t)
    }
}
