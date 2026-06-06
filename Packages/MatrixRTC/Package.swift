// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MatrixRTC",
    platforms: [
        .iOS(.v16),
        .macOS(.v10_15)
    ],
    products: [
        .library(
            name: "MatrixRTC",
            targets: ["MatrixRTC"]
        ),
        .library(
            name: "MatrixRTCLiveKit",
            targets: ["MatrixRTCLiveKit"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/livekit/client-sdk-swift.git",
            from: "2.14.1"
        ),
    ],
    targets: [
        .target(
            name: "MatrixRTC"
        ),
        .target(
            name: "MatrixRTCLiveKit",
            dependencies: [
                "MatrixRTC",
                .product(name: "LiveKit", package: "client-sdk-swift"),
            ]
        ),
        .testTarget(
            name: "MatrixRTCTests",
            dependencies: ["MatrixRTC"]
        ),
    ]
)
