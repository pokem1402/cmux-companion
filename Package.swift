// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxCompanion",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CmuxCompanionCore", targets: ["CmuxCompanionCore"]),
        .executable(name: "CmuxCompanion", targets: ["CmuxCompanion"]),
        .executable(name: "cmux-set", targets: ["CmuxSetCLI"]),
        .executable(name: "cmux-companion-selftest", targets: ["CmuxCompanionSelfTest"])
    ],
    targets: [
        .target(
            name: "CmuxCompanionCore"
        ),
        .executableTarget(
            name: "CmuxCompanion",
            dependencies: ["CmuxCompanionCore"]
        ),
        .executableTarget(
            name: "CmuxSetCLI",
            dependencies: ["CmuxCompanionCore"]
        ),
        .executableTarget(
            name: "CmuxCompanionSelfTest",
            dependencies: ["CmuxCompanionCore"]
        ),
        .testTarget(
            name: "CmuxCompanionCoreTests",
            dependencies: ["CmuxCompanionCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
