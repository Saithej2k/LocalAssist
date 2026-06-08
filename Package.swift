// swift-tools-version: 6.2

import PackageDescription

let developerFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let developerLibraries = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

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
        .executable(name: "localassist-bench", targets: ["LocalAssistBenchmarks"]),
        .executable(name: "localassist-selftest", targets: ["LocalAssistSelfTests"])
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
        .executableTarget(
            name: "LocalAssistSelfTests",
            dependencies: ["LocalAssistCore"]
        ),
        .testTarget(
            name: "LocalAssistCoreTests",
            dependencies: ["LocalAssistCore"],
            swiftSettings: [
                .unsafeFlags([
                    "-F", developerFrameworks
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", developerFrameworks,
                    "-Xlinker", "-rpath",
                    "-Xlinker", developerFrameworks,
                    "-Xlinker", "-rpath",
                    "-Xlinker", developerLibraries
                ])
            ]
        )
    ]
)
