// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyOwnTools",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "AIUsageCore", path: "Sources/AIUsageCore"),
        .executableTarget(
            name: "MyOwnTools",
            dependencies: ["AIUsageCore"],
            path: "Sources/MyOwnTool"
        ),
        .executableTarget(
            name: "AIUsageCoreChecks",
            dependencies: ["AIUsageCore"],
            path: "Tests/AIUsageCoreChecks"
        )
    ]
)
