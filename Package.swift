// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "beckon",
    platforms: [.macOS(.v14)],
    targets: [
        // Shared by the CLI and the app. Darwin only, so the CLI stays Foundation-free.
        .target(name: "BeckonCore"),
        // The hook binary Claude Code runs on every event: must start in a few milliseconds.
        .executableTarget(name: "beckon", dependencies: ["BeckonCore"]),
        // The menu-bar agent that owns the socket and the panel.
        .executableTarget(name: "BeckonApp", dependencies: ["BeckonCore"]),
        .testTarget(name: "BeckonAppTests", dependencies: ["BeckonApp", "BeckonCore"]),
    ],
    swiftLanguageModes: [.v5]
)
