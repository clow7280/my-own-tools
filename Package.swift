// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyOwnTools",
    // 枚举形式的 .v15 要求 swift-tools-version 6.0，这里保持 5.9 并用等价的版本字符串
    platforms: [.macOS("15.0")],
    targets: [
        .target(name: "StatsCore", path: "Sources/StatsCore"),
        .executableTarget(
            name: "MyOwnTools",
            dependencies: ["StatsCore"],
            path: "Sources/MyOwnTool"
        ),
        .executableTarget(
            name: "StatsCoreChecks",
            dependencies: ["StatsCore"],
            path: "Tests/StatsCoreChecks"
        )
    ]
)
