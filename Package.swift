// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Satellite",
    platforms: [.macOS(.v14)],
    dependencies: [
        // The terminal emulator behind terminal panes (MIT). Pinned to an exact version, so it only changes when
        // this line does; see THIRD_PARTY_NOTICES.md.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.1"),
    ],
    targets: [
        .executableTarget(
            name: "Satellite",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/Satellite"),
    ]
)
