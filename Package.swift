// swift-tools-version: 5.9
import PackageDescription

// The build script packages this executable with its icons and app metadata.
let package = Package(
    name: "NotchNotify",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NotchNotify", targets: ["NotchNotify"])],
    targets: [
        // All app logic lives here so tests can @testable import it.
        .target(
            name: "NotchNotifyCore",
            path: "Sources/NotchNotifyCore"
        ),
        .executableTarget(
            name: "NotchNotify",
            dependencies: ["NotchNotifyCore"],
            path: "Sources/NotchNotify"
        ),
        .testTarget(
            name: "NotchNotifyTests",
            dependencies: ["NotchNotifyCore"],
            path: "Tests/NotchNotifyTests"
        ),
    ]
)
