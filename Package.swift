// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TranscriptionPill",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TranscriptionPill", targets: ["TranscriptionPill"])
    ],
    targets: [
        .executableTarget(
            name: "TranscriptionPill",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "TranscriptionPillTests",
            dependencies: ["TranscriptionPill"]
        )
    ]
)
