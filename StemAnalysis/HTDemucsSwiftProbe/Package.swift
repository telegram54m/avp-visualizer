// swift-tools-version: 6.0
//
//  HTDemucsSwiftProbe — Phase 0 feasibility probe for the
//  swift-sidecar-port-spec. Single goal: load htdemucs weights into
//  mlx-swift, run the forward pass on a known input, and diff against
//  the Python reference. If parity passes (per-stem RMS < 1e-3),
//  Phases 1-3 of the port are GO.
//
//  Sits outside the High Videlity Xcode project on purpose — failure
//  here costs nothing. Iterate on this package without touching the
//  shipping app.

import PackageDescription

let package = Package(
    name: "HTDemucsSwiftProbe",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HTDemucsSwift", targets: ["HTDemucsSwift"]),
        .executable(name: "htdemucs-probe", targets: ["ProbeCLI"]),
        .executable(name: "swift-backend-smoke", targets: ["SmokeTestCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.31.3"),
        // Sibling probe package — needed for the smoke test which exercises
        // the same FeatureDeriver the High Videlity Swift backend uses.
        .package(path: "../FeatureDeriveSwiftProbe"),
    ],
    targets: [
        .target(
            name: "HTDemucsSwift",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift"),
            ]
        ),
        .executableTarget(
            name: "ProbeCLI",
            dependencies: ["HTDemucsSwift"]
        ),
        .executableTarget(
            name: "SmokeTestCLI",
            dependencies: [
                "HTDemucsSwift",
                .product(name: "FeatureDerive", package: "FeatureDeriveSwiftProbe"),
            ]
        ),
    ]
)
