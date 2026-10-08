// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "KeyChord",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KeyChordCore", targets: ["KeyChordCore"]),
        .executable(name: "KeyChord", targets: ["KeyChord"]),
    ],
    targets: [
        // Platform-independent chord engine, event router, loader, and probe model.
        // Uses only the Swift standard library (no Foundation, no macOS frameworks).
        .target(name: "KeyChordCore"),
        // Thin macOS platform layer (event tap, output synthesis, menu-bar UI).
        .executableTarget(
            name: "KeyChord",
            dependencies: ["KeyChordCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("WebKit"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        .testTarget(name: "KeyChordCoreTests", dependencies: ["KeyChordCore"]),
    ]
)
