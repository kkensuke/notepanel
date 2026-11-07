// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Notepanel",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "NotepanelCore"),
        .executableTarget(name: "Notepanel", dependencies: ["NotepanelCore"]),
        .testTarget(name: "NotepanelCoreTests", dependencies: ["NotepanelCore"]),
    ]
)
