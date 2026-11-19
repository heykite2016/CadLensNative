import AppKit

// Diagnostics go to a redirected file during scripted runs; without this every
// progress line sits in the C buffer until the process exits, which makes a
// slow pass look like a hang with no output at all.
setvbuf(stdout, nil, _IONBF, 0)

// 无头渲染模式（诊断用）：
//   CadLens render <in.dwg> <out.png> [space]
// 用真实 CadDocument + CadRenderer（CG 全量通道）把图纸渲染成 PNG，
// 以便在 Mac 外也能肉眼定位渲染问题（线条/填充/裁剪）。不启动 GUI。
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "render" {
    // 渲染路径会经 Theme.isDark 读取 NSApp.effectiveAppearance，
    // 无头模式必须先创建 NSApplication 并给定 appearance，否则强制解包崩溃。
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    // 画布配色跟随外观，参考工程默认用纯黑 CAD 画布。无头渲染默认走浅色，
    // 以便在白色底上看线宽；设 CADLENS_RENDER_APPEARANCE=dark 可切到暗色，
    // 用来核对暗色画布下的颜色提升逻辑（深色几何不能被"压暗"）。
    let appearance = ProcessInfo.processInfo
        .environment["CADLENS_RENDER_APPEARANCE"]?.lowercased() ?? "light"
    // Theme reads CADLENS_APPEARANCE because NSColor dynamic providers resolve
    // against NSAppearance.current, not the app's appearance, and an offscreen
    // CG context is always aqua.
    setenv("CADLENS_APPEARANCE", appearance, 1)
    app.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
    headlessRender(input: CommandLine.arguments[2],
                   output: CommandLine.arguments[3],
                   space: CommandLine.arguments.count >= 5
                        ? (Int32(CommandLine.arguments[4]) ?? 0) : 0)
    exit(0)
}

// 图标对照表（诊断用）：CadLens glyphs <out.png>
// 按工具栏完全相同的坐标系（翻转视图 + 24 格设计网格）把关键图标画成一张表，
// 用来确认方向类图标（选择箭头、垃圾桶）没有上下颠倒。
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "glyphs" {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    glyphSheet(to: CommandLine.arguments[2])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
// 界面外观跟着画布配色走（深色画布配深色界面）。启动时先定下标杆，
// 否则后台渲染线程第一次取 Theme.isDark 会拿到未初始化的缓存。
Theme.activateSavedTheme()
app.run()

/// 用真实渲染管线把指定图纸/空间渲染为 PNG。
func headlessRender(input: String, output: String, space: Int32) {
    let url = URL(fileURLWithPath: input)
    let doc: CadDocument
    do { doc = try CadDocument(url: url) } catch {
        print("load failed: \(error)"); exit(1)
    }
    doc.activateSpace(space)

    let viewW: CGFloat = {
        if let spec = ProcessInfo.processInfo.environment["CADLENS_RENDER_SIZE"],
           let value = Double(spec.split(separator: "x").first ?? "") { return value }
        return 2200
    }()
    let viewH: CGFloat = {
        if let spec = ProcessInfo.processInfo.environment["CADLENS_RENDER_SIZE"] {
            let parts = spec.split(separator: "x")
            if parts.count > 1, let value = Double(parts[1]) { return value }
        }
        return 1500
    }()
    // Same framing and the same spatial query the on-screen pass uses, so a
    // headless export is a faithful proxy for what the window shows.
    var box = doc.initialViewBox(for: space) ?? doc.spaces.first?.box ?? .zero
    // CADLENS_RENDER_BOX=minx,miny,maxx,maxy forces a detail window, which is
    // how a single elevation/dimension cluster can be compared 1:1 with the
    // reference viewer instead of squinting at a whole-sheet render.
    if let spec = ProcessInfo.processInfo.environment["CADLENS_RENDER_BOX"] {
        let v = spec.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        if v.count == 4 {
            box = CGRect(x: v[0], y: v[1], width: v[2] - v[0], height: v[3] - v[1])
        }
    }
    let scale: CGFloat
    let originX: CGFloat
    let originY: CGFloat
    // A stale or mis-decoded VPORT can point outside the drawing; only trust it
    // when its window actually looks at the geometry. The check uses the full
    // entity union with a quarter-extent of slack: this sheet's saved camera
    // sits on the elevation detail at the right-hand edge, outside the
    // percentile box, and rejecting it opened the file at a whole-sheet zoom.
    let savedPlausible: Bool = {
        guard let saved = doc.savedView else { return false }
        var union = CGRect.null
        for i in doc.entityIndices(in: space) {
            let b = doc.entities[i].box
            guard !b.isEmpty, b.width.isFinite, b.height.isFinite else { continue }
            union = union.isNull ? b : union.union(b)
        }
        guard !union.isNull else { return false }
        let window = CGRect(x: saved.center.x - saved.width / 2,
                            y: saved.center.y - saved.height / 2,
                            width: saved.width, height: saved.height)
        let reach = union.insetBy(dx: -union.width * 0.25, dy: -union.height * 0.25)
        return window.intersects(reach) || reach.contains(saved.center)
    }()
    // Frame the whole sheet, matching the window's first open. The saved VPORT
    // camera is a detail crop on many drawings, so it is not the initial view.
    if space == 0, ProcessInfo.processInfo.environment["CADLENS_SAVED_VIEW"] != nil,
       let saved = doc.savedView, savedPlausible,
       saved.width > 1e-9, saved.height > 1e-9 {
        // CadView.cpp::fitToInitialView — the saved VPORT camera wins.
        scale = max(1e-14, min(viewW / saved.width, viewH / saved.height))
        originX = saved.center.x - viewW / (2 * scale)
        originY = saved.center.y - viewH / (2 * scale)
    } else {
        let pad: CGFloat = 0.04
        let w = max(box.width, 1.0)
        let h = max(box.height, 1.0)
        scale = min(viewW / (w * (1 + pad * 2)), viewH / (h * (1 + pad * 2)))
        originX = box.minX - (viewW / scale - w) / 2
        originY = box.minY - (viewH / scale - h) / 2
    }
    let transform = ViewTransform(origin: CGPoint(x: originX, y: originY), scale: scale)
    if ProcessInfo.processInfo.environment["CADLENS_VIEW_LOG"] != nil {
        if let s = doc.savedView {
            print("[view] savedView center=(\(s.center.x), \(s.center.y)) "
                  + "size=\(s.width)x\(s.height) plausible=\(savedPlausible)")
        } else {
            print("[view] no savedView")
        }
        print("[view] contentBox=\(doc.contentBox(for: space) ?? .zero)")
        print("[view] initialViewBox=\(box)")
        print("[view] scale=\(scale) origin=(\(originX), \(originY))")
    }

    let renderer = CadRenderer(document: doc)
    if ProcessInfo.processInfo.environment["CADLENS_PROFILE"] != nil {
        print(String(format: "[perf] load=%.1fms  entities=%d  space=%d  visibleQuery=%@",
                     doc.loadMilliseconds, doc.entities.count, space,
                     "pending"))
    }
    var options = CadRenderer.Options()
    options.drawLines = true
    options.drawHatches = true
    options.drawText = true
    options.quality = 2
    options.minimumPixels = 0.02
    options.lineWidthScale = scale
    if let raw = ProcessInfo.processInfo.environment["CADLENS_LW_MULT"],
       let value = Double(raw), value > 0 {
        options.lineWidthMultiplier = CGFloat(value)
    }

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let profiling = ProcessInfo.processInfo.environment["CADLENS_PROFILE"] != nil
    // CADLENS_REPEAT re-draws the same camera N times into the same bitmap.
    // Frame 1 pays for every cache; frames 2..N are what a pan or a zoom tick
    // actually costs once the caches are warm, which is the number that
    // matters for interaction.
    let repeatCount = max(1, Int(
        ProcessInfo.processInfo.environment["CADLENS_REPEAT"] ?? "1") ?? 1)
    var bytes = [UInt8](repeating: 255, count: Int(viewW * viewH * 4))
    bytes.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress!,
                            width: Int(viewW), height: Int(viewH),
                            bitsPerComponent: 8,
                            bytesPerRow: Int(viewW * 4),
                            space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let worldRect = transform.worldRect(CGRect(x: 0, y: 0, width: viewW, height: viewH))
        for pass in 0..<repeatCount {
            ctx.saveGState()
            // Same canvas fill the window uses, so a dark-canvas export is not a
            // white sheet with colours corrected for a background it does not have.
            ctx.setFillColor(Theme.canvasBackground.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: viewW, height: viewH))
            ctx.translateBy(x: -originX * scale, y: -originY * scale)
            ctx.scaleBy(x: scale, y: scale)
            let queryStart = CACurrentMediaTime()
            let indices = doc.index(for: space).query(worldRect)
            let queryMs = (CACurrentMediaTime() - queryStart) * 1000
            let drawStart = CACurrentMediaTime()
            renderer.draw(entities: indices, space: space, in: ctx,
                          worldRect: worldRect, scale: scale, options: options)
            if profiling {
                print(String(format: "[frame %d] query=%.1fms draw=%.1fms candidates=%d",
                             pass, queryMs,
                             (CACurrentMediaTime() - drawStart) * 1000, indices.count))
            }
            ctx.restoreGState()
        }
    }
    let cg = CGContext(data: &bytes, width: Int(viewW), height: Int(viewH),
                       bitsPerComponent: 8,
                       bytesPerRow: Int(viewW * 4), space: colorSpace,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    guard let image = cg.makeImage() else { print("no image"); exit(1) }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
        print("no png"); exit(1)
    }
    do { try png.write(to: URL(fileURLWithPath: output)) } catch {
        print("write failed: \(error)"); exit(1)
    }
    print("rendered \(input) -> \(output)  scale=\(scale) origin=(\(originX),\(originY)) box=(\(box.minX),\(box.minY))-\(box.maxX),\(box.maxY))")
}

/// 把一组图标按工具栏的绘制方式排成一张对照图。
func glyphSheet(to path: String) {
    let items: [(String, CADGlyph)] = [("select", .select), ("trash", .trash),
                                       ("open", .open), ("print", .print),
                                       ("pan", .pan), ("zoomFit", .zoomFit)]
    let side: CGFloat = 110
    let size = CGSize(width: side * CGFloat(items.count + 2), height: side + 22)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                        bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(origin: .zero, size: size))
    // 与视图一致的翻转坐标系：原点在左上，y 向下。
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)
    for (index, item) in items.enumerated() {
        let rect = CGRect(x: CGFloat(index) * side + 12, y: 24,
                          width: side - 24, height: side - 24)
        item.1.draw(in: ctx, rect: rect, color: .black, lineWidth: 1.6)
        let label = NSAttributedString(string: item.0, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.black,
        ])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        label.draw(at: CGPoint(x: CGFloat(index) * side + 14, y: 4))
        NSGraphicsContext.restoreGraphicsState()
    }
    // 两个方向标：箭头画在 x 递增/ y 递增的方向上，用来确认翻转后的实际朝向。
    func marker(_ rect: CGRect, horizontal: Bool) {
        let s = rect.width / 24
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY + rect.height)
        ctx.scaleBy(x: s, y: -s)
        ctx.setLineWidth(1.2 / s)
        ctx.setStrokeColor(NSColor.systemRed.cgColor)
        ctx.setFillColor(NSColor.systemRed.cgColor)
        if horizontal {
            ctx.move(to: CGPoint(x: 3, y: 12))
            ctx.addLine(to: CGPoint(x: 21, y: 12))
            ctx.strokePath()
            ctx.move(to: CGPoint(x: 21, y: 12))
            ctx.addLine(to: CGPoint(x: 16, y: 15))
            ctx.addLine(to: CGPoint(x: 16, y: 9))
        } else {
            ctx.move(to: CGPoint(x: 12, y: 3))
            ctx.addLine(to: CGPoint(x: 12, y: 21))
            ctx.strokePath()
            ctx.move(to: CGPoint(x: 12, y: 21))
            ctx.addLine(to: CGPoint(x: 15, y: 16))
            ctx.addLine(to: CGPoint(x: 9, y: 16))
        }
        ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()
    }
    let hx = CGRect(x: CGFloat(items.count) * side + 12, y: 24, width: side - 24, height: side - 24)
    marker(hx, horizontal: true)
    marker(hx.offsetBy(dx: side, dy: 0), horizontal: false)

    guard let image = ctx.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: image)
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
        print("glyphs -> \(path)")
    }
}
