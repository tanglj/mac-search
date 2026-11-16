// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacSearch",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MacSearchCore", targets: ["MacSearchCore"]),
        .executable(name: "mac-search", targets: ["MacSearchCLI"]),
        .executable(name: "MacSearchDesktop", targets: ["MacSearchDesktop"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "MacSearchCore", dependencies: ["CSQLite"]),
        .target(name: "MacSearchDesktopKit", dependencies: ["MacSearchCore"]),
        .executableTarget(name: "MacSearchDesktop", dependencies: ["MacSearchCore", "MacSearchDesktopKit"]),
        .executableTarget(name: "MacSearchCLI", dependencies: ["MacSearchCore"]),
        .testTarget(name: "MacSearchCoreTests", dependencies: ["MacSearchCore"]),
        .testTarget(name: "MacSearchDesktopKitTests", dependencies: ["MacSearchCore", "MacSearchDesktopKit"]),
        .testTarget(name: "MacSearchDesktopTests", dependencies: ["MacSearchDesktop", "MacSearchCore", "MacSearchDesktopKit"])
    ]
)
