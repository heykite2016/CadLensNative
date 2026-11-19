import AppKit
import CoreText
import Foundation

/// The reference product ships osifont (ISO 3098 engineering letterforms,
/// diameter/degree/plus-minus glyphs and SHX-like strokes) plus a CJK face.
/// CAD labels must use those faces: Helvetica/PingFang have different advances,
/// so centred room numbers, door tags and aligned dimensions shift. Both the
/// Core Graphics text pass and the GPU glyph atlas go through here so the two
/// renderers measure exactly the same glyphs.
enum CadFont {
    /// CAD drawings use the GB engineering pair: gbenor (latin) + gbcbig (CJK).
    /// Those ship as SHX, which CoreText cannot load, so a TrueType conversion
    /// with the same name is picked up first when present in Resources/fonts.
    /// The bundled fallbacks keep the same metrics class: osifont is an
    /// ISO 3098 engineering face and Noto Sans CJK covers every CJK codepoint,
    /// so nothing ever renders as tofu.
    private static let westernFiles = ["gbenor.ttf", "gbenor.shx.ttf",
                                      "osifont-lgpl3fe.ttf"]
    private static let cjkFiles = ["gbcbig.ttf", "gbcbig.shx.ttf",
                                   "NotoSansCJKsc-Regular.otf"]

    private static func register(_ names: [String]) -> String? {
        var candidates: [URL] = []
        if let resource = Bundle.main.resourceURL {
            candidates.append(resource.appendingPathComponent("fonts"))
            candidates.append(resource)
        }
        candidates.append(Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("Resources/fonts"))
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/fonts"))
        // Direct `build/CadLens` runs (snapshots, CLI) have no app bundle.
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CadLens/
            .deletingLastPathComponent()   // Sources/
            .deletingLastPathComponent()   // project root
        candidates.append(sourceRoot.appendingPathComponent("Resources/fonts"))

        for file in names {
            for directory in candidates {
                let url = directory.appendingPathComponent(file)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
                if let list = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
                    as? [CTFontDescriptor],
                   let descriptor = list.first,
                   let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute)
                    as? String {
                    return name
                }
            }
        }
        return nil
    }

    private static let faces: (western: String?, cjk: String?) = {
        let western = register(westernFiles)
        let cjk = register(cjkFiles)
        if ProcessInfo.processInfo.environment["CADLENS_FONT_LOG"] != nil {
            print("[font] western=\(western ?? "-") cjk=\(cjk ?? "-")")
        }
        return (western, cjk)
    }()

    /// Primary engineering face; falls back to the system face only when the
    /// bundled resources are missing.
    static func ns(size: CGFloat) -> NSFont {
        if let cached = fontCache[size] { return cached }
        let base: NSFont
        if let name = faces.western, let font = NSFont(name: name, size: size) {
            base = font
        } else {
            base = NSFont.systemFont(ofSize: size)
        }
        // gbenor/osifont carry the ISO 3098 latin letterforms but no CJK glyphs.
        // Without a cascade list CoreText silently falls back to the system face
        // for Chinese labels, whose advances differ — centred room names and
        // dimension text then sit a few pixels off.
        var resolved = base
        if let cjkName = faces.cjk, let cjk = NSFont(name: cjkName, size: size) {
            let descriptor = base.fontDescriptor.addingAttributes([
                .cascadeList: [cjk.fontDescriptor],
            ])
            resolved = NSFont(descriptor: descriptor, size: size) ?? base
        }
        fontCache[size] = resolved
        return resolved
    }

    private static var fontCache: [CGFloat: NSFont] = [:]

    /// CAD `height` is the visible ink height of a capital letter, not the em
    /// size — a 2.5 mm label rendered at point size 2.5 comes out about a
    /// quarter short, which also shifts every centred or right-aligned string.
    /// CadView.cpp::cadFontForText measures the glyph box and rescales the point
    /// size until the ink height matches the requested height; do the same.
    static func fitted(size target: CGFloat, text: String) -> NSFont {
        let probe = text.isEmpty ? "Ag" : text
        var font = ns(size: max(target, 0.01))
        // Glyph-path bounds are the ink box. `boundingRect`/`size()` return the
        // line box (ascent + descent + leading), which is ~1.2 em — using it
        // made the normalised size come out 15–20 % SMALLER than requested.
        let inkHeight: CGFloat = {
            let attributed = NSAttributedString(string: probe,
                                                attributes: [.font: font])
            let line = CTLineCreateWithAttributedString(attributed)
            let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            if bounds.height > 0.01 { return bounds.height }
            return CTFontGetCapHeight(font as CTFont)
        }()
        guard inkHeight > 0.02 else { return font }
        // Centre the ink box on the baseline the way CAD does: shift the point
        // size so ascender-to-descender covers `target`, then let the caller
        // place the baseline.
        let normalized = min(max(target * target / inkHeight, 1), target * 3)
        font = ns(size: normalized)
        return font
    }

    static func ct(size: CGFloat) -> CTFont {
        ns(size: size) as CTFont
    }
}
