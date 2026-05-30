// swift-tools-version: 6.0
//
//  FeatureDeriveSwiftProbe — Phase 1 of swift-sidecar-port-spec.
//
//  Ports `derive_features` from sidecar.py (librosa-based) to Swift
//  using Accelerate / vDSP. Stays fully independent of mlx-swift so it
//  can land on its own — the bundle-size win starts here even before
//  Phase 2 swaps the model side.
//
//  Targets:
//    FeatureDerive — library: STFT + chromagram + RMS + onset
//    feature-probe — executable: parity test vs librosa reference

import PackageDescription

let package = Package(
    name: "FeatureDeriveSwiftProbe",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FeatureDerive", targets: ["FeatureDerive"]),
        .executable(name: "feature-probe", targets: ["FeatureProbeCLI"]),
    ],
    targets: [
        .target(name: "FeatureDerive"),
        .executableTarget(
            name: "FeatureProbeCLI",
            dependencies: ["FeatureDerive"]
        ),
    ]
)
