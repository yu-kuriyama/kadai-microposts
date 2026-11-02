// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VideoSaverCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "VideoSaverCore", targets: ["VideoSaverCore"]),
    ],
    targets: [
        .target(name: "VideoSaverCore"),
        .testTarget(
            name: "VideoSaverCoreTests",
            dependencies: ["VideoSaverCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
