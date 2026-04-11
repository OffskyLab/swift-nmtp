// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "swift-nmtp",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NMTP", targets: ["NMTP"]),
        .library(name: "NMTPWebSocket", targets: ["NMTPWebSocket"]),
        .library(name: "NMTPeer", targets: ["NMTPeer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.40.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.10.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "NMTP", dependencies: [
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOExtras", package: "swift-nio-extras"),
            .product(name: "Logging", package: "swift-log"),
        ]),
        .target(name: "NMTPWebSocket", dependencies: [
            "NMTP",
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
        ]),
        .target(name: "NMTPeer", dependencies: [
            "NMTP",
            .product(name: "NIO", package: "swift-nio"),
        ]),
        .testTarget(name: "NMTPTests", dependencies: [
            "NMTP",
            .product(name: "NIO", package: "swift-nio"),
        ]),
        .testTarget(name: "NMTPWebSocketTests", dependencies: [
            "NMTPWebSocket",
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
        ]),
        .testTarget(name: "NMTPeerTests", dependencies: [
            "NMTPeer",
            "NMTP",
            .product(name: "NIO", package: "swift-nio"),
        ]),
    ]
)
