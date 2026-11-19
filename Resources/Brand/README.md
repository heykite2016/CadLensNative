# 速看CAD · 发布图标备选

> **当前 v3.0.0 发布采用 B「取景框」**：`appicon-b.icns`、`package-b.icns`、`logo-b.png` / `logo-b-light.png`。

共 4 个方向，每个方向提供：

| 类别 | 文件 | 用途 |
|---|---|---|
| 软件 Logo | `logo-a.png` … `logo-d.png` | 深色背景横版组合标（透明底，2400×700） |
| 软件 Logo（浅色底） | `logo-a-light.png` … `logo-d-light.png` | 白/浅色背景横版组合标（透明底） |
| macOS 应用图标 | `appicon-a.png` / `.icns` … `appicon-d` | Dock、启动台、Finder 的 App 图标 |
| 安装包图标 | `package-a.png` / `.icns` … `package-d` | DMG 卷标 / 安装器 / 发布页下载卡片 |
| 总览 | `icon-options.png` | 4 个方向同屏对比 |

所有主图都是 1024×1024 RGBA（图标主体为 macOS 规范 squircle，四周透明）；Logo 为 2400×700 透明 PNG。

## 4 个方向

### A · 蓝图视界 / BLUEPRINT
深蓝图纸底 + 白色平面 + 绿色尺寸线。最接近现有版本的品牌延续，稳、专业，适合作为**默认主图标**。
- 适合：官网、安装器、正式版 Dock
- 识别点：平面图 + 尺寸双箭头

### B · 取景框 / FOCUS FRAME
近黑底 + 四角取景框 + 中央平面和绿色尺寸线。小尺寸下轮廓最强，最像“看图/取景”工具。
- 适合：Dock 小图标、菜单栏、社媒头像
- 识别点：四角括号 + 绿色量线

### C · 量角弧 / PRECISION ARC
米白图纸底 + 深蓝角尺 + 绿色四分之一圆弧。最“制图/测量”，在浅色背景和印刷物料里辨识度最好。
- 适合：浅色宣传页、帮助文档、打印物料
- 识别点：L 形角尺 + 圆心/半径弧

### D · 层叠图纸 / SHEET STACK
深青底 + 三张错开图纸 + 前图纸尺寸线。强调“多图/布局/整套图纸”，适合 PDF、多文档工作流。
- 适合：多图版宣传、安装包、更新日志头图
- 识别点：层叠纸 + 薄荷绿量线

## 推荐组合

- **主 App 图标**：A（品牌延续）或 B（小尺寸最醒目）
- **安装包 / DMG**：与主 App 同方向，保持家族一致
- **浅色宣传物料**：C 的 `logo-c-light.png`
- **多图/PDF 场景**：D

## 启用方式

```bash
# 以 A 方案为例；换成 b/c/d 即可
cp Resources/Brand/appicon-a.icns Resources/AppIcon.icns
cp Resources/Brand/appicon-a.png  Resources/AppIcon-1024.png

# DMG 卷标 / 安装器图标（在打包脚本里指定）
cp Resources/Brand/package-a.icns /path/to/volume.icns

# 官网/发布页使用
# 深色底：logo-a.png；浅色底：logo-a-light.png
```

重新生成：

```bash
# 需要 Pillow；脚本会同时重生成 PNG 和 .icns
python3 Tools/make_brand_icons.py
python3 Tools/make_brand_sheet.py
```

> `package-*.icns` 是 1024 主图生成的完整 iconset；如果发布系统只接受 PNG，直接用 `package-*.png`。
