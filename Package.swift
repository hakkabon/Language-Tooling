// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Language-Tooling",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "LanguageTooling", targets: ["LanguageTooling"]),
        .library(
            name: "LanguageToolingFormatting",
            targets: ["LanguageToolingFormatting"]),
        .library(
            name: "LanguageToolingTesting",
            targets: ["LanguageToolingTesting"]),
        .library(
            name: "LanguageExperimentProtocol",
            targets: ["LanguageExperimentProtocol"]),
    ],
    dependencies: [
        .package(path: "../Incremental-Parsing"),
    ],
    targets: [
        .target(
            name: "LanguageTooling",
            dependencies: [
                .product(
                    name: "IncrementalParsing",
                    package: "Incremental-Parsing"),
            ]),
        .target(
            name: "LanguageToolingFormatting",
            dependencies: ["LanguageTooling"]),
        .target(
            name: "LanguageToolingTesting",
            dependencies: ["LanguageTooling"]),
        .target(name: "LanguageExperimentProtocol"),
        .testTarget(
            name: "LanguageToolingTests",
            dependencies: [
                "LanguageTooling",
                "LanguageToolingFormatting",
                "LanguageToolingTesting",
                .product(
                    name: "IncrementalParsing",
                    package: "Incremental-Parsing"),
            ]),
        .testTarget(
            name: "LanguageExperimentProtocolTests",
            dependencies: ["LanguageExperimentProtocol"]),
    ])
