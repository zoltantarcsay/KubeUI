// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KubeKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "KubeKit", targets: ["KubeKit"]),
    ],
    targets: [
        .target(name: "KubeKit"),
        .testTarget(name: "KubeKitTests", dependencies: ["KubeKit"]),
    ]
)
