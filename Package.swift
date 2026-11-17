// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MXNoti",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MXNoti", targets: ["MXNoti"])],
    targets: [
        .target(name: "MXNotiCore"),
        .executableTarget(name: "MXNoti", dependencies: ["MXNotiCore"]),
        .testTarget(name: "MXNotiCoreTests", dependencies: ["MXNotiCore"])
    ]
)
