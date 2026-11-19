import Foundation
import CadCore

func dumpLayer(_ doc: OpaquePointer, name: String) {
    guard let entitiesPtr = cad_doc_entities(doc),
          let layersPtr = cad_doc_layers(doc),
          let textPtr = cad_doc_text(doc),
          let pointsPtr = cad_doc_points(doc) else { return }
    var target: Int32 = -1
    for i in 0..<Int(cad_doc_layer_count(doc)) {
        if String(cString: textPtr + Int(layersPtr[i].name_start)) == name {
            target = Int32(i)
        }
    }
    guard target >= 0 else { print("no such layer: \(name)"); return }
    for i in 0..<Int(cad_doc_entity_count(doc)) {
        let e = entitiesPtr[i]
        guard e.layer == target else { continue }
        var geometry = ""
        if e.pcount > 0 && e.pcount < 400 {
            var pts: [String] = []
            for k in 0..<Int(e.pcount) {
                let p = pointsPtr[Int(e.pstart) + k]
                pts.append(String(format: "(%.3f,%.3f)", p.x, p.y))
            }
            geometry = pts.joined(separator: " ")
        } else {
            geometry = String(format: "c=(%.2f,%.2f) r=%.3f a0=%.1f a1=%.1f",
                              e.cx, e.cy, e.r, e.a0, e.a1)
        }
        print(String(format: "#%d kind=%d pts=%d %@", i, e.kind, e.pcount,
                     geometry as NSString))
    }
}

func describe(_ path: String, layer: String?, outliers: Bool = false, big: Bool = false,
              texts: Bool = false, viewports: Bool = false, layoutBoxes: Bool = false, spaceHist: Bool = false, handles: Bool = false,
              dump: Bool = false) {
    var error: UnsafeMutablePointer<CChar>? = nil
    let started = Date()
    guard let doc = path.withCString({ cad_doc_load($0, &error) }) else {
        let message = error.map { String(cString: $0) } ?? "unknown error"
        print("load failed: \(message)")
        return
    }
    defer { cad_doc_free(doc) }

    let elapsed = Date().timeIntervalSince(started) * 1000
    let version = String(cString: cad_doc_version(doc))
    let backend = String(cString: cad_doc_backend(doc))
    print("file     : \(path)")
    print("version  : \(version)  backend: \(backend)")
    print("load     : \(String(format: "%.1f", elapsed)) ms (core \(String(format: "%.1f", cad_doc_load_ms(doc))) ms)")

    let entityCount = Int(cad_doc_entity_count(doc))
    let layers = Int(cad_doc_layer_count(doc))
    let spaces = Int(cad_doc_space_count(doc))
    let points = Int(cad_doc_point_count(doc))
    let hatches = Int(cad_doc_hatch_count(doc))
    let rings = Int(cad_doc_ring_count(doc))
    let viewportCount = Int(cad_doc_viewport_count(doc))
    print("entities : \(entityCount)  points: \(points)  hatches: \(hatches)  rings: \(rings)")
    print("layers   : \(layers)  spaces: \(spaces)  viewports: \(viewportCount)  skipped: \(cad_doc_skipped(doc))")

    if let layerPtr = cad_doc_layers(doc), let textPtr = cad_doc_text(doc) {
        var hidden = 0
        for i in 0..<layers {
            let layer = layerPtr[i]
            let name = String(cString: textPtr + Int(layer.name_start))
            if layer.flags & Int32(CAD_LAYER_OFF) != 0 { hidden += 1 }
            if i < 6 || layers <= 24 {
                print(String(format: "  layer %-16@ aci=%2d lw=%.2f flags=%d count=%d",
                             name as NSString,
                             Int((layer.rgb >> 24) & 0xFF),
                             layer.lineweight, layer.flags, layer.count))
            }
        }
        print("  ... hidden layers: \(hidden)")
    }

    if let spacesPtr = cad_doc_spaces(doc), let textPtr = cad_doc_text(doc) {
        for i in 0..<spaces {
            let space = spacesPtr[i]
            let name = String(cString: textPtr + Int(space.name_start))
            print(String(format: "  space %d: %@ entities=%d bbox=(%.1f,%.1f)-(%.1f,%.1f)",
                         i, name as NSString, space.entity_count,
                         space.box.minx, space.box.miny, space.box.maxx, space.box.maxy))
        }
    }

    if let entitiesPtr = cad_doc_entities(doc), let textPtr = cad_doc_text(doc) {
        var byKind: [Int32: Int] = [:]
        for i in 0..<entityCount {
            let e = entitiesPtr[i]
            byKind[e.kind, default: 0] += 1
            if i < 5 {
                var label = "line"
                switch e.kind {
                case Int32(CAD_POLYLINE.rawValue): label = "pline"
                case Int32(CAD_CIRCLE.rawValue): label = "circle"
                case Int32(CAD_ARC.rawValue): label = "arc"
                case Int32(CAD_ELLIPSE.rawValue): label = "ellipse"
                case Int32(CAD_TEXT.rawValue):
                    label = "text"
                    if e.tstart >= 0 {
                        let text = String(cString: textPtr + Int(e.tstart))
                        label = "text \"\(text.prefix(24))\""
                    }
                case Int32(CAD_HATCH.rawValue): label = "hatch"
                case Int32(CAD_SOLID.rawValue): label = "solid"
                case Int32(CAD_POINT.rawValue): label = "point"
                default: label = "kind\(e.kind)"
                }
                print(String(format: "  #%d %@ layer=%d rgb=%06X pts=%d box=(%.2f,%.2f)-(%.2f,%.2f)",
                             i, label as NSString, e.layer, e.rgb & 0xFFFFFF, e.pcount,
                             e.box.minx, e.box.miny, e.box.maxx, e.box.maxy))
            }
        }
        let names: [Int32: String] = [1: "line", 2: "pline", 3: "circle", 4: "arc",
                                      5: "ellipse", 6: "text", 7: "hatch", 8: "point", 9: "solid"]
        let summary = byKind.sorted { $0.key < $1.key }
            .map { "\(names[$0.key] ?? "\($0.key)")=\($0.value)" }
            .joined(separator: " ")
        print("  kinds: \(summary)")
    }

    if let hatchesPtr = cad_doc_hatches(doc), let ringsPtr = cad_doc_rings(doc),
       let pointsPtr = cad_doc_points(doc) {
        let hatchCount = Int(cad_doc_hatch_count(doc))
        for h in 0..<min(hatchCount, 16) {
            let hatch = hatchesPtr[h]
            var rings = ""
            for r in 0..<Int(hatch.ringcount) {
                let ring = ringsPtr[Int(hatch.ringstart) + r]
                var box = (1e300, 1e300, -1e300, -1e300)
                for k in 0..<Int(ring.pcount) {
                    let p = pointsPtr[Int(ring.pstart) + k]
                    box.0 = min(box.0, p.x)
                    box.1 = min(box.1, p.y)
                    box.2 = max(box.2, p.x)
                    box.3 = max(box.3, p.y)
                }
                rings += String(format: " ring%d=%dpts (%.2f,%.2f)-(%.2f,%.2f)",
                                r, ring.pcount, box.0, box.1, box.2, box.3)
            }
            print(String(format: "  hatch %d solid=%d style=%d defs=%d angle=%.1f scale=%.2f%@",
                         h, hatch.solid, hatch.style, hatch.defcount,
                         hatch.angle * 180 / .pi, hatch.scale, rings as NSString))
        }
    }

    if let layer { dumpLayer(doc, name: layer) }

    if outliers, let entitiesPtr = cad_doc_entities(doc), let textPtr = cad_doc_text(doc) {
        var boxes: [(Int, cad_entity)] = []
        boxes.reserveCapacity(entityCount)
        for i in 0..<entityCount {
            let e = entitiesPtr[i]
            if e.box.minx > e.box.maxx { continue }
            boxes.append((i, e))
        }
        func percentile(_ values: [Double], _ p: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let index = Int(Double(sorted.count - 1) * p)
            return sorted[index]
        }
        let xs = boxes.flatMap { [Double($0.1.box.minx), Double($0.1.box.maxx)] }
        let ys = boxes.flatMap { [Double($0.1.box.miny), Double($0.1.box.maxy)] }
        print(String(format: "  robust extent: x %.2f..%.2f  y %.2f..%.2f (1%%..99%%)",
                     percentile(xs, 0.01), percentile(xs, 0.99),
                     percentile(ys, 0.01), percentile(ys, 0.99)))
        let ranked = boxes.map { item -> (Double, Int, cad_entity) in
            let b = item.1.box
            let d = max(max(abs(Double(b.minx)), abs(Double(b.maxx))),
                        max(abs(Double(b.miny)), abs(Double(b.maxy))))
            return (d, item.0, item.1)
        }.sorted { $0.0 > $1.0 }
        print("  farthest entities:")
        for (distance, index, e) in ranked.prefix(12) {
            var label = "kind\(e.kind)"
            if e.kind == Int32(CAD_TEXT.rawValue), e.tstart >= 0 {
                label = "text \"\(String(cString: textPtr + Int(e.tstart)).prefix(20))\""
            } else if e.kind == Int32(CAD_POLYLINE.rawValue) { label = "pline" }
            else if e.kind == Int32(CAD_LINE.rawValue) { label = "line" }
            else if e.kind == Int32(CAD_POINT.rawValue) { label = "point" }
            let layerName = e.layer >= 0 && Int(e.layer) < layers
                ? String(cString: textPtr + Int(cad_doc_layers(doc)![Int(e.layer)].name_start))
                : "?"
            print(String(format: "    #%d %-22@ |max|=%.3e box=(%.3e,%.3e)-(%.3e,%.3e) layer=%@",
                         index, label as NSString, distance,
                         e.box.minx, e.box.miny, e.box.maxx, e.box.maxy,
                         layerName as NSString))
        }
    }
    if big, let entitiesPtr = cad_doc_entities(doc), let textPtr = cad_doc_text(doc),
       let pointsPtr = cad_doc_points(doc), let layersPtr = cad_doc_layers(doc) {
        var count = 0
        var byLayer: [String: Int] = [:]
        for i in 0..<entityCount {
            let e = entitiesPtr[i]
            let w = Double(e.box.maxx - e.box.minx)
            let h = Double(e.box.maxy - e.box.miny)
            guard w > 60000 || h > 60000 else { continue }
            let layerName = e.layer >= 0 && Int(e.layer) < layers
                ? String(cString: textPtr + Int(layersPtr[Int(e.layer)].name_start)) : "?"
            byLayer[layerName, default: 0] += 1
            count += 1
            if count <= 25 {
                var geom = ""
                if e.pcount >= 2 {
                    let a = pointsPtr[Int(e.pstart)]
                    let z = pointsPtr[Int(e.pstart) + Int(e.pcount) - 1]
                    geom = String(format: "p0=(%.1f,%.1f) pN=(%.1f,%.1f)", a.x, a.y, z.x, z.y)
                }
                print(String(format: "    big #%d handle=%llu kind=%d pts=%d layer=%@ box=(%.1f,%.1f)-(%.1f,%.1f) %@",
                             i, e.handle, e.kind, e.pcount, layerName as NSString,
                             e.box.minx, e.box.miny, e.box.maxx, e.box.maxy, geom as NSString))
            }
        }
        print("  big entities (>60000): \(count)")
        for (name, n) in byLayer.sorted(by: { $0.value > $1.value }).prefix(15) {
            print("    \(name): \(n)")
        }
        var nearOrigin = 0
        for i in 0..<entityCount {
            let e = entitiesPtr[i]
            if e.box.minx > -100000 { nearOrigin += 1 }
        }
        print("  entities with minx > -100000: \(nearOrigin)")
    }
    if handles, let entitiesPtr = cad_doc_entities(doc), let textPtr = cad_doc_text(doc),
       let layersPtr = cad_doc_layers(doc) {
        for i in 0..<entityCount {
            let e = entitiesPtr[i]
            guard e.handle >= 12300 && e.handle <= 12460 else { continue }
            let name = e.layer >= 0 && Int(e.layer) < layers
                ? String(cString: textPtr + Int(layersPtr[Int(e.layer)].name_start)) : "?"
            print(String(format: "handle %llu kind=%d space=%d layer=%@", e.handle, e.kind, e.space, name as NSString))
        }
    }

    if spaceHist, let entitiesPtr = cad_doc_entities(doc) {
        var bins = Array(repeating: 0, count: 16)
        for i in 0..<entityCount {
            let e = entitiesPtr[i]
            guard e.space == 1, e.box.minx <= e.box.maxx else { continue }
            let cy = (e.box.miny + e.box.maxy) / 2
            let bin = Int(floor((cy + 400) / 100))
            if bin >= 0 && bin < bins.count { bins[bin] += 1 }
        }
        for (i, n) in bins.enumerated() {
            print(String(format: "spaceHist y %6d..%6d : %d", -400 + i*100, -300 + i*100, n))
        }
    }

    if layoutBoxes, let entitiesPtr = cad_doc_entities(doc),
       let textPtr = cad_doc_text(doc), let layersPtr = cad_doc_layers(doc) {
        for i in 0..<entityCount {
            let e = entitiesPtr[i]
            guard e.space == 1 else { continue }
            let w = e.box.maxx - e.box.minx, h = e.box.maxy - e.box.miny
            guard w > 300, h > 100, w < 1200, h < 500 else { continue }
            let name = e.layer >= 0 && Int(e.layer) < layers
                ? String(cString: textPtr + Int(layersPtr[Int(e.layer)].name_start)) : "?"
            print(String(format: "layoutbox #%d handle=%llu kind=%d layer=%@ box=(%.1f,%.1f)-(%.1f,%.1f) pts=%d",
                         i, e.handle, e.kind, name as NSString,
                         e.box.minx, e.box.miny, e.box.maxx, e.box.maxy, e.pcount))
        }
    }

    if viewports, let viewportsPtr = cad_doc_viewports(doc), let textPtr = cad_doc_text(doc) {
        for i in 0..<Int(cad_doc_viewport_count(doc)) {
            let v = viewportsPtr[i]
            let name = String(cString: textPtr + Int(cad_doc_spaces(doc)![Int(v.space)].name_start))
            print(String(format: "viewport space=%@ id=%d status=%d frozen=%d center=(%.3f,%.3f) size=(%.3f,%.3f) modelCenter=(%.3f,%.3f) modelHeight=%.3f twist=%.4f clip=(%.1f,%.1f)-(%.1f,%.1f)",
                         name as NSString, v.id, v.status, v.frozen_count,
                         v.cx, v.cy, v.width, v.height,
                         v.model_cx, v.model_cy, v.model_height, v.twist,
                         v.clip.minx, v.clip.miny, v.clip.maxx, v.clip.maxy))
        }
    }

    if texts, let entitiesPtr = cad_doc_entities(doc), let textPtr = cad_doc_text(doc) {
        for i in 0..<entityCount {
            let e = entitiesPtr[i]
            guard e.kind == Int32(CAD_TEXT.rawValue), e.tstart >= 0 else { continue }
            let value = String(cString: textPtr + Int(e.tstart))
            print(String(format: "text space=%d handle=%llu cx=%.6f cy=%.6f h=%.4f rot=%.6f ws=%.6f ha=%d va=%d mtext=%d %@",
                         e.space, e.handle, e.cx, e.cy, e.h, e.rot * 180 / .pi, e.ws,
                         e.halign, e.valign,
                         e.flags & Int32(CAD_FLAG_MTEXT) != 0 ? 1 : 0,
                         value.prefix(40) as NSString))
        }
    }

    // Exact point dump for byte-level comparison against the reference
    // reader's --inspect-entities + CADLENS_DUMP_POINTS output.
    if dump, let entitiesPtr = cad_doc_entities(doc), let pointsPtr = cad_doc_points(doc) {
        let total = Int(cad_doc_point_count(doc))
        for i in 0..<entityCount {
            let e = entitiesPtr[i]
            let start = Int(e.pstart), count = Int(e.pcount)
            var coords = ""
            if count > 0 && start >= 0 && start + count <= total {
                let limit = min(count, 4096)
                var parts: [String] = []
                parts.reserveCapacity(limit)
                for k in 0..<limit {
                    let p = pointsPtr[start + k]
                    parts.append(String(format: "%.12g,%.12g", p.x, p.y))
                }
                coords = parts.joined(separator: ";")
            }
            print(String(format: "dump|%d|%llu|%d|%d|%d|%.12g|%.12g|%.12g|%.12g|%.12g|%.12g|%.12g|%.12g|%.12g|%d|%d|%@",
                         e.space, e.handle, e.kind, e.pcount, e.flags,
                         e.box.minx, e.box.miny, e.box.maxx, e.box.maxy,
                         e.cx, e.cy, e.r, e.a0, e.a1,
                         e.rgb & 0xFFFFFF, Int(e.aci),
                         coords as NSString))
        }
    }
}

var args = Array(CommandLine.arguments.dropFirst())
var layerName: String? = nil
var outliers = false
var big = false
var texts = false
var viewports = false
var layoutBoxes = false
var spaceHist = false
var handles = false
var dump = false
if let index = args.firstIndex(of: "--layer"), index + 1 < args.count {
    layerName = args[index + 1]
    args.removeSubrange(index...(index + 1))
}
if let index = args.firstIndex(of: "--outliers") {
    outliers = true
    args.remove(at: index)
}
if let index = args.firstIndex(of: "--big") {
    big = true
    args.remove(at: index)
}
if let index = args.firstIndex(of: "--texts") {
    texts = true
    args.remove(at: index)
}
if let index = args.firstIndex(of: "--viewports") {
    viewports = true
    args.remove(at: index)
}
if let index = args.firstIndex(of: "--layout-boxes") {
    layoutBoxes = true
    args.remove(at: index)
}
if let index = args.firstIndex(of: "--space-hist") {
    spaceHist = true
    args.remove(at: index)
}
if let index = args.firstIndex(of: "--handles") {
    handles = true
    args.remove(at: index)
}
if let index = args.firstIndex(of: "--dump") {
    dump = true
    args.remove(at: index)
}
if args.isEmpty {
    print("usage: cadtool [--layer NAME] [--outliers] [--big] [--texts] [--viewports] [--dump] <drawing.dwg|drawing.dxf>")
    exit(1)
}
for path in args {
    describe(path, layer: layerName, outliers: outliers, big: big,
             texts: texts, viewports: viewports, layoutBoxes: layoutBoxes, spaceHist: spaceHist, handles: handles,
             dump: dump)
}
