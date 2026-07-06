// swift-tools-version: 6.2

import PackageDescription

let developerFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let developerLibraries = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

let package = Package(
    name: "LocalAssist",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        .library(name: "LocalAssistCore", targets: ["LocalAssistCore"]),
        .library(name: "LocalAssistFoundationModels", targets: ["LocalAssistFoundationModels"]),
        .library(name: "LocalAssistSystemTools", targets: ["LocalAssistSystemTools"]),
        .library(name: "LocalAssistAppIntents", targets: ["LocalAssistAppIntents"]),
        .library(name: "LocalAssistAppUI", targets: ["LocalAssistAppUI"]),
        .executable(name: "localassist", targets: ["LocalAssistCLI"]),
        .executable(name: "localassist-bench", targets: ["LocalAssistBenchmarks"]),
        .executable(name: "localassist-selftest", targets: ["LocalAssistSelfTests"]),
        .executable(name: "localassist-eval", targets: ["LocalAssistEvals"])
    ],
    targets: [
        .target(name: "LocalAssistCore"),
        .target(
            name: "LocalAssistFoundationModels",
            dependencies: ["LocalAssistCore"]
        ),
        .target(
            name: "LocalAssistSystemTools",
            dependencies: ["LocalAssistCore"]
        ),
        .target(
            name: "LocalAssistAppIntents",
            dependencies: [
                "LocalAssistCore",
                "LocalAssistFoundationModels",
                "LocalAssistSystemTools"
            ]
        ),
        .target(
            name: "LocalAssistAppUI",
            dependencies: [
                "LocalAssistCore",
                "LocalAssistFoundationModels",
                "LocalAssistSystemTools"
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
            dependencies: ["LocalAssistCore", "LocalAssistEvalKit", "LocalAssistSystemTools"]
        ),
        .target(
            name: "LocalAssistEvalKit",
            dependencies: ["LocalAssistCore"]
        ),
        .executableTarget(
            name: "LocalAssistEvals",
            dependencies: [
                "LocalAssistCore",
                "LocalAssistEvalKit",
                "LocalAssistFoundationModels"
            ]
        ),
        .testTarget(
            name: "LocalAssistCoreTests",
            dependencies: [
                "LocalAssistCore",
                "LocalAssistEvalKit",
                "LocalAssistSystemTools",
                "LocalAssistAppUI"
            ],
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
