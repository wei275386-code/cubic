// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CubicCore",
    platforms: [.iOS("26.0"), .macOS(.v14)],
    products: [.library(name: "CubicCore", targets: ["CubicCore"])],
    targets: [
        .target(name: "CubicCore"),
        .testTarget(name: "CubicCoreTests", dependencies: ["CubicCore"])
    ]
)
