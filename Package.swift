// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Forel",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ForelCore", targets: ["ForelCore"]),
        .executable(name: "ForelApp", targets: ["ForelApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.18"),
    ],
    targets: [
        .target(
            name: "ForelCore",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .executableTarget(
            name: "ForelApp",
            dependencies: ["ForelCore"],
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "ForelCoreTests",
            dependencies: ["ForelCore"]
        ),
    ]
)
