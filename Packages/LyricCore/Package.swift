// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LyricCore",
    platforms: [.iOS(.v18), .watchOS(.v10), .macOS(.v14)],
    products: [
        .library(name: "LyricCore", targets: ["LyricCore"])
    ],
    targets: [
        .target(name: "LyricCore"),
        .testTarget(name: "LyricCoreTests", dependencies: ["LyricCore"])
    ]
)
