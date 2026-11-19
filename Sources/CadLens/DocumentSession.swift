import AppKit

/// 一张打开的图纸。
///
/// 窗口里只有一块画布，所谓"多图纸"是把每张图的状态存起来、切换时换进
/// 画布——相机、当前空间、选中的标注都跟着各自的图纸走，切回来还是离开时
/// 看到的那个位置。这和 AutoCAD 的多图形窗口、参照项目的文档标签是同一套
/// 模型：图纸之间不共享视图状态，也不共享标注。
final class DocumentSession {
    let url: URL
    let document: CadDocument
    /// 上次停留的空间（模型 / 布局），切换回来直接落到原处。
    var space: Int32
    /// 上次的相机。没有它就只能重新"显示全图"，而人往往是在某个节点上
    /// 切走、切回来还要接着看那里。
    var camera: ViewTransform
    /// 标注字号锁定的基准比例。切走再切回时如果不还原，部分标注会沿用上一
    /// 张图的基准，字号突然变大或变小。
    var fitScale: CGFloat = 0
    var selectedAnnotation: Int?
    /// 是否已经有过一次真实的取景。刚打开时相机是占位值（scale 1、原点 0），
    /// 直接拿来用会把图纸甩到屏幕外，必须走"显示全图"。
    var hasCamera = false

    init(url: URL, document: CadDocument) {
        self.url = url
        self.document = document
        self.space = Int32(document.defaultSpaceIndex)
        self.camera = ViewTransform()
        self.selectedAnnotation = nil
    }

    /// 标签上那行字。取文件名；同名图纸（不同目录下的 `平面图.dwg`）
    /// 才退到"文件名 — 上级目录"，否则两个一模一样的标签等于没有标签。
    var displayName: String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }

    var folderName: String {
        let parent = url.deletingLastPathComponent()
        return parent.lastPathComponent
    }

    /// 一张图的内存占用粗算，用于在标签 tooltip 里交代"关掉它能省多少"。
    /// 只看图元数组，几何缓存不算在内——那是可以被重建的。
    var footprint: Int {
        document.entities.count
    }
}
