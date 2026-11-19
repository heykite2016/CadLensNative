import AppKit

/// 画布深浅。
///
/// CAD 的画布按行规默认是深色；需要核对纸质效果时临时切成浅色。界面外观
/// 跟着画布走：深色画布配深色界面，浅色画布配浅色界面（见
/// `applyAppearanceForCanvasTone`）。`auto` 则让画布和界面一起跟随系统。
enum CanvasTone: String, CaseIterable {
    case auto, light, dark

    var title: String {
        switch self {
        case .auto: return "跟随系统"
        case .light: return "浅色画布 · 浅色界面"
        case .dark: return "深色画布 · 深色界面"
        }
    }
}

extension Notification.Name {
    /// 画布配色变了：所有自绘控件和光栅缓存要重取颜色。
    static let cadLensThemeChanged = Notification.Name("CadLensThemeChanged")
}

/// Single source of truth for the native look: system colours, CAD canvas
/// colours, and dimension styling shared by the canvas and the inspector.
enum Theme {
    // MARK: 画布配色

    private static let canvasToneKey = "CadLensCanvasTone"

    static var canvasTone: CanvasTone {
        get {
            // 截图脚本用它把画布单独钉成深/浅，不去动用户的偏好。
            if let forced = getenv("CADLENS_CANVAS_TONE"),
               let tone = CanvasTone(rawValue: String(cString: forced)) {
                return tone
            }
            return CanvasTone(rawValue: UserDefaults.standard.string(forKey: canvasToneKey) ?? "")
                ?? .dark
        }
        set {
            guard newValue != canvasTone else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: canvasToneKey)
            applyAppearanceForCanvasTone()
            // 画布底色、纸面、栅格、ACI 7 图元、标注墨色和十字光标都由它派生，
            // 等于一次"配色换了"，走同一条广播让所有缓存失效。
            NotificationCenter.default.post(name: .cadLensThemeChanged, object: nil)
        }
    }

    /// 界面外观跟着画布走：深色画布 → 深色系统控件，浅色画布 → 浅色。
    /// `auto` 让两者一起跟随系统。截图脚本用 `CADLENS_APPEARANCE` 单独钉住
    /// 外观时不要覆盖它——那条路径要能自由组合"深界面 + 浅画布"做对照。
    static func applyAppearanceForCanvasTone() {
        guard getenv("CADLENS_APPEARANCE") == nil else {
            refreshAppearance()
            return
        }
        let appearance: NSAppearance?
        switch canvasTone {
        case .dark: appearance = NSAppearance(named: .darkAqua)
        case .light: appearance = NSAppearance(named: .aqua)
        case .auto: appearance = nil
        }
        if NSApp?.appearance !== appearance {
            NSApp?.appearance = appearance
        }
        refreshAppearance()
    }

    /// 启动时定下外观基准，不广播（那时还没有窗口）。
    static func activateSavedTheme() {
        applyAppearanceForCanvasTone()
    }

    /// 一张完整的界面配色表。自绘控件只从这里取色。
    struct Palette {
        let dark: Bool
        let accent: NSColor
        let canvasBackground: NSColor
        let canvasPaper: NSColor
        let canvasGrid: NSColor
        let foreground: NSColor
        let measurement: NSColor
        let measurementFillAlpha: CGFloat
        let chrome: NSColor
        let chromeSunken: NSColor
        let panel: NSColor
        let tabFill: NSColor
        let hairline: NSColor
        let iconIdle: NSColor
        let groupTitle: NSColor
        let hoverFill: NSColor
        let chromeTint: NSColor
        let panelTint: NSColor
        let sunkenTint: NSColor
        let commandFill: NSColor
        let commandField: NSColor
        let selection: NSColor
        let snapMarker: NSColor
    }

    private static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                blue: CGFloat(b) / 255, alpha: a)
    }

    /// 薄荷青柠：白纸 + 薄荷绿 + 柠檬黄。日间最清爽的一套。
    private static let mintPalette = Palette(
        dark: false,
        accent: rgb(18, 184, 134),
        // 浅色下画布必须比玻璃暗一档。原先底色接近白（247,252,249），白玻璃
        // 压上去和桌面糊成一片，浮岛等于消失了；这里退到淡灰绿，纸面仍是纯白，
        // 于是"桌子 → 玻璃 → 纸"三层一眼分得开。
        canvasBackground: rgb(228, 235, 231),
        canvasPaper: .white,
        canvasGrid: NSColor(white: 0, alpha: 0.07),
        foreground: rgb(22, 48, 42),
        measurement: rgb(11, 143, 105),
        measurementFillAlpha: 0.10,
        chrome: rgb(255, 255, 255),
        chromeSunken: rgb(242, 249, 245),
        panel: rgb(246, 251, 248),
        tabFill: rgb(231, 246, 239),
        hairline: NSColor(white: 0, alpha: 0.10),
        iconIdle: rgb(44, 74, 64),
        groupTitle: rgb(92, 122, 111),
        hoverFill: NSColor(white: 0, alpha: 0.05),
        chromeTint: rgb(255, 255, 255, 0.74),
        panelTint: rgb(244, 251, 247, 0.72),
        sunkenTint: rgb(237, 246, 241, 0.80),
        commandFill: rgb(255, 255, 255, 0.97),
        commandField: NSColor(white: 0.35, alpha: 0.05),
        selection: rgb(18, 184, 134),
        snapMarker: rgb(239, 169, 32))

    /// 夜航霓虹：深墨底 + 电光紫 + 珊瑚粉。夜里看不刺眼。
    private static let neonPalette = Palette(
        dark: true,
        accent: rgb(124, 92, 255),
        canvasBackground: rgb(15, 20, 36),
        canvasPaper: rgb(20, 26, 44),
        canvasGrid: NSColor(white: 1, alpha: 0.06),
        foreground: rgb(231, 235, 255),
        measurement: rgb(255, 128, 149),
        measurementFillAlpha: 0.12,
        chrome: rgb(23, 29, 49),
        chromeSunken: rgb(18, 23, 40),
        panel: rgb(26, 33, 56),
        tabFill: rgb(42, 51, 80),
        hairline: NSColor(white: 1, alpha: 0.09),
        iconIdle: rgb(201, 208, 232),
        groupTitle: rgb(154, 163, 196),
        hoverFill: NSColor(white: 1, alpha: 0.07),
        chromeTint: rgb(22, 28, 48, 0.64),
        panelTint: rgb(26, 33, 56, 0.58),
        sunkenTint: rgb(15, 20, 36, 0.72),
        commandFill: rgb(13, 18, 32, 0.96),
        commandField: NSColor(white: 1, alpha: 0.06),
        selection: rgb(124, 92, 255),
        snapMarker: rgb(255, 153, 102))

    /// 奶油焦糖：暖白 + 砖红 + 墨绿。复古，长时间看不累。
    private static let caramelPalette = Palette(
        dark: false,
        accent: rgb(180, 85, 45),
        canvasBackground: rgb(253, 250, 244),
        canvasPaper: .white,
        canvasGrid: NSColor(white: 0, alpha: 0.05),
        foreground: rgb(46, 36, 29),
        measurement: rgb(31, 111, 92),
        measurementFillAlpha: 0.10,
        chrome: rgb(247, 239, 227),
        chromeSunken: rgb(241, 230, 214),
        panel: rgb(251, 246, 236),
        tabFill: rgb(239, 226, 208),
        hairline: NSColor(white: 0, alpha: 0.12),
        iconIdle: rgb(62, 47, 36),
        groupTitle: rgb(122, 99, 83),
        hoverFill: NSColor(white: 0, alpha: 0.05),
        chromeTint: rgb(247, 239, 227, 0.72),
        panelTint: rgb(251, 246, 236, 0.66),
        sunkenTint: rgb(239, 228, 211, 0.80),
        commandFill: rgb(255, 253, 248, 0.97),
        commandField: NSColor(white: 0.35, alpha: 0.04),
        selection: rgb(180, 85, 45),
        snapMarker: rgb(31, 111, 92))

    /// 界面令牌始终走系统外观。画布另有明暗开关，两者不再互相牵连。
    static var palette: Palette { systemPalette }

    /// 界面令牌表：工具栏、面板用的是系统深/浅两套取色；画布另有开关。
    private static var systemPalette: Palette {
        let dark = systemDark
        return Palette(
            dark: dark,
            // 固定的品牌蓝而不是系统强调色：去掉主题切换后，界面需要一张
            // 自己认得出的脸。深浅两档保证在两种系统外观下都够清楚。
            accent: dark ? rgb(96, 165, 250) : rgb(37, 99, 235),
            canvasBackground: dark ? NSColor(srgbRed: 0.09, green: 0.10, blue: 0.12, alpha: 1)
                                   : NSColor(srgbRed: 0.985, green: 0.987, blue: 0.99, alpha: 1),
            canvasPaper: dark ? NSColor(srgbRed: 0.13, green: 0.14, blue: 0.16, alpha: 1) : .white,
            canvasGrid: dark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.05),
            foreground: dark ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.12, alpha: 1),
            measurement: dark ? NSColor(srgbRed: 0.216, green: 0.839, blue: 0.478, alpha: 1)
                              : NSColor(srgbRed: 0.055, green: 0.482, blue: 0.243, alpha: 1),
            measurementFillAlpha: dark ? 0.12 : 0.10,
            chrome: dark ? NSColor(srgbRed: 0.125, green: 0.137, blue: 0.157, alpha: 1)
                         : NSColor(srgbRed: 0.898, green: 0.906, blue: 0.918, alpha: 1),
            chromeSunken: dark ? NSColor(srgbRed: 0.098, green: 0.106, blue: 0.122, alpha: 1)
                               : NSColor(srgbRed: 0.863, green: 0.873, blue: 0.886, alpha: 1),
            panel: dark ? NSColor(srgbRed: 0.145, green: 0.157, blue: 0.176, alpha: 1)
                        : NSColor(srgbRed: 0.933, green: 0.937, blue: 0.945, alpha: 1),
            tabFill: dark ? NSColor(srgbRed: 0.20, green: 0.215, blue: 0.24, alpha: 0.92)
                          : NSColor(srgbRed: 0.86, green: 0.868, blue: 0.882, alpha: 0.95),
            hairline: dark ? NSColor(white: 1, alpha: 0.085) : NSColor(white: 0, alpha: 0.135),
            iconIdle: dark ? NSColor(white: 0.82, alpha: 1) : NSColor(white: 0.26, alpha: 1),
            groupTitle: dark ? NSColor(white: 0.74, alpha: 1) : NSColor(white: 0.28, alpha: 1),
            hoverFill: dark ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.055),
            chromeTint: dark ? NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 0.58)
                             : NSColor(srgbRed: 0.95, green: 0.955, blue: 0.962, alpha: 0.62),
            panelTint: dark ? NSColor(srgbRed: 0.13, green: 0.14, blue: 0.16, alpha: 0.52)
                            : NSColor(srgbRed: 0.96, green: 0.963, blue: 0.97, alpha: 0.58),
            sunkenTint: dark ? NSColor(srgbRed: 0.085, green: 0.092, blue: 0.106, alpha: 0.66)
                             : NSColor(srgbRed: 0.905, green: 0.912, blue: 0.923, alpha: 0.70),
            commandFill: dark ? NSColor(srgbRed: 0.072, green: 0.079, blue: 0.092, alpha: 0.96)
                              : NSColor(srgbRed: 0.992, green: 0.993, blue: 0.996, alpha: 0.97),
            commandField: dark ? NSColor(white: 1, alpha: 0.055) : NSColor(white: 0.35, alpha: 0.05),
            selection: NSColor(srgbRed: 0.20, green: 0.55, blue: 1.0, alpha: 1),
            snapMarker: NSColor(srgbRed: 1.0, green: 0.62, blue: 0.10, alpha: 1))
    }

    static var accent: NSColor { palette.accent }

    /// 打印时的外观开关。
    ///
    /// 屏幕上的深色画布直接打到纸上是一张全黑纸，所以打印必须走"白纸"这套
    /// 取色：`isDark` 被压成 false，颜色走浅色画布那条降亮分支，黑白模式下
    /// 所有线条统一成黑色。这三个开关是全局的、只在打印上下文里短暂打开，
    /// 打完整块恢复——把状态存在渲染器里反而更容易漏掉一次恢复。
    enum PrintAppearance {
        static var isPrinting = false
        static var monochrome = false
        /// 灰度输出：保留明暗层次，去掉彩度。施工图用灰度打，既分得清图层，
        /// 又不会因为彩色墨盒见底而变成一张淡图。
        static var grayscale = false

        static func with<T>(monochrome: Bool, grayscale: Bool = false,
                            _ body: () -> T) -> T {
            let previousPrinting = isPrinting
            let previousMonochrome = Self.monochrome
            let previousGrayscale = Self.grayscale
            isPrinting = true
            Self.monochrome = monochrome
            Self.grayscale = grayscale
            defer {
                isPrinting = previousPrinting
                Self.monochrome = previousMonochrome
                Self.grayscale = previousGrayscale
            }
            return body()
        }
    }

    /// Which canvas palette is in force.
    ///
    /// Normally the system appearance decides. `CADLENS_APPEARANCE=dark|light`
    /// overrides it, which is how the headless renderer exercises the
    /// dark-canvas branch and how a reviewer can flip palettes without
    /// changing macOS settings.
    ///
    /// Deliberately a computed value rather than an NSColor
    /// `dynamicProvider:`: those resolve against `NSAppearance.current`, which
    /// in an offscreen Core Graphics context is always the aqua appearance, so
    /// the dark palette silently never applied when rendering to a file.
    static var isDark: Bool {
        // 打印永远是白纸，与系统外观、画布开关都无关。
        if PrintAppearance.isPrinting { return false }
        // `getenv`, not ProcessInfo: ProcessInfo snapshots the environment on
        // first access, so a value installed by the headless entry point after
        // that point would be invisible here.
        if getenv("CADLENS_APPEARANCE") != nil { return systemDark }
        switch canvasTone {
        case .dark: return true
        case .light: return false
        case .auto: return systemDark
        }
    }

    private static var cachedDark: Bool?

    /// 系统外观，或 `CADLENS_APPEARANCE` 强制指定。与画布开关无关。
    private static var systemDark: Bool {
        // Cached because the renderer now runs on a background queue, and
        // `NSApp.effectiveAppearance` is an AppKit call that belongs to the
        // main thread. The cache is refreshed from the view when the system
        // appearance actually changes.
        if let cached = cachedDark { return cached }
        let resolved = NSApp?.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        cachedDark = resolved
        return resolved
    }

    /// Re-reads the system appearance. Must be called on the main thread.
    static func refreshAppearance() {
        cachedDark = NSApp?.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// 画布底色。深色画布是 CAD 行规（默认），浅色只在需要看纸质效果时用。
    static var canvasBackground: NSColor {
        if PrintAppearance.isPrinting { return .white }
        return isDark ? rgb(13, 17, 23) : rgb(248, 249, 251)
    }

    static var canvasPaper: NSColor {
        if PrintAppearance.isPrinting { return .white }
        return isDark ? rgb(20, 25, 32) : .white
    }

    static var canvasGrid: NSColor {
        isDark ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.05)
    }

    /// ACI 7 means "black or white depending on background" in CAD.
    static var foreground: NSColor {
        isDark ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.12, alpha: 1)
    }

    /// 十字光标线：与画布底色反相，保证黑底白线、白底黑线。
    static var crosshair: NSColor {
        isDark ? NSColor(white: 0.90, alpha: 1) : NSColor(white: 0.10, alpha: 1)
    }

    /// 光标描边下的对比色描边：即使光标压在同色图元上仍然看得见，相当于
    /// CAD 里 XOR 反色绘制的静态近似（图层版无法逐帧 XOR 整个 backing store）。
    static var crosshairHalo: NSColor {
        isDark ? NSColor(white: 0, alpha: 0.75) : NSColor(white: 1, alpha: 0.85)
    }

    static var selection: NSColor { palette.selection }
    static var snapMarker: NSColor {
        // 捕捉标记同样要跟画布反相，浅底上把亮橙压深一档才看得清。
        isDark ? rgb(255, 158, 26) : rgb(180, 78, 0)
    }

    /// Annotation ink. The reference implementation ships #37d67a, which is
    /// what a Chinese interior drawing office expects to see over a black
    /// sheet; the light-canvas variant is darkened so it still reads on paper.
    static var measurementStroke: NSColor {
        // 标注墨色按画布明暗取：深底用亮绿，浅底压暗，避免与底色同亮度。
        let base = rgb(55, 214, 122)
        return isDark ? base : dimmedForLightCanvas(base)
    }

    static var measurementFill: NSColor {
        measurementStroke.withAlphaComponent(palette.measurementFillAlpha)
    }

    // MARK: Application chrome
    //
    // A CAD window is a dense instrument panel, not a translucent sidebar
    // stack. These are solid, low-contrast surfaces so the drawing stays the
    // brightest thing on screen.

    /// Toolbar / status bar / palette surface.
    static var chrome: NSColor { palette.chrome }

    /// Slightly deeper surface used for the command line and the dock headers.
    static var chromeSunken: NSColor { palette.chromeSunken }

    /// Panel body (layer / annotation docks).
    static var panel: NSColor { palette.panel }

    /// 激活标签的底色。比面板再实一点，压在模糊材质上才看得出是一块"被选中
    /// 的纸"，而不是一团更亮的雾。
    static var tabFill: NSColor { palette.tabFill }

    static var hairline: NSColor { palette.hairline }

    /// Icons sit one step below label colour until they are active.
    static var iconIdle: NSColor { palette.iconIdle }

    static var groupTitle: NSColor {
        // 小字号 + 半透明底 = 对比度最先失守的地方。分组的标题是导航，掉了
        // 对比度整列就散了，所以它比 secondaryLabel 再深一档。
        palette.groupTitle
    }

    static var hoverFill: NSColor { palette.hoverFill }

    // MARK: 设计令牌（Apple HIG）
    //
    // 数值来自 HIG 速查表，不凭手感：圆角按控件尺寸分档，动效一律走
    // 120–280ms 的 ease-out，间距是 4pt 网格。散落在各控件里的魔法数字
    // 一多，界面就会有种"每个角落的圆角都不一样"的廉价感。

    enum Radius {
        /// 工具栏/面板里的单格按钮：8pt 是 macOS 控件的标准圆角。
        static let control: CGFloat = 8
        /// 卡片、分组容器。
        static let card: CGFloat = 10
        /// 标签、徽章、小胶囊。
        static let small: CGFloat = 6
        /// 状态栏那种极扁的开关。
        static let pill: CGFloat = 999
    }

    enum Motion {
        /// hover 底色淡入。
        static let hover: TimeInterval = 0.12
        /// 按下回弹。
        static let press: TimeInterval = 0.10
        /// 面板开合、切页这类结构性变化。
        static let standard: TimeInterval = 0.26
        /// 与 `standard` 配套的曲线：起步快、收尾慢，接近临界阻尼弹簧
        /// （bounce 0）的手感，但不需要维护一个真正的物理弹簧对象。
        static let springCurve = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)

        static let easeOutCurve = CAMediaTimingFunction(name: .easeOut)
    }

    /// 材质上的半透明着色。自绘背景从这里取色而不是取不透明的 `chrome`：
    /// 只有半透明才看得见底下那层材质，层级也才有厚度可言。
    static var chromeTint: NSColor { palette.chromeTint }

    static var panelTint: NSColor { palette.panelTint }

    static var sunkenTint: NSColor { palette.sunkenTint }

    /// 命令行整条底色。比工具栏再沉一档、并且更实：它是一条可以打字的输入区，
    /// 和画布/工具栏混成同一个灰面时，用户找不到"该往哪儿输入"。
    static var commandFill: NSColor { palette.commandFill }

    /// 命令行里的输入井（输入框所在的凹槽）。
    static var commandField: NSColor { palette.commandField }

    static func aciColor(_ aci: UInt8, rgb: UInt32) -> NSColor {
        // 黑白打印：A CI 7 与白色图元在纸上都会消失，一律压成黑线；
        // 灰度模式交给后面的 displayColor 去降饱和。
        if PrintAppearance.isPrinting {
            if PrintAppearance.monochrome { return .black }
            if aci == 7 || rgb == 0 || rgb == 0xFFFFFF { return .black }
        }
        // ACI 7 is the only index that means "background contrast colour".
        // ACI 0 is BYBLOCK: the reader has already substituted the enclosing
        // insert's colour into `rgb`, so testing the index here would repaint
        // every BYBLOCK detail of a coloured block in black and white. Decide
        // on the resolved RGB instead, and only fall back to the contrast
        // colour when that RGB carries nothing usable.
        if aci == 7 { return foreground }
        if rgb == 0 || rgb == 0xFFFFFF { return foreground }
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        var color = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        color = displayColor(color)
        if PrintAppearance.isPrinting && PrintAppearance.grayscale {
            if let srgb = color.usingColorSpace(.sRGB) {
                let grey = luminance(srgb.redComponent, srgb.greenComponent,
                                     srgb.blueComponent)
                color = NSColor(srgbRed: grey, green: grey, blue: grey, alpha: 1)
            }
        }
        return color
    }

    /// Reference CadView.cpp::displayColor(). Which direction the correction
    /// runs depends on the canvas, and getting it backwards is what makes a
    /// drawing look "not the same colour as the file":
    ///
    /// * Light canvas  (`CadLight`) — the problem colour is TOO BRIGHT. Yellow
    ///   on white is invisible, so anything above 0.48 relative luminance is
    ///   scaled down in 8 % steps to ≤ 0.4. Dark grades pass through.
    /// * Dark canvas  (default `CadDark`) — the problem colour is TOO DARK.
    ///   Black-on-black and a solid ACI 7 fill disappear, so anything below
    ///   0.12 luminance is lifted, preserving hue and saturation
    ///   (CadModel.cpp::displayColorForDarkCanvas). Bright grades pass through,
    ///   which is why an ACI 2 dimension stays yellow instead of turning into
    ///   washed-out cream.
    ///
    /// Applying the light-canvas branch unconditionally both dimmed the yellows
    /// and left near-black geometry invisible on a dark canvas.
    static func displayColor(_ color: NSColor) -> NSColor {
        isDark ? liftedForDarkCanvas(color) : dimmedForLightCanvas(color)
    }

    /// Reference CadView.cpp::displayColor() light-canvas branch. Anything
    /// above 0.48 relative luminance is scaled down in 8 % steps until it
    /// reaches 0.4, and only a colour that cannot get there at all collapses
    /// to #101820. Dark, saturated ACI grades are returned untouched, which is
    /// what keeps the sheet looking like the drawing instead of a pastel
    /// reinterpretation.
    static func dimmedForLightCanvas(_ color: NSColor) -> NSColor {
        guard let srgb = color.usingColorSpace(.sRGB) else { return color }
        let red = srgb.redComponent
        let green = srgb.greenComponent
        let blue = srgb.blueComponent
        if luminance(red, green, blue) <= 0.48 { return color }
        var amount: CGFloat = 0.08
        while amount <= 1.0 {
            let scale = 1 - amount
            if luminance(red * scale, green * scale, blue * scale) <= 0.4 {
                return NSColor(srgbRed: red * scale, green: green * scale,
                               blue: blue * scale, alpha: srgb.alphaComponent)
            }
            amount += 0.08
        }
        return NSColor(srgbRed: 0x10 / 255.0, green: 0x18 / 255.0,
                       blue: 0x20 / 255.0, alpha: srgb.alphaComponent)
    }

    /// Reference CadModel.cpp::displayColorForDarkCanvas(). Lifts colours that
    /// are too dark to see on a black canvas. Chromatic colours keep hue and
    /// saturation and are brightened along V until they clear 0.18 luminance;
    /// blending a dark red toward white instead produces the washed-out pastel
    /// look of a generic dark-theme converter, so that is only done for
    /// neutrals.
    static func liftedForDarkCanvas(_ color: NSColor) -> NSColor {
        guard let srgb = color.usingColorSpace(.sRGB) else { return color }
        let alpha = srgb.alphaComponent
        let red = srgb.redComponent
        let green = srgb.greenComponent
        let blue = srgb.blueComponent
        if luminance(red, green, blue) >= 0.12 { return color }

        var hue: CGFloat = -1
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var ignoredAlpha: CGFloat = 1
        srgb.getHue(&hue, saturation: &saturation,
                    brightness: &brightness, alpha: &ignoredAlpha)
        let hsv = hue >= 0
            ? (hue: hue, saturation: saturation, value: brightness)
            : (hue: -1 as CGFloat, saturation: 0 as CGFloat,
               value: max(red, green, blue))
        if hsv.saturation >= 0.32, hsv.hue >= 0 {
            var value = max(64.0 / 255.0, hsv.value)
            while value <= 1.0 {
                let candidate = NSColor(hue: hsv.hue, saturation: hsv.saturation,
                                        brightness: value, alpha: alpha)
                if let rgb = candidate.usingColorSpace(.sRGB),
                   luminance(rgb.redComponent, rgb.greenComponent,
                             rgb.blueComponent) >= 0.18 {
                    return candidate
                }
                value += 8.0 / 255.0
            }
            return NSColor(hue: hsv.hue, saturation: hsv.saturation,
                           brightness: 1, alpha: alpha)
        }

        // Neutral black and greys have no hue worth preserving; raise them
        // toward light grey for visibility on the black canvas.
        var amount: CGFloat = 0.2
        while amount <= 0.75 {
            let r = red * (1 - amount) + amount
            let g = green * (1 - amount) + amount
            let b = blue * (1 - amount) + amount
            if luminance(r, g, b) >= 0.18 {
                return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
            }
            amount += 0.05
        }
        return NSColor(srgbRed: red * 0.25 + 0.75, green: green * 0.25 + 0.75,
                       blue: blue * 0.25 + 0.75, alpha: alpha)
    }

    private static func linear(_ value: CGFloat) -> CGFloat {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private static func luminance(_ red: CGFloat, _ green: CGFloat,
                                 _ blue: CGFloat) -> CGFloat {
        0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// Reference CadView.cpp::lineWidthPixels(): the 24 DXF lineweight grades
    /// map to 0.55 + millimetres * 1.35 screen points, with NO floor and no
    /// ceiling. A `max(value, 1.0)` guard here lifted every 0.05–0.33 mm line
    /// to a full point, so the whole sheet drew ~60 % heavier than the source
    /// drawing.
    static func lineWidth(_ mm: Float) -> CGFloat {
        guard mm > 0 else { return 1.25 }
        return 0.55 + CGFloat(mm) * 1.35
    }
}


// MARK: - Material layers

extension NSView {
    /// 在视图最底层铺一层窗口材质。
    ///
    /// 自绘面板原先填的是不透明色，整块窗口看起来像一张拼起来的色卡。
    /// 铺材质 + 把自绘背景改成半透明 tint 之后，工具栏、侧栏会像原生 App
    /// 那样"浮"在图纸之上——层级由材质厚度表达，而不是靠加边框。
    ///
    /// 只在窗口层级用（工具栏/侧栏/命令行/状态栏），不进图纸内容层：CAD 的
    /// 画布必须是实色，毛玻璃进内容层会让线条对比随背景漂移。
    @discardableResult
    func installMaterial(_ material: NSVisualEffectView.Material,
                         blending: NSVisualEffectView.BlendingMode = .behindWindow,
                         emphasized: Bool = false) -> NSVisualEffectView {
        let effect = NSVisualEffectView()
        effect.material = material
        effect.blendingMode = blending
        effect.state = .followsWindowActiveState
        effect.isEmphasized = emphasized
        effect.translatesAutoresizingMaskIntoConstraints = false
        if let first = subviews.first {
            addSubview(effect, positioned: .below, relativeTo: first)
        } else {
            addSubview(effect, positioned: .below, relativeTo: nil)
        }
        // 约束而不是 autoresizing：面板在 init 时尺寸还是零，按比例自适应的
        // 子视图会一直停在零宽。
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        return effect
    }
}

/// 自绘控件上的圆角底色。
///
/// 用 CALayer 而不是在 `draw(_:)` 里填色，是因为 hover 与选中态必须淡入
/// 淡出：AppKit 的自绘视图每次重画都是一次硬跳变，而"瞬间跳变的底色"
/// 是界面显得粗糙的第一来源。layer 的 backgroundColor 天生可动画。
final class FadeBackdrop {
    private let layer = CALayer()
    private let cornerRadius: CGFloat
    private weak var host: NSView?

    init(host: NSView, cornerRadius: CGFloat = Theme.Radius.control,
         inset: NSEdgeInsets = NSEdgeInsets(top: 2, left: 1.5, bottom: 2, right: 1.5)) {
        self.host = host
        self.cornerRadius = cornerRadius
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.backgroundColor = nil
        host.wantsLayer = true
        host.layer?.insertSublayer(layer, at: 0)
        self.inset = inset
    }

    private var inset = NSEdgeInsets(top: 2, left: 1.5, bottom: 2, right: 1.5)

    /// 由宿主在 `layout()` 里调用：自绘视图的尺寸变化不会自动传到子 layer。
    func layout() {
        guard let host else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = CGRect(x: inset.left, y: inset.top,
                             width: max(host.bounds.width - inset.left - inset.right, 0),
                             height: max(host.bounds.height - inset.top - inset.bottom, 0))
        CATransaction.commit()
    }

    func setTint(_ color: NSColor?, animated: Bool = true) {
        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Theme.Motion.hover)
            CATransaction.setAnimationTimingFunction(Theme.Motion.easeOutCurve)
            layer.backgroundColor = color?.cgColor
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.backgroundColor = color?.cgColor
            CATransaction.commit()
        }
    }

    /// 按下时整格轻微内缩：HIG 的按压反馈是 scale 0.97，不是变深。
    func setPressed(_ pressed: Bool) {
        guard let host, let hostLayer = host.layer else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Theme.Motion.press)
        CATransaction.setAnimationTimingFunction(Theme.Motion.easeOutCurve)
        hostLayer.transform = pressed ? CATransform3DMakeScale(0.96, 0.96, 1) : CATransform3DIdentity
        CATransaction.commit()
    }
}

// MARK: - 主题切换

/// 主题变化后需要重新取色的自绘控件。
///
/// 大部分控件在 `draw(_:)` 里现取 `Theme.xxx`，`needsDisplay` 一句话就够；
/// 但把颜色缓存进 `CALayer` 的（hover 底色、选中药丸）必须显式重取。
protocol ThemeAware: AnyObject {
    func themeDidChange()
}

extension NSView {
    /// 递归刷新：先重取缓存色，再让每一层重画。
    func applyThemeRecursively() {
        (self as? ThemeAware)?.themeDidChange()
        needsDisplay = true
        for subview in subviews { subview.applyThemeRecursively() }
    }
}

/// 1pt 分隔线。
///
/// 原先每个分隔线都是一个 `wantsLayer` 的 NSView + 一次性写入的
/// `backgroundColor`。那种写法换主题后还留着上一套的灰色，所以改成自绘：
/// 每次画都重取 `Theme.hairline`，主题切换自动跟上。
final class HairlineView: NSView {
    private let vertical: Bool

    init(vertical: Bool = true) {
        self.vertical = vertical
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        Theme.hairline.setFill()
        if vertical {
            NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        } else {
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        }
    }
}
