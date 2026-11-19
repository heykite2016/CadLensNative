# 速看CAD · CadLens Native

> macOS 原生 DWG/DXF/PDF 看图与现场测量工具。纯 Swift + AppKit，DWG/DXF 解析沿用
> LibreDWG + libdxfrw，渲染走 Metal + Core Graphics 分块管线；没有 Qt 运行期依赖。

**GitHub:** https://github.com/heykite2016/CadLensNative  
**Gitee:** https://gitee.com/FanieWang/CadLensNative

## 下载

在 Releases 里下载 macOS 版本（当前构建为 **x86_64**）：

- `CadLens-3.0.0-macos-x86_64.dmg`：拖进「应用程序」即可
- `CadLens-3.0.0-macos-x86_64.zip`：绿色版

应用使用 ad-hoc 签名（没有 Apple 公证）。第一次打开如果被 Gatekeeper 拦住：

```bash
xattr -dr com.apple.quarantine /Applications/CadLens.app
```

或右键 App →「打开」→「仍要打开」。

## 默认打开方式

安装包声明了 `.dwg` / `.dxf` 文档类型和独立文件图标，并把 `LSHandlerRank` 设为
`Default`。要把当前用户的默认打开方式明确切换到速看CAD：

```bash
# 先注册 App
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f /Applications/CadLens.app

# 编译并运行默认打开方式脚本
swiftc -O Tools/set_default_cad_app.swift -o /tmp/set-cad-default -framework CoreServices
/tmp/set-cad-default
```

也可以随时在 Finder 里选中 `.dwg` / `.dxf` →「显示简介」→「打开方式」里改回其他软件。

```
CadLensNative/
├── Sources/CadCore/          # C++ 解析核心，扁平 C ABI（cadcore.h）
│   ├── cadcore.cpp           # DWG/DXF → 实体/点/图层/空间/视口/填充
│   └── include/              # cadcore.h + module.modulemap（Swift 直接 import）
├── Sources/CadLens/          # Swift/AppKit 应用
├── Sources/cadtool/          # 命令行诊断工具（读图、统计、按图层导出）
├── Tools/                    # 样例图纸与应用图标生成脚本
├── Resources/                # Info.plist、AppIcon.icns
├── Samples/                  # plan.dxf（AC1015）、plan.pdf（矢量施工图）
└── build.sh                  # 一键构建 + 打包 .app
```

## 从源码构建

需要 macOS 12+、Xcode Command Line Tools（Swift 6），以及 LibreDWG / libdxfrw 静态库。
依赖编译和目录约定见 [DEPENDENCIES.md](DEPENDENCIES.md)。

```bash
export LIBSHARE=/path/to/libshare
./build.sh          # 生成 build/CadLens.app
./build.sh tool     # 额外生成 build/cadtool
open -a build/CadLens.app Samples/plan.dxf
```

产物是 ad-hoc 签名的普通 `.app`，可以直接拖进「应用程序」目录。构建脚本也接受
`SWIFTC=/path/to/swiftc` 与 `CXX=/path/to/clang++`，便于在非标准工具链下复现。

## 功能

**查看**
- DWG（R13–R2018，LibreDWG）、DXF（libdxfrw 主通路，LibreDWG 兜底）、PDF（PDFKit）三种来源
- 实体覆盖：直线/圆弧/圆/椭圆/样条/多段线（含 bulge 圆弧）/文字与多行文字/块参照（含属性、
  阵列插入、嵌套 12 层）/实体填充/图案填充（含图案线角度、间距、虚线与多环挖空）
- 布局/图纸空间切换；PDF 按页切换（侧栏页面列表与底部页码条联动）；
  打开时自动落在**第一个有图元的空间**，避免图纸全部画在布局里时开出来是空白
- 图层可见性、冻结、锁定状态；侧栏开关图层、全部显示/隐藏
- 线宽显示开关、栅格、十字光标、对象捕捉标记
- 外观跟随系统 / 强制浅色 / 强制深色（CAD 暗色配色自动提亮深色图层）

**测量**（13 种，全部可持久化）
对齐、线性、连续、快速标注 QDIM、矩形面积、多边形面积、圆面积、填充面积、半径、角度、弧长、侧面积、文字注释。
对齐/线性在两点之后用第三点定尺寸线位置（和 DIMALIGNED/DIMLINEAR 一致）；快速标注框选后
先预览、再点击/回车放置。取点支持端点/中点/圆心/最近点捕捉、正交约束、Shift 极轴锁定；
标注可拖动文字位置、选中高亮、双击侧栏跳转、Delete 删除、⌘⇧⌫ 全部清除。

**输出**
- 导出 PNG（按屏显比例，2× 像素密度）
- 导出 PDF（矢量，不受窗口分辨率限制；PDF 来源会直接嵌入原页，不重采样）
- 打印（自动适配纸张、居中）

**其它**
- 标注按图纸路径哈希存储于 `~/Library/Application Support/CadLensNative/annotations/`，
  重新打开自动恢复；撤销/重做走 `NSUndoManager`
- 最近打开菜单、拖拽图纸到窗口打开、窗口位置记忆、单窗口复用

## 快捷键

| 操作 | 快捷键 |
|---|---|
| 打开 / 导出 PNG / 打印 | ⌘O / ⌘E / ⌘P |
| 放大 / 缩小 / 显示全图 | ⌘+ / ⌘- / ⌘0 |
| 对象捕捉 / 正交 / 栅格 / 线宽 | F3 / F8 / F7 / ⌘L |
| 信息面板 | ⌥⌘S |
| 测量工具 | A 对齐、L 线性、C 连续、QDIM 快速标注、R 矩形、P 多边形、O 圆面积、F 填充面积、D 半径、G 角度、K 弧长、S 侧面积、T 注释 |
| 取消取点 / 结束 / 删除标注 | Esc / ⏎ / Delete |
| 重复上一个测量工具 | 空闲时 ⏎ 或空格 |
| 全部标注清除 | ⌘⇧⌫ |

## 性能设计

原项目为了性能砍了功能（分块光栅、限制实体数）。这一版换掉取舍方式，
在保留全部功能、不降低任何渲染质量的前提下用架构换性能。

先给一台最低配机器的实测数字（大图 189,116 图元 / 8.5 MB DWG，2560×1600 Retina，
i5-8210Y + Intel UHD 617 集显）：

| 场景 | 旧架构（每帧全量重绘） | 现在 |
| --- | --- | --- |
| 全质量一帧 | 3095 ms | 5 ms CPU + 4.5 ms GPU |
| 拖拽/缩放一帧 | 3095 ms | 2~3 ms CPU + 4.5 ms GPU（受 60 Hz 节拍限制） |

三个渲染层各司其职，且**都只在自己真正变化时才付钱**：

- **解析**：C++ 一次遍历产出扁平数组（`cad_entity` + 共享点池），Swift 侧零拷贝映射；
  151 图元的施工图载入 ~2 ms，块插入递归展开最多 12 层 / 90 万实体上限。
- **DXF 走 libdxfrw**：LibreDWG 的 DXF 导入器是 O(n²) 的（8000 线 ≈ 3.5 s，5 万线 ≈ 3.5 分钟），
  libdxfrw 是线性的，所以 DXF 先交给它（8000 线 ≈ 66 ms，5 万线 ≈ 400 ms，快 500 倍），
  只有它拒收时才回退到 LibreDWG。两条通路在样例上逐图元完全一致（151/151，坐标相同）。
- **线条与文字走 Metal**：线段在世界空间一次性上传成实例缓冲，顶点着色器把每条线段
  扩张成四边形，片元着色器按到中线的距离做一像素抗锯齿。平移缩放只改一个 uniform。
  - 单位法线在**上传时**预算并塞进结构体原有的 padding（每个线段仍是 48 字节，
    显存零增长）。顶点着色器因此不再需要 `precise::length` + 除法 —— 后者在 Intel
    集显上会退化成 IEEE 精确开方，是这条路径最大的开销（17 ms → 4.5 ms）。
  - 曲线按其屏幕尺寸细分，折线按 0.35 px 容差简化；几何按 log2(scale) 分桶缓存，
    只有相机跨桶才重建。
- **填充与格网走填充层**：`CALayer` 的 `contents` 承载一张世界坐标位图（视口 + 25% 边距），
  平移缩放只是改 `frame`，由合成器在 GPU 上完成。**这是最大的一处浪费**：旧实现
  每帧用 Core Graphics 把这张位图重画进 view 的 backing store，再整块上传，
  实测 26.7 ms/帧，而它内部真正的绘制只有 1.2 ms。世界坐标的参考栅格也画进这张位图，
  于是格网跟着一起免费移动。
- **标注与指针走 overlay 层**：只有含世界坐标内容（标注、测量橡皮筋）时，相机变化才
  触发它重绘。十字光标是两条只改 `frame` 的 1 像素子图层，指针移动不再上传整块
  2560×1600 backing store（旧实现 11.4 ms/帧）。
- **裁剪**：均匀网格空间索引（`SpatialIndex`）做视口剔除与命中测试，O(可见图元) 而非 O(全部图元)。
- **测量**：几何计算全在文档坐标系完成，视图变换只做投影，缩放不损失精度。
- **导出**：走同一渲染器但跳过所有缓存，直接按目标分辨率绘制矢量。

`CGContext` 在这里是**不能**用来画图的：它对 1 设备像素以上的描边会走通用路径
（生成描边轮廓 + 逐顶点求 miter 交点），合成测试里 10 万条线段在 w=1.0 时要 166 ms，
w=1.2 时要 **292 秒**，10 万个小四边形填充要 **287 秒**。Retina 上 `max(px, 0.6) × 2`
保证所有线宽都超过 1 像素，所以这条路径必然踩中。它现在只用于填充、格网、标注和导出。


## 开发工具

`cadtool` 用来在没有界面的情况下核对解析结果：

```bash
./build/cadtool Samples/plan.dxf              # 版本、耗时、实体/图层/空间统计 + 填充明细
./build/cadtool Samples/plan.dxf --layer DOOR # 指定图层的实体与坐标
CADCORE_PROFILE=1 ./build/cadtool x.dxf       # 打印读取各阶段耗时
CADCORE_NO_DXFRW=1 ./build/cadtool x.dxf      # 强制走 LibreDWG，用于两条通路对拍
```

`Tools/make_entities.py` 生成一份覆盖全部实体分支的 DXF（带 bulge 的闭合多段线、实心与
图案填充、MTEXT、旋转文字、带属性的块参照、椭圆、样条、SOLID），用来做解析回归：

```bash
python3 Tools/make_entities.py /tmp/entities.dxf
./build/cadtool /tmp/entities.dxf
CADCORE_NO_DXFRW=1 ./build/cadtool /tmp/entities.dxf
```

界面自检（无需屏幕录制权限，应用自己渲染窗口快照）：

```bash
# 直接运行可执行文件，环境变量才能传进应用（open 走 LaunchServices 会丢掉它们）
CADLENS_SNAPSHOT=/tmp/shot.png CADLENS_SNAPSHOT_EXIT=1 \
  build/CadLens.app/Contents/MacOS/CadLens $PWD/Samples/plan.dxf

CADLENS_DEMO=1                     # 用真实取点流程跑一遍 7 种测量
CADLENS_ZOOM=60 CADLENS_CENTER=11,9  # 固定相机
CADLENS_ZOOM_FACTOR=8              # 在自适应取景之后放大 8 倍
CADLENS_POINTER=600,380            # 固定十字光标位置（视图坐标）
CADLENS_GRID=1 CADLENS_CROSSHAIR=0 # 覆盖这两个开关，不写入用户偏好
CADLENS_EXPORT_PNG=/tmp/a.png CADLENS_EXPORT_PDF=/tmp/a.pdf  # 走导出管线
CADLENS_APPEARANCE=dark            # 强制深色
```

性能基准（脚本化拖拽/缩放，报告每帧的 median / p90，而不是均值 —— 均值会被热降频
和偶发错过垂直同步的帧拉偏）：

```bash
CADLENS_BENCH=1 CADLENS_SNAPSHOT_EXIT=1 \
  build/CadLens.app/Contents/MacOS/CadLens "/path/to/big.dwg"
```

`CADLENS_FRAME_LOG=1` 会额外打印每帧的分段耗时（`[frame]` 几何重建/提交/等 drawable、
`[span]` 画布/overlay、`[gpu]` GPU 时间、`[hatch]` 填充重栅格）。定位"慢在哪"靠它，
而不是靠猜。其余诊断开关：`CADLENS_LAYERS=metal` 只留 GPU 层、`CADLENS_METAL=0`
回退到 Core Graphics 单通道、`CADLENS_NO_SHEET_CACHE=1` 复现旧的全量重绘。

注意这台机器（7 W 双核 + 集显）会热降频，同一份代码连跑可能整轮落在 16.6 ms
（60 Hz 节拍）或 33 ms（合成器降到 30 Hz），差值不是代码问题，判断改动要看分段耗时
而不是端到端数字。


样例图纸可重新生成：

```bash
python3 Tools/make_sample.py                       # Samples/plan.dxf
python3 Tools/make_entities.py                     # Samples/entities.dxf
python3 Tools/make_stress.py 50000 /tmp/s50k.dxf   # 5 万图元压测图
swiftc -O Tools/make_sample_pdf.swift -o /tmp/m && /tmp/m Samples/plan.pdf
./Tools/make_icon.sh                               # Resources/AppIcon.icns
```

## 许可证

本项目以 **GPL-3.0-or-later** 发布，见 [LICENSE](LICENSE)。DWG/DXF 解析依赖
LibreDWG（GPL-3.0-or-later）与 libdxfrw（GPL-2.0-or-later）；分发二进制时请一并遵守
其许可证。字体许可见 [DEPENDENCIES.md](DEPENDENCIES.md)。

## 与 Qt 原版的差异

| 方面 | Qt 原版 | 本版 |
|---|---|---|
| 框架 | Qt 6 Widgets | AppKit（NSWindow/NSToolbar/NSSplitViewController） |
| PDF | PDFium（需自带二进制） | 系统 PDFKit，零额外依赖 |
| 渲染 | 直接绘制 + 缓存位图 | Metal 实例化描边 + 图集文字 + 三层缓存 |
| 分发 | 依赖 Qt 框架包 | 单个 11 MB 可执行文件，无外部框架 |
