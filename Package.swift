// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PortKeeper",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PortKeeper", targets: ["PortKeeper"])],
    targets: [
        .executableTarget(name: "PortKeeper")
    ]
)
