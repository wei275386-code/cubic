// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CubicCore",
    platforms: [.iOS("26.0"), .macOS(.v14)],
    products: [.library(name: "CubicCore", targets: ["CubicCore"])],
    targets: [
        .systemLibrary(name: "CSQLite3", pkgConfig: "sqlite3"),
        .target(name: "CubicCore", dependencies: ["CSQLite3"]),
        .testTarget(name: "CubicCoreTests", dependencies: ["CubicCore", "CSQLite3"])
    ]
)
