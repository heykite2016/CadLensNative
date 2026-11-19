# 第三方依赖

速看CAD 的图形解析依赖两个 GPL 兼容的原生库。它们不随源码仓库分发，需要按下面的目录约定自行编译。

```
$LIBSHARE/
├── include/
│   ├── libredwg/*.h
│   └── libdxfrw/*.h
└── lib/
    ├── libredwg.a
    └── libdxfrw.a
```

## LibreDWG 0.13.x（GPL-3.0-or-later）

- 上游：https://github.com/LibreDWG/libredwg
- 用途：DWG R13–R2018 主解析；DXF 在 libdxfrw 拒收时的兼容兜底。
- **必须启用写/DXF 读入支持**（否则 `dxf_read_file` 不会编进静态库）：
  - CMake 构建时打开 `USE_WRITE=ON`，并生成静态库。
  - 安装到 `$LIBSHARE`，确保 `include/libredwg` 与 `lib/libredwg.a` 存在。

## libdxfrw 1.1.x（GPL-2.0-or-later）

- 上游：https://github.com/LibreCAD/libdxfrw
- 用途：DXF 的线性主解析通路。
- 以静态库安装到 `$LIBSHARE/lib/libdxfrw.a`，头文件在 `$LIBSHARE/include`。

## 构建

```bash
export LIBSHARE=/path/to/libshare
./build.sh          # build/CadLens.app
./build.sh tool     # 额外生成 build/cadtool
```

链接参数已包含 `-liconv`（macOS 上 LibreDWG 的隐式依赖）。如果依赖库是较新的 macOS SDK 构建的，链接低版本 target 时出现 `was built for newer macOS version` 警告是正常的。

## 运行时与字体

- macOS 12 或更新版本。
- `Resources/fonts/NotoSansCJKsc-Regular.otf`（SIL Open Font License）用于中文 CAD 文字。
- `Resources/fonts/osifont-lgpl3fe.ttf`（LGPL）用于拉丁文字。
