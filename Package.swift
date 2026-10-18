// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Wisp",
    platforms: [.macOS(.v14)],
    dependencies: [
        // In-app updates. The only third-party dependency; keep it that way.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Wisp",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Wisp"
        ),
        .testTarget(name: "WispTests", dependencies: ["Wisp"], path: "Tests/WispTests")
    ]
)
