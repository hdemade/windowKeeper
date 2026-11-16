// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WindowKeeper",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "WindowKeeper", path: "Sources/WindowKeeper")
    ]
)
