// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Lab421Licensing",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Lab421Licensing", targets: ["Lab421Licensing"]),
    ],
    targets: [
        .target(
            name: "Lab421Licensing",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "Lab421LicensingTests",
            dependencies: ["Lab421Licensing"],
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
