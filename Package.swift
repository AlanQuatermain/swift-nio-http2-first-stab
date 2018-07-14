// swift-tools-version:4.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-nio-http2",
    products: [
        .executable(name: "NIOHTTP2Server", targets: ["NIOHTTP2Server"]),
        .library(name: "NIOHPACK", targets: ["NIOHPACK"]),
        .library(name: "NIOHTTP2", targets: ["NIOHTTP2"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-nio-nghttp2-support.git", from: "1.0.0"),
    ],
    targets: [
        .target(name: "CNIONghttp2"),
        .target(name: "NIOHTTP2Server", dependencies: ["NIOHTTP2"]),
        .target(name: "NIOHPACK", dependencies: ["NIO", "NIOConcurrencyHelpers"]),
        .target(name: "NIOHTTP2", dependencies: ["NIO", "NIOHTTP1", "NIOTLS", "CNIONghttp2"]),
        
        .testTarget(name: "NIOHPACKTests", dependencies: ["NIOHPACK"]),
        .testTarget(name: "NIOHTTP2Tests", dependencies: ["NIO", "NIOHTTP1", "NIOHTTP2"]),
    ]
)
