// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Oktopus",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Oktopus",
            path: "Sources/Oktopus",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
