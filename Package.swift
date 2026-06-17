// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Forel",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ForelCore", targets: ["ForelCore"]),
        .executable(name: "ForelApp", targets: ["ForelApp"]),
    ],
    targets: [
        .target(
            name: "ForelCore",
            dependencies: []
        ),
        .executableTarget(
            name: "ForelApp",
            dependencies: ["ForelCore"],
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
