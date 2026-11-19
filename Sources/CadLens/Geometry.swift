import Foundation
import CoreGraphics

/// Do two boxes overlap?
///
/// CoreGraphics defines an empty rect as one with zero width *or* zero height,
/// and `CGRect.intersects` returns false whenever either side is empty. A
/// horizontal line has height 0 and a vertical line has width 0, so the
/// obvious `box.intersects(worldRect)` test silently rejected every
/// axis-aligned segment — exactly what walls, dimension lines and extension
/// lines are made of. Comparing the edges directly keeps degenerate boxes
/// (segments and points) visible.
func cadBoxesOverlap(_ a: CGRect, _ b: CGRect) -> Bool {
    guard !a.isNull, !b.isNull else { return false }
    return a.minX <= b.maxX && a.maxX >= b.minX
        && a.minY <= b.maxY && a.maxY >= b.minY
}

/// Ramer–Douglas–Peucker simplification in drawing coordinates.
///
/// The reference reader samples every circle/arc/ellipse at a fixed π/48
/// (CadModel.cpp::sampleArc) and then simplifies those polylines against a
/// screen-space tolerance in CadView.cpp::simplifyScreenPolyline before
/// stroking. Skipping that second step uploads ~96 edges for a circle that is
/// ten pixels wide, which is both slower and no more accurate than the eight
/// chords a 0.35 px tolerance keeps. Both the CG and the GPU renderer call this
/// with `tolerance = screenTolerance / cameraScale`.
func cadSimplify(_ points: [CGPoint], tolerance: CGFloat, closed: Bool) -> [CGPoint] {
    guard points.count > 3, tolerance > 0 else { return points }
    let toleranceSquared = tolerance * tolerance
    if !closed { return cadRDP(points, toleranceSquared) }

    // A closed ring has no natural first/last chord. Split it at the vertex
    // farthest from the first point, simplify both open chains, then join.
    let origin = points[0]
    var farthest = 1
    var farthestDistance = -1.0
    for i in 1..<points.count {
        let dx = points[i].x - origin.x, dy = points[i].y - origin.y
        let distance = dx * dx + dy * dy
        if distance > farthestDistance {
            farthestDistance = distance
            farthest = i
        }
    }
    let head = cadRDP(Array(points[0...farthest]), toleranceSquared)
    var tail = Array(points[farthest..<points.count])
    tail.append(origin)
    let simplifiedTail = cadRDP(tail, toleranceSquared)
    var result = head
    if simplifiedTail.count > 2 {
        result.append(contentsOf: simplifiedTail.dropFirst().dropLast())
    }
    return result
}

private func cadRDP(_ points: [CGPoint], _ toleranceSquared: CGFloat) -> [CGPoint] {
    guard points.count > 2 else { return points }
    var keep = [Bool](repeating: false, count: points.count)
    keep[0] = true
    keep[points.count - 1] = true
    var stack: [(Int, Int)] = [(0, points.count - 1)]

    while let (start, end) = stack.popLast() {
        guard end > start + 1 else { continue }
        let a = points[start], b = points[end]
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        var bestIndex = -1
        var bestDistance = toleranceSquared
        for i in (start + 1)..<end {
            let p = points[i]
            let distanceSquared: CGFloat
            if lengthSquared < 1e-12 {
                let ex = p.x - a.x, ey = p.y - a.y
                distanceSquared = ex * ex + ey * ey
            } else {
                var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
                t = max(0, min(1, t))
                let ex = p.x - (a.x + t * dx), ey = p.y - (a.y + t * dy)
                distanceSquared = ex * ex + ey * ey
            }
            if distanceSquared > bestDistance {
                bestDistance = distanceSquared
                bestIndex = i
            }
        }
        if bestIndex > 0 {
            keep[bestIndex] = true
            stack.append((start, bestIndex))
            stack.append((bestIndex, end))
        }
    }
    return points.indices.filter { keep[$0] }.map { points[$0] }
}
