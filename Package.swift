// swift-tools-version: 5.8

import PackageDescription

let package = Package(
    name: "SwiftNIO-AsyncAwait-Example",
    platforms: [ .macOS(.v13) ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", .upToNextMajor(from: "2.0.0")),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", .upToNextMajor(from: "2.0.0")),
    ],
    targets: [
        .executableTarget(
            name: "SwiftNIO-AsyncAwait-Example",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            path: "Sources"),
    ]
)

// EOF
