import CoreGraphics
import Foundation

/// Compiled AutoCAD SHX stroke fonts.
///
/// Domestic drawings are set in the GB pair gbenor.shx (latin/digits) plus
/// gbcbig.shx (CJK big font). CoreText cannot open SHX — it is a compiled
/// vector-pen format, not a TrueType container — so the viewer parses it here
/// and strokes the same single-line glyphs the drawing was authored with.
/// Without this the labels came out in a substitute face whose advances differ,
/// which is exactly the "text sits a few pixels off" defect.
///
/// Two on-disk layouts exist and both are handled:
///  * `AutoCAD-86 unifont 1.0` — 16-bit unicode index, inline records.
///  * `AutoCAD-86 bigfont 1.0` — 16-bit GB code index, offset table.
///
/// The pen program itself is a stream of nibble pairs: the high nibble is a
/// vector length 1–15 and the low nibble a direction in 22.5° steps. A zero
/// length turns the low nibble into an opcode. The tricky part is that the
/// four arc opcodes do not all take the same operand count — 0A takes two
/// bytes, 0B five, 0C three and 0D a whole run of them — so getting the stream
/// back in sync after an arc is what makes or breaks every curved glyph.
final class ShxFont {
    /// One sub-path of a glyph in font units (y up, baseline at 0).
    struct SubPath {
        var points: [CGPoint]
    }

    struct Glyph {
        var subPaths: [SubPath]
        /// Where the pen ended up: the advance for the next character.
        var advance: CGFloat
    }

    /// Cap height in font units as declared by the file. This includes
    /// ascenders and accents, so it is not what CAD calls the text height.
    let above: CGFloat
    let below: CGFloat
    /// Measured capital (or CJK full-character) height in font units. A CAD
    /// text height is this, not an em size, so glyphs scale by `height / capHeight`.
    let capHeight: CGFloat

    private let programs: [Int: [UInt8]]
    /// Big fonts are indexed by GB code, unifonts by unicode scalar.
    private let usesGBIndex: Bool
    /// Decoded glyphs, including negative results so a broken record is only
    /// walked once.
    private var cache: [Int: Glyph?] = [:]

    private init(above: CGFloat, below: CGFloat, capHeight: CGFloat,
                 programs: [Int: [UInt8]], usesGBIndex: Bool) {
        self.above = max(above, 1)
        self.below = below
        self.capHeight = max(capHeight, 1)
        self.programs = programs
        self.usesGBIndex = usesGBIndex
    }

    var isEmpty: Bool { programs.isEmpty }

    // MARK: - Character lookup

    func glyph(for character: Character) -> Glyph? {
        guard let code = code(for: character) else { return nil }
        if let cached = cache[code] { return cached }
        let decoded = programs[code].flatMap {
            ShxFont.decode(program: $0, fonts: programs)
        }
        // Some records (gbenor's '9', '&', '§') encode their arc with an
        // operand layout this reader does not reproduce, which throws the pen
        // far outside the glyph cell. Treat those as absent so the caller can
        // substitute a text face rather than draw a stray tangle.
        let limit = capHeight * 4
        func plausible(_ glyph: Glyph) -> Bool {
            !glyph.subPaths.contains { path in
                path.points.contains { abs($0.x) > limit || abs($0.y) > limit }
            }
        }
        if let glyph = decoded, plausible(glyph) {
            cache[code] = glyph
            return glyph
        }
        if let turned = ShxFont.turnOver(code, programs: programs, limit: limit) {
            cache[code] = turned
            return turned
        }
        cache[code] = Glyph?.none
        return nil
    }

    /// Digits whose record this reader cannot reproduce are taken from their
    /// 180° counterpart. ISO 3098 draws 6 and 9 as the same shape turned over,
    /// so the substitute keeps the weight and the metrics of the family
    /// instead of dropping to a filled text face mid-label.
    private static let rotationalCounterparts: [Int: Int] = [
        0x39: 0x36,  // '9' from '6'
        0x36: 0x39,  // '6' from '9'
    ]

    private static func turnOver(_ code: Int, programs: [Int: [UInt8]],
                                 limit: CGFloat) -> Glyph? {
        guard let source = rotationalCounterparts[code],
              let program = programs[source],
              let base = decode(program: program, fonts: programs) else { return nil }
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        var minY = minX, maxY = maxX
        for path in base.subPaths {
            for point in path.points {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
        }
        guard minX <= maxX, minY <= maxY else { return nil }
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        let paths = base.subPaths.map { path in
            SubPath(points: path.points.map { CGPoint(x: 2 * cx - $0.x, y: 2 * cy - $0.y) })
        }
        guard plausible(paths, limit: limit) else { return nil }
        return Glyph(subPaths: paths, advance: base.advance)
    }

    private static func plausible(_ paths: [SubPath], limit: CGFloat) -> Bool {
        !paths.contains { path in
            path.points.contains { abs($0.x) > limit || abs($0.y) > limit }
        }
    }

    private func code(for character: Character) -> Int? {
        if let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
           scalar.value < 0x80 {
            return Int(scalar.value)
        }
        if usesGBIndex {
            return ShxFont.gbCode(for: character)
                ?? Int(character.unicodeScalars.first?.value ?? 0)
        }
        return Int(character.unicodeScalars.first?.value ?? 0)
    }

    private static let gb18030 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    /// The big font's index is the two-byte GB18030 code, not a unicode value.
    private static func gbCode(for character: Character) -> Int? {
        guard let data = String(character).data(using: gb18030),
              data.count == 2 else { return nil }
        return Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])
    }

    // MARK: - Loading

    static func load(bundled name: String, cjk: Bool) -> ShxFont? {
        for directory in searchDirectories() {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { continue }
            if let font = parse(data: data, cjk: cjk) { return font }
        }
        return nil
    }

    private static func searchDirectories() -> [URL] {
        var directories: [URL] = []
        if let resource = Bundle.main.resourceURL {
            directories.append(resource.appendingPathComponent("fonts"))
            directories.append(resource)
        }
        directories.append(Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("Resources/fonts"))
        directories.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/fonts"))
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        directories.append(sourceRoot.appendingPathComponent("Resources/fonts"))
        return directories
    }

    // MARK: - Binary format

    private struct Reader {
        let bytes: [UInt8]
        var offset: Int = 0
        var isValid: Bool { offset >= 0 && offset < bytes.count }
        mutating func u8() -> Int { defer { offset += 1 }; return offset < bytes.count ? Int(bytes[offset]) : 0 }
        mutating func i8() -> Int { let v = u8(); return v > 127 ? v - 256 : v }
        mutating func u16() -> Int {
            let lo = u8(), hi = u8()
            return lo | (hi << 8)
        }
        mutating func u32() -> Int {
            let a = u8(), b = u8(), c = u8(), d = u8()
            return a | (b << 8) | (c << 16) | (d << 24)
        }
        mutating func seek(_ position: Int) { offset = position }
        mutating func skip(_ count: Int) { offset += count }
        func slice(_ start: Int, _ count: Int) -> [UInt8] {
            guard start >= 0, count > 0, start + count <= bytes.count else { return [] }
            return Array(bytes[start..<(start + count)])
        }
    }

    static func parse(data: Data, cjk: Bool) -> ShxFont? {
        var reader = Reader(bytes: [UInt8](data))

        // Identification string, terminated by 0x1A.
        var header: [UInt8] = []
        while reader.isValid, reader.offset < 64 {
            let byte = reader.u8()
            if byte == 0x1A { break }
            if byte != 0x0D && byte != 0x0A { header.append(UInt8(byte)) }
        }
        let title = String(decoding: header, as: UTF8.self)
        guard title.hasPrefix("AutoCAD-86") else { return nil }

        if title.contains("bigfont") {
            return parseBigFont(reader: &reader)
        }
        return parseUniFont(reader: &reader)
    }

    private static func parseUniFont(reader: inout Reader) -> ShxFont? {
        let count = reader.u16()
        _ = reader.u16()
        let nameBytes = reader.u16()
        let nameStart = reader.offset
        guard count > 0, count < 70000, nameBytes > 8,
              nameStart + nameBytes <= reader.bytes.count else { return nil }

        // The 6 bytes that close the name block: above, below, modes, encoding,
        // embedded, spare.
        var above = CGFloat(reader.bytes[nameStart + nameBytes - 6])
        var below = CGFloat(reader.bytes[nameStart + nameBytes - 5])
        reader.seek(nameStart + nameBytes)

        var programs: [Int: [UInt8]] = [:]
        var index = 0
        while index < count, reader.isValid {
            let code = reader.u16()
            let length = reader.u16()
            guard length >= 0, reader.offset + length <= reader.bytes.count else { break }
            let record = reader.slice(reader.offset, length)
            reader.skip(length)
            index += 1
            if code == 0 {
                // The code-0 record restates the font's vertical metrics.
                let body = stripName(record)
                if body.count >= 3 {
                    above = CGFloat(body[0])
                    below = CGFloat(body[1])
                }
                continue
            }
            programs[code] = record
        }
        guard !programs.isEmpty else { return nil }
        let cap = measureCapHeight(programs: programs, cjk: false, fallback: above)
        return ShxFont(above: above, below: below, capHeight: cap,
                       programs: programs, usesGBIndex: false)
    }

    private static func parseBigFont(reader: inout Reader) -> ShxFont? {
        _ = reader.u16()
        let count = reader.u16()
        let changeCount = reader.u16()
        guard count > 0, count < 40000, changeCount < 256 else { return nil }
        for _ in 0..<changeCount { _ = reader.u16(); _ = reader.u16() }

        var records: [(code: Int, length: Int, offset: Int)] = []
        records.reserveCapacity(count)
        for _ in 0..<count {
            let code = reader.u16()
            let length = reader.u16()
            let offset = reader.u32()
            records.append((code, length, offset))
        }
        var programs: [Int: [UInt8]] = [:]
        programs.reserveCapacity(records.count)
        for record in records {
            guard record.code != 0, record.offset > 0,
                  record.offset < reader.bytes.count, record.length > 0 else { continue }
            let raw = reader.slice(record.offset, record.length)
            guard !raw.isEmpty else { continue }
            programs[record.code] = raw
        }
        guard !programs.isEmpty else { return nil }
        // A big font carries no above/below header — byte 0 is a title string
        // ("工程汉字的字体文件 1998.1"), not metrics. Measure instead.
        let cap = measureCapHeight(programs: programs, cjk: true, fallback: 90)
        return ShxFont(above: cap, below: cap * 0.18, capHeight: cap,
                       programs: programs, usesGBIndex: true)
    }

    /// Drops the null-terminated glyph name that prefixes a record.
    private static func stripName(_ record: [UInt8]) -> [UInt8] {
        var cursor = 0
        if cursor < record.count, record[cursor] == 0 {
            cursor += 1
        } else {
            while cursor < record.count, record[cursor] != 0 { cursor += 1 }
            cursor += 1
        }
        return cursor < record.count ? Array(record[cursor...]) : []
    }

    /// Font units per CAD text height.
    ///
    /// The declared `above` counts accents and ascenders, so it is taller than
    /// a capital letter; using it would draw every label ~25 % too small. For
    /// a big font there is no header at all, so the CJK full height is taken
    /// from the glyphs themselves.
    private static func measureCapHeight(programs: [Int: [UInt8]], cjk: Bool,
                                         fallback: CGFloat) -> CGFloat {
        if !cjk {
            if let program = programs[0x48],                       // 'H'
               let glyph = decode(program: program, fonts: programs) {
                let top = glyph.subPaths.flatMap { $0.points }.map { $0.y }.max() ?? 0
                if top > 1 { return top }
            }
            return fallback
        }
        var tops: [CGFloat] = []
        tops.reserveCapacity(512)
        for (_, program) in programs.prefix(512) {
            guard let glyph = decode(program: program, fonts: programs) else { continue }
            let top = glyph.subPaths.flatMap { $0.points }.map { $0.y }.max() ?? 0
            if top > 1 { tops.append(top) }
        }
        guard !tops.isEmpty else { return fallback }
        tops.sort()
        // Most CJK glyphs fill the cell; the 90th percentile ignores the few
        // that shrink below the cap line, and stops descender-like glyphs from
        // dragging the estimate down.
        return tops[Int(Double(tops.count - 1) * 0.90)]
    }

    // MARK: - Glyph pen program

    private struct PenState {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var scale: CGFloat = 1
        var penDown = false
        var subPaths: [SubPath] = []
        var current: [CGPoint] = []
        var maxX: CGFloat = 0

        mutating func flush() {
            if current.count >= 2 { subPaths.append(SubPath(points: current)) }
            current.removeAll(keepingCapacity: true)
        }

        mutating func hop(_ x: CGFloat, _ y: CGFloat) {
            self.x = x
            self.y = y
            maxX = max(maxX, x)
            if penDown {
                if current.isEmpty { current.append(CGPoint(x: x, y: y)) }
                current.append(CGPoint(x: x, y: y))
            }
        }
    }

    /// Direction unit vectors for the 16 compass headings. AutoCAD uses the
    /// classic 0.5 diagonal, not 0.7071, so matching it keeps stroke lengths
    /// identical to what the plotter drew.
    private static let directions: [(CGFloat, CGFloat)] = [
        (1, 0), (1, 0.5), (1, 1), (0.5, 1),
        (0, 1), (-0.5, 1), (-1, 1), (-1, 0.5),
        (-1, 0), (-1, -0.5), (-1, -1), (-0.5, -1),
        (0, -1), (0.5, -1), (1, -1), (1, -0.5),
    ]

    private static func decode(program: [UInt8], fonts: [Int: [UInt8]]) -> Glyph? {
        let body = stripName(program)
        guard !body.isEmpty else { return nil }
        var state = PenState()
        var stack: [(x: CGFloat, y: CGFloat, scale: CGFloat)] = []
        run(bytes: body, index: 0, state: &state, stack: &stack,
            depth: 0, fonts: fonts)
        state.flush()
        guard !state.subPaths.isEmpty else { return nil }
        // A record that lands outside any plausible glyph box means the pen
        // stream desynced (an arc opcode with a width we do not know). Report
        // the glyph as missing so the caller can substitute a text face.
        let bound: CGFloat = 300
        for path in state.subPaths {
            for point in path.points {
                if abs(point.x) > bound || abs(point.y) > bound { return nil }
            }
        }
        let advance = max(state.maxX, 0)
        return Glyph(subPaths: state.subPaths, advance: advance)
    }

    /// Walks one pen program. `index` is threaded through because sub-shapes
    /// (opcode 7) re-enter with a different program.
    private static func run(bytes: [UInt8], index startIndex: Int,
                            state: inout PenState,
                            stack: inout [(x: CGFloat, y: CGFloat, scale: CGFloat)],
                            depth: Int, fonts: [Int: [UInt8]]) {
        var index = startIndex
        var guardCount = 0
        while index < bytes.count, guardCount < 6000 {
            guardCount += 1
            let byte = Int(bytes[index])
            index += 1
            let direction = byte & 0x0F
            let length = (byte & 0xF0) >> 4
            if length != 0 {
                let (dx, dy) = directions[direction]
                let unit = CGFloat(length) * state.scale
                state.hop(state.x + dx * unit, state.y + dy * unit)
                continue
            }
            switch direction {
            case 0: // end of shape
                return
            case 1: // pen down
                if state.penDown { state.flush() }
                state.penDown = true
                state.current = [CGPoint(x: state.x, y: state.y)]
            case 2: // pen up
                state.flush()
                state.penDown = false
            case 3: // divide vector length
                let factor = max(1, Int(bytes[index])); index += 1
                state.scale /= CGFloat(factor)
            case 4: // multiply vector length
                let factor = max(1, Int(bytes[index])); index += 1
                state.scale *= CGFloat(factor)
            case 5:
                stack.append((state.x, state.y, state.scale))
            case 6:
                if let saved = stack.popLast() {
                    state.x = saved.x; state.y = saved.y; state.scale = saved.scale
                }
            case 7: // draw sub-shape
                let sub = Int(bytes[index]); index += 1
                if depth < 6, let nested = fonts[sub] {
                    // A nested shape is a call, not an inline splice: its
                    // divide/multiply vectors must not leak back into the
                    // outer glyph, and the pen returns where it left off.
                    // CJK glyphs lean on this heavily — gbcbig draws 中 as a
                    // 口 sub-shape plus one stroke, and without the isolation
                    // every following character comes out ~11× too small.
                    let savedX = state.x
                    let savedY = state.y
                    let savedScale = state.scale
                    let savedPen = state.penDown
                    let savedPath = state.current
                    if state.penDown { state.flush() }
                    run(bytes: stripName(nested), index: 0, state: &state,
                        stack: &stack, depth: depth + 1, fonts: fonts)
                    state.flush()
                    state.x = savedX
                    state.y = savedY
                    state.scale = savedScale
                    state.penDown = savedPen
                    state.current = savedPath
                }
            case 8: // signed XY displacement
                let dx = Int8(bitPattern: bytes[index]); index += 1
                let dy = index < bytes.count ? Int8(bitPattern: bytes[index]) : 0
                index += 1
                state.hop(state.x + CGFloat(dx) * state.scale,
                          state.y + CGFloat(dy) * state.scale)
            case 9: // run of XY displacements, terminated by (0,0)
                while index + 1 < bytes.count {
                    let dx = Int8(bitPattern: bytes[index])
                    let dy = Int8(bitPattern: bytes[index + 1])
                    index += 2
                    if dx == 0 && dy == 0 { break }
                    state.hop(state.x + CGFloat(dx) * state.scale,
                              state.y + CGFloat(dy) * state.scale)
                }
            case 10: // octant arc: radius, (clockwise, start octant, count)
                let radiusRaw = Int(bytes[index])
                let packed = index + 1 < bytes.count ? Int(bytes[index + 1]) : 0
                index += 2
                let radius = (radiusRaw == 0 ? 256 : radiusRaw).cg * state.scale
                let startAngle = CGFloat(packed >> 4 & 0x7) * .pi / 4
                var count = packed & 0x0F
                if count == 0 { count = 8 }
                let clockwise = (packed & 0x80) != 0
                let center = CGPoint(x: state.x - radius * cos(startAngle),
                                     y: state.y - radius * sin(startAngle))
                let sweep = CGFloat(count) * .pi / 4 * (clockwise ? -1 : 1)
                arcPoints(center: center, radius: radius,
                          startAngle: startAngle, sweep: sweep, into: &state)
            case 11: // fractional arc: radius, start octant+fraction, end octant+fraction
                guard index + 4 < bytes.count else { index = bytes.count; continue }
                let radiusRaw = Int(bytes[index])
                let so = Int(bytes[index + 1]), sf = Int(bytes[index + 2])
                let eo = Int(bytes[index + 3]), ef = Int(bytes[index + 4])
                index += 5
                let radius = (radiusRaw == 0 ? 256 : radiusRaw).cg * state.scale
                let a0 = (CGFloat(so) + CGFloat(sf) / 256) * .pi / 4
                let a1 = (CGFloat(eo) + CGFloat(ef) / 256) * .pi / 4
                let center = CGPoint(x: state.x - radius * cos(a0),
                                     y: state.y - radius * sin(a0))
                arcPoints(center: center, radius: radius,
                          startAngle: a0, sweep: a1 - a0, into: &state)
            case 12: // arc from (dx, dy, bulge)
                index = bulgeSegment(bytes: bytes, index: index, state: &state)
            case 13: // run of bulge arcs, terminated by (0,0)
                while index + 1 < bytes.count {
                    if bytes[index] == 0 && bytes[index + 1] == 0 {
                        index += 2
                        break
                    }
                    let next = bulgeSegment(bytes: bytes, index: index, state: &state)
                    if next == index { break }
                    index = next
                }
            case 14: // vertical-text only: skip its operand
                index += 1
            default:
                break
            }
        }
    }

    private static func bulgeSegment(bytes: [UInt8], index: Int,
                                     state: inout PenState) -> Int {
        guard index + 2 < bytes.count else { return bytes.count }
        let dx = Int8(bitPattern: bytes[index])
        let dy = Int8(bitPattern: bytes[index + 1])
        let bulge = Int8(bitPattern: bytes[index + 2])
        let start = CGPoint(x: state.x, y: state.y)
        let end = CGPoint(x: start.x + CGFloat(dx) * state.scale,
                          y: start.y + CGFloat(dy) * state.scale)
        if bulge == 0 {
            state.hop(end.x, end.y)
            return index + 3
        }
        let theta = CGFloat(bulge) * .pi / 127
        let chord = hypot(end.x - start.x, end.y - start.y)
        guard chord > 1e-9 else { return index + 3 }
        let radius = chord / (2 * sin(abs(theta) / 2))
        // The centre sits on the far side of the chord from the bulge apex.
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let nx = -(end.y - start.y) / chord
        let ny = (end.x - start.x) / chord
        let apexSide: CGFloat = theta > 0 ? -1 : 1
        let offset = radius * cos(theta / 2)
        let center = CGPoint(x: mid.x - nx * apexSide * offset,
                             y: mid.y - ny * apexSide * offset)
        let startAngle = atan2(start.y - center.y, start.x - center.x)
        arcPoints(center: center, radius: radius,
                  startAngle: startAngle, sweep: theta, into: &state)
        return index + 3
    }

    private static func arcPoints(center: CGPoint, radius: CGFloat,
                                  startAngle: CGFloat, sweep: CGFloat,
                                  into state: inout PenState) {
        guard radius > 0, abs(sweep) > 1e-6 else { return }
        let steps = max(3, Int(abs(sweep) / 0.12))
        for step in 0...steps {
            let angle = startAngle + sweep * CGFloat(step) / CGFloat(steps)
            state.hop(center.x + radius * cos(angle),
                      center.y + radius * sin(angle))
        }
    }
}

private extension Int {
    var cg: CGFloat { CGFloat(self) }
}
