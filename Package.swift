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
        .target(
            name: "ForelCore",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
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
            dependencies: ["ForelCore"],
            // Command Line Tools (no full Xcode) ship Testing.framework outside the
            // default search path; point the compiler/linker at it explicitly.
            swiftSettings: [
                .unsafeFlags(["-F/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ])
            ]
        ),
    ]
)
