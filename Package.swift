// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ampere",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "AmpereCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ampered",
            dependencies: ["AmpereCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Ampere",
            dependencies: ["AmpereCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ampere-cli",
            dependencies: ["AmpereCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AmpereCoreTests",
            dependencies: ["AmpereCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
