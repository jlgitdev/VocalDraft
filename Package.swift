// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "VocalDraft",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "VocalDraft", targets: ["VocalDraft"])
    ],
    targets: [
        .executableTarget(
            name: "VocalDraft",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "VocalDraftTests",
            dependencies: ["VocalDraft"]
        )
    ]
)
