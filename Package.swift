// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AISwitch",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AISwitch", targets: ["AISwitch"])
    ],
    targets: [
        .executableTarget(
            name: "AISwitch",
            path: "Sources/AISwitch"
        ),
        .testTarget(
            name: "AISwitchTests",
            dependencies: ["AISwitch"],
            path: "Tests/AISwitchTests",
            swiftSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-framework", "Testing",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                ])
            ]
        )
    ]
)
