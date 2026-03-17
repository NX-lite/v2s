// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "v2s",
    platforms: [
        .macOS("15.0"),
    ],
    targets: [
        .executableTarget(
            name: "V2SApp",
            path: "Sources/V2SApp"
        ),
    ]
)
