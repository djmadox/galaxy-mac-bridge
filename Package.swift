// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MacDroid",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MacDroidCore", targets: ["MacDroidCore"]),
        .executable(name: "MacDroid", targets: ["MacDroidApp"])
    ],
    targets: [
        .target(name: "MacDroidCore"),
        .executableTarget(
            name: "MacDroidApp",
            dependencies: ["MacDroidCore"],
            linkerSettings: [
                .linkedFramework("IOBluetooth")
            ]
        ),
        .testTarget(
            name: "MacDroidCoreTests",
            dependencies: ["MacDroidCore"]
        )
    ]
)
