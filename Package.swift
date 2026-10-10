// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CotEditorSurge",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "check-surge", targets: ["CheckSurge"])],
    targets: [
        .executableTarget(name: "CheckSurge"),
        .testTarget(
            name: "CheckSurgeTests", dependencies: ["CheckSurge"], path: "tests/CheckSurgeTests"
        ),
    ]
)
