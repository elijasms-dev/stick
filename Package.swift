// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Stick",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Stick", targets: ["Stick"])],
    targets: [
        .target(name: "StickCore"),
        .executableTarget(name: "Stick", dependencies: ["StickCore"], linkerSettings: [.linkedFramework("Carbon")]),
        .testTarget(name: "StickCoreTests", dependencies: ["StickCore"]),
        .testTarget(name: "StickTests", dependencies: ["Stick"])
    ]
)
