// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HallucinationEngine",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "HallucinationEngine", path: "Sources")
    ]
)
