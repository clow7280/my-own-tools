// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyOwnTool",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "MyOwnTool", path: "Sources/MyOwnTool")
    ]
)
