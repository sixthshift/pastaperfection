// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PastaPerfection",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "PastaPerfectionCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "pastaperfectiond",
            dependencies: ["PastaPerfectionCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "PastaPerfection",
            dependencies: ["PastaPerfectionCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "pastaperfection-cli",
            dependencies: ["PastaPerfectionCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PastaPerfectionCoreTests",
            dependencies: ["PastaPerfectionCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
