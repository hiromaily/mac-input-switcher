// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "mac-input-switcher",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "InputSwitcherCore"),
        .executableTarget(name: "mac-input-switcher", dependencies: ["InputSwitcherCore"]),
        .testTarget(name: "InputSwitcherCoreTests", dependencies: ["InputSwitcherCore"]),
    ]
)
