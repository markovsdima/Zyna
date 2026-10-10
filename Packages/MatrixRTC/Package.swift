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
            url: "https://github.com/markovsdima/client-sdk-swift.git",
            exact: "2.15.0-zyna.2"
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
        .testTarget(
            name: "MatrixRTCLiveKitTests",
            dependencies: [
                "MatrixRTC",
                "MatrixRTCLiveKit",
            ]
        ),
    ]
)
