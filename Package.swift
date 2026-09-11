// swift-tools-version: 5.10

import PackageDescription
import Foundation

let isCommandLineToolsTesting = ProcessInfo.processInfo.environment["V2S_CLT_TESTING"] == "1"
let v2sExcludedResources = isCommandLineToolsTesting
    ? ["Resources/SileroVAD.mlpackage"]
    : []
let v2sResources: [Resource] = [
    .copy("Resources/AppIcon/AppIcon-512.png"),
] + (isCommandLineToolsTesting ? [] : [
    .copy("Resources/SileroVAD.mlpackage"),
])
let v2sSwiftSettings: [SwiftSetting] = isCommandLineToolsTesting
    ? [.define("V2S_CLT_TESTING")]
    : []

let package = Package(
    name: "v2s",
    platforms: [
        .macOS("15.0"),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "v2s",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/V2SApp",
            exclude: v2sExcludedResources,
            resources: v2sResources,
            swiftSettings: v2sSwiftSettings
        ),
        .testTarget(
            name: "v2sTests",
            dependencies: ["v2s"],
            path: "Tests/V2STests"
        ),
    ]
)
