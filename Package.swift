// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Rill", platforms: [.macOS(.v14)],
    products: [.executable(name: "Rill", targets: ["Rill"])],
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2")],
    targets: [
        .target(name: "RillCore", dependencies: [.product(name: "Yams", package: "Yams")]),
        .executableTarget(name: "Rill", dependencies: ["RillCore"]),
        .testTarget(name: "RillCoreTests", dependencies: ["RillCore"])
    ]
)
