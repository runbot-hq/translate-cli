// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "translate-cli",
    // .v26 is not available in PackageDescription 6.0 (requires 6.2).
    // Runtime availability enforced in TranslationEngine.swift via LanguageAvailability checks.
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "translate-cli", targets: ["TranslateCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "TranslateCLI",
            dependencies: [
                "TranslateCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/TranslateCLI"
        ),
        .target(name: "TranslateCore", path: "Sources/TranslateCore"),
        .testTarget(
            name: "TranslateCoreTests",
            dependencies: ["TranslateCore"],
            path: "Tests/TranslateCoreTests"
        )
    ]
)
