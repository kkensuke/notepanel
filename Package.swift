// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Notepanel",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "NotepanelCore"),
        .executableTarget(name: "Notepanel", dependencies: ["NotepanelCore"]),
        // Assertion-based checks instead of a test target: XCTest needs Xcode, not just the
        // Command Line Tools. Run with `swift run NotepanelChecks`.
        .executableTarget(name: "NotepanelChecks", dependencies: ["NotepanelCore"]),
    ]
)
