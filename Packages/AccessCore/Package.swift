// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AccessCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "AccessCore", targets: ["AccessCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "AccessCore",
            dependencies: [.product(name: "HeapModule", package: "swift-collections")],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "AccessCoreTests", dependencies: ["AccessCore"]),
    ],
    swiftLanguageModes: [.v5]
)
