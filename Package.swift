// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "QuickPi",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "QuickPi", targets: ["QuickPi"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/gonzalezreal/swift-markdown-ui.git",
            exact: "2.4.1"
        ),
    ],
    targets: [
        .binaryTarget(
            name: "Sparkle",
            url: "https://github.com/sparkle-project/Sparkle/releases/download/2.9.4/Sparkle-for-Swift-Package-Manager.zip",
            checksum: "cb6fdbdc8884f15d62a616e79face92b08322410fd2d425edc6596ccbf4ba3b0"
        ),
        .executableTarget(
            name: "QuickPi",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                "Sparkle",
            ],
            path: "Sources/QuickPi",
            resources: [
                .copy("Resources/ProviderIcons"),
            ]
        ),
        .testTarget(
            name: "QuickPiTests",
            dependencies: [
                "QuickPi",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            path: "Tests/QuickPiTests"
        ),
    ]
)
