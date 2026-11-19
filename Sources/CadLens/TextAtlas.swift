import AppKit
import CoreText
import Metal

/// Glyph raster cache.
///
/// Every distinct (font, size, glyph) triple is rasterised once with Core Text
/// into a shelf-packed R8 atlas page. The GPU then draws each glyph as a quad,
/// so a sheet with thousands of labels costs a couple of draw calls instead of
/// thousands of Core Graphics text runs per frame.
///
/// Rasters are kept at the pixel size the screen actually needs; the size is
/// chosen from `pixelSizes` so a zoom step only re-rasterises when the glyph
/// would otherwise be stretched past ~1.6×.
final class GlyphAtlas {

    struct Entry {
        var page: Int32 = -1
        /// origin.xy and size.zw, normalised texture coordinates.
        var uv = SIMD4<Float>(repeating: 0)
        /// Raster size in pixels.
        var size = SIMD2<Float>(repeating: 0)
        /// Offset of the raster's lower-left corner from the baseline origin,
        /// in pixels, y up.
        var bearing = SIMD2<Float>(repeating: 0)
    }

    private struct Key: Hashable {
        var font: String
        var size: Int
        var glyph: UInt16
    }

    /// Em sizes that glyphs get rasterised at. The smallest bucket at or above
    /// the needed size wins, so text is normally rendered from a raster within
    /// a factor of 1.6 of its final size.
    static let pixelSizes = [16, 24, 36, 56, 88]

    let device: MTLDevice
    private let pageEdge = 2048
    private(set) var pages: [MTLTexture] = []
    private var shelfX = 0
    private var shelfY = 0
    private var shelfHeight = 0
    private var cache: [Key: Entry] = [:]
    private var layoutCache: [String: TextLine] = [:]

    /// Blank glyphs (spaces) still need an advance, so they get an entry with
    /// no page and are skipped when building quads.
    private let blank = Entry()

    init(device: MTLDevice) {
        self.device = device
    }

    static func bucket(for pixels: CGFloat) -> Int {
        for size in pixelSizes where CGFloat(size) >= pixels { return size }
        return pixelSizes[pixelSizes.count - 1]
    }

    // MARK: Rasterising

    func entry(font: CTFont, size: Int, glyph: CGGlyph) -> Entry {
        let name = CTFontCopyPostScriptName(font) as String
        let key = Key(font: name, size: size, glyph: glyph)
        if let cached = cache[key] { return cached }

        let sized = CTFontCreateCopyWithAttributes(font, CGFloat(size), nil, nil)
        var single = glyph
        let bounds = CTFontGetBoundingRectsForGlyphs(sized, .default, &single, nil, 1)
        guard bounds.width > 0.05, bounds.height > 0.05, bounds.width < 400,
              bounds.height < 400 else {
            cache[key] = blank
            return blank
        }

        let width = Int(ceil(bounds.width)) + 2
        let height = Int(ceil(bounds.height)) + 2
        guard width < pageEdge, height < pageEdge,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else {
            cache[key] = blank
            return blank
        }
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 1, alpha: 1)
        var position = CGPoint(x: 1 - bounds.minX, y: 1 - bounds.minY)
        CTFontDrawGlyphs(sized, &single, &position, 1, context)

        guard let slot = allocate(width: width, height: height) else {
            cache[key] = blank
            return blank
        }
        guard let data = context.data else {
            cache[key] = blank
            return blank
        }
        pages[slot.page].replace(
            region: MTLRegionMake2D(slot.x, slot.y, width, height), mipmapLevel: 0,
            withBytes: data, bytesPerRow: context.bytesPerRow)

        let edge = Float(pageEdge)
        let entry = Entry(page: Int32(slot.page),
                          uv: SIMD4<Float>(Float(slot.x) / edge,
                                           Float(slot.y) / edge,
                                           Float(width) / edge,
                                           Float(height) / edge),
                          size: SIMD2<Float>(Float(width), Float(height)),
                          bearing: SIMD2<Float>(Float(bounds.minX.rounded(.down)),
                                                Float(bounds.minY.rounded(.down))))
        cache[key] = entry
        return entry
    }

    private func allocate(width: Int, height: Int) -> (page: Int, x: Int, y: Int)? {
        if shelfX + width > pageEdge {
            shelfY += shelfHeight + 1
            shelfX = 0
            shelfHeight = 0
        }
        if shelfY + height > pageEdge {
            shelfY = 0
            shelfX = 0
            shelfHeight = 0
            pages.append(makePage())
        }
        if pages.isEmpty { pages.append(makePage()) }
        let slot = (page: pages.count - 1, x: shelfX, y: shelfY)
        shelfX += width + 1
        shelfHeight = max(shelfHeight, height)
        return slot
    }

    private func makePage() -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: pageEdge, height: pageEdge, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .managed
        return device.makeTexture(descriptor: descriptor)!
    }

    // MARK: Layout

    /// One laid-out line of text. Metrics are in em units (font size = 1) so a
    /// single layout serves every height the label is drawn at.
    struct TextLine {
        struct Item {
            var font: CTFont
            var glyph: CGGlyph
            var x: CGFloat
        }
        var items: [Item] = []
        var width: CGFloat = 0
        var ascent: CGFloat = 0.8
        var descent: CGFloat = 0.2
    }

    private static let baseFont: CTFont = {
        // Reference: osifont + NotoSansCJKsc for CAD glyphs. CJK characters
        // still arrive as separate CTRuns via CoreText's cascade, so the
        // per-run font below is honoured for those glyphs.
        return CadFont.ct(size: 100)
    }()

    func line(_ text: String) -> TextLine {
        if let cached = layoutCache[text] { return cached }
        if layoutCache.count > 24_000 { layoutCache.removeAll(keepingCapacity: true) }

        var result = TextLine()
        guard !text.isEmpty else { return result }
        let attributed = NSAttributedString(string: text,
                                            attributes: [.font: Self.baseFont])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        result.width = width / 100
        result.ascent = ascent / 100
        result.descent = descent / 100

        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return result }
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            let range = CFRange(location: 0, length: count)
            CTRunGetGlyphs(run, range, &glyphs)
            CTRunGetPositions(run, range, &positions)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName as String] as? NSFont
            let font: CTFont = runFont.map { $0 as CTFont } ?? Self.baseFont
            for i in 0..<count {
                result.items.append(TextLine.Item(font: font, glyph: glyphs[i],
                                                  x: positions[i].x / 100))
            }
        }
        layoutCache[text] = result
        return result
    }

    func purge() {
        cache.removeAll(keepingCapacity: true)
        layoutCache.removeAll(keepingCapacity: true)
        pages.removeAll(keepingCapacity: true)
        shelfX = 0
        shelfY = 0
        shelfHeight = 0
    }
}
