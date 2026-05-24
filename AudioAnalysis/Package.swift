// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioAnalysis",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "AudioAnalysis", targets: ["AudioAnalysis"]),
    ],
    targets: [
        .target(name: "AudioAnalysis"),
        .executableTarget(name: "visualize", dependencies: ["AudioAnalysis"]),
        .testTarget(name: "AudioAnalysisTests", dependencies: ["AudioAnalysis"]),
    ]
)
