// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyOwnTools",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "MyOwnTools", path: "Sources/MyOwnTool")
    ]
)
