// swift-tools-version:5.7
import PackageDescription
import Foundation

let libshare = ProcessInfo.processInfo.environment["LIBSHARE"]
    ?? "\(ProcessInfo.processInfo.environment["HOME"] ?? "/tmp")/Documents/libshare"

let package = Package(
    name: "CadLens",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "CadLens", targets: ["CadLens"]),
        .executable(name: "cadtool", targets: ["cadtool"]),
    ],
    targets: [
        .target(
            name: "CadCore",
            path: "Sources/CadCore",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-I\(libshare)/include/libredwg", "-O2"]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(libshare)/lib",
                    "-lredwg", "-ldxfrw", "-lc++",
                ]),
            ]
        ),
        .executableTarget(
            name: "cadtool",
            dependencies: ["CadCore"],
            path: "Sources/cadtool"
        ),
        .executableTarget(
            name: "CadLens",
            dependencies: ["CadCore"],
            path: "Sources/CadLens",
            swiftSettings: [
                .unsafeFlags(["-Ounchecked"], .when(configuration: .release)),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("PDFKit"),
                .linkedFramework("CoreText"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
