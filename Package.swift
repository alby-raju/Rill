// swift-tools-version: 6.2.3
import PackageDescription

let package = Package(
    name: "Rill", platforms: [.macOS(.v15)],
    products: [.executable(name: "Rill", targets: ["Rill"])],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", exact: "2.4.4"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", exact: "2.11.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.39.0"),
        .package(url: "https://github.com/swift-server/swift-kafka-client.git", exact: "1.0.0-beta.1"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.16.2")
    ],
    targets: [
        .target(name: "RillCore", dependencies: [.product(name: "Yams", package: "Yams"), .product(name: "ZIPFoundation", package: "ZIPFoundation"), .product(name: "GRPCCore", package: "grpc-swift-2"), .product(name: "GRPCNIOTransportHTTP2TransportServices", package: "grpc-swift-nio-transport"), .product(name: "SwiftProtobuf", package: "swift-protobuf"), .product(name: "Kafka", package: "swift-kafka-client"), .product(name: "Logging", package: "swift-log")]),
        .executableTarget(name: "Rill", dependencies: ["RillCore"], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .target(name: "RillBrokerTestSupport", path: "Tests/BrokerSupport", publicHeadersPath: "include"),
        .testTarget(name: "RillCoreTests", dependencies: ["RillCore", "RillBrokerTestSupport", .product(name: "Kafka", package: "swift-kafka-client"), .product(name: "ZIPFoundation", package: "ZIPFoundation"), .product(name: "SwiftProtobuf", package: "swift-protobuf"), .product(name: "GRPCCore", package: "grpc-swift-2"), .product(name: "GRPCNIOTransportHTTP2TransportServices", package: "grpc-swift-nio-transport")])
    ]
)
