// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Rill", platforms: [.macOS(.v14)],
    products: [.executable(name: "Rill", targets: ["Rill"])],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
    ],
    targets: [
        .target(name: "RillCore", dependencies: [.product(name: "Yams", package: "Yams"), .product(name: "ZIPFoundation", package: "ZIPFoundation")]),
        .executableTarget(name: "Rill", dependencies: ["RillCore"]),
        .testTarget(name: "RillCoreTests", dependencies: ["RillCore", .product(name: "ZIPFoundation", package: "ZIPFoundation")])
    ]
)
