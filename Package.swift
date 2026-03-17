// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "trackpad-area-customizer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "trackpad-area-customizer",
            targets: ["TrackpadAreaCustomizer"]
        )
    ],
    targets: [
        .executableTarget(
            name: "TrackpadAreaCustomizer",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .unsafeFlags([
                    "-F/System/Library/PrivateFrameworks",
                    "-framework",
                    "MultitouchSupport"
                ])
            ]
        )
    ]
)
