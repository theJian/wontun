// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wontun",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Wontun", targets: ["Wontun"])],
    targets: [
        .executableTarget(name: "Wontun"),
        .testTarget(name: "WontunTests", dependencies: ["Wontun"])
    ]
)
