// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LocalAssist",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "LocalAssistCore", targets: ["LocalAssistCore"]),
        .library(name: "LocalAssistFoundationModels", targets: ["LocalAssistFoundationModels"]),
        .library(name: "LocalAssistAppIntents", targets: ["LocalAssistAppIntents"]),
        .executable(name: "localassist", targets: ["LocalAssistCLI"]),
        .executable(name: "localassist-bench", targets: ["LocalAssistBenchmarks"])
    ],
    targets: [
        .target(name: "LocalAssistCore"),
        .target(
            name: "LocalAssistFoundationModels",
            dependencies: ["LocalAssistCore"]
        ),
        .target(
            name: "LocalAssistAppIntents",
            dependencies: [
                "LocalAssistCore",
                "LocalAssistFoundationModels"
            ]
        ),
        .executableTarget(
            name: "LocalAssistCLI",
            dependencies: [
                "LocalAssistCore",
                "LocalAssistFoundationModels"
            ]
        ),
        .executableTarget(
            name: "LocalAssistBenchmarks",
            dependencies: ["LocalAssistCore"]
        ),
        .testTarget(
            name: "LocalAssistCoreTests",
            dependencies: ["LocalAssistCore"]
        )
    ]
)
