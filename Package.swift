// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Forel",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ForelCore", targets: ["ForelCore"]),
        .executable(name: "ForelApp", targets: ["ForelApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.18"),
        .package(url: "https://github.com/lab421/licensing.git", revision: "1569b2038595862084a466d8dea806b360642608"),
    ],
    targets: [
        .systemLibrary(name: "CArchive"),
        .target(
            name: "ForelCore",
            dependencies: [
                "CArchive",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "Lab421Licensing", package: "licensing"),
            ]
        ),
        .executableTarget(
            name: "ForelApp",
            dependencies: [
                "ForelCore",
                .product(name: "Lab421Licensing", package: "licensing"),
            ],
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "ForelCoreTests",
            dependencies: ["ForelCore"]
        ),
    ]
)
