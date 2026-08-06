// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PLayout",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PLayout", path: "Sources/PLayout"),
        .testTarget(name: "PLayoutTests", dependencies: ["PLayout"], path: "Tests/PLayoutTests"),
    ]
)
