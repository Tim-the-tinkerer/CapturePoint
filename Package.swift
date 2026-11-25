// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CapturePoint",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CapturePoint", targets: ["CapturePoint"]),
        .library(name: "CapturePointCore", targets: ["CapturePointCore"]),
    ],
    targets: [
        .target(
            name: "CapturePointCore",
            path: "Sources/CapturePointCore"
        ),
        .executableTarget(
            name: "CapturePoint",
            dependencies: ["CapturePointCore"],
            path: "Sources/CapturePoint"
        ),
        .testTarget(
            name: "CapturePointCoreTests",
            dependencies: ["CapturePointCore"],
            path: "Tests/CapturePointCoreTests"
        ),
    ]
)
