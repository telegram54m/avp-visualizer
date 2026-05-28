// swift-tools-version: 6.0
//
//  Package.swift — Swift client for the demucs-mlx Python sidecar.
//
//  Sits outside the High Videlity Xcode project so we can iterate on
//  the IPC + decoding without touching the app build. When the
//  integration is ready, we'll either add this as a local SPM dep on
//  High Videlity.xcodeproj or copy StemFeatureProvider.swift into the
//  app's source folder.

import PackageDescription

let package = Package(
    name: "StemSidecarClient",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StemSidecarClient", targets: ["StemSidecarClient"]),
        .library(name: "MusicAppNowPlaying", targets: ["MusicAppNowPlaying"]),
        .executable(name: "stem-sidecar-test", targets: ["CLITest"]),
    ],
    targets: [
        .target(name: "StemSidecarClient"),
        // macOS-only: queries Music.app via NSAppleScript for the
        // currently-playing track's local file URL + metadata.
        // Intentionally separate from StemSidecarClient so the sidecar
        // bridge can stay decoupled from any specific audio source.
        .target(name: "MusicAppNowPlaying"),
        .executableTarget(
            name: "CLITest",
            dependencies: ["StemSidecarClient", "MusicAppNowPlaying"]
        ),
    ]
)
