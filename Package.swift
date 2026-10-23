// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Rill", platforms: [.macOS(.v14)], products: [.executable(name: "Rill", targets: ["Rill"])], targets: [.target(name: "RillCore"), .executableTarget(name: "Rill", dependencies: ["RillCore"]), .testTarget(name: "RillCoreTests", dependencies: ["RillCore"])])
