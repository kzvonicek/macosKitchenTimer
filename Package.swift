// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KitchenTimer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "KitchenTimer",
            path: "Sources/KitchenTimer",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
