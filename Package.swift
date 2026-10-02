// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Satellite",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Satellite", path: "Sources/Satellite"),
    ]
)
