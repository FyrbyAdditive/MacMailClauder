// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacMailClauder",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MacMailClauderMCP", targets: ["MacMailClauderMCP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.7.1"),
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "Shared",
            dependencies: [],
            path: "Sources/Shared"
        ),
        .executableTarget(
            name: "MacMailClauderMCP",
            dependencies: [
                "Shared",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "SQLite", package: "SQLite.swift"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            path: "Sources/MacMailClauderMCP"
        ),
    ]
)
