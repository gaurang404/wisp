// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Wisp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Wisp", path: "Sources/Wisp"),
        .testTarget(name: "WispTests", dependencies: ["Wisp"], path: "Tests/WispTests")
    ]
)
