// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let package = Package(
    name: "ReducerArchitecture",
    platforms: [
        .macOS("13.0"), .iOS("16.0"), .tvOS(.v14)
    ],
    products: [
        .library(
            name: "ReducerArchitecture",
            targets: ["ReducerArchitecture"]
        ),
        .library(
            name: "TestSupport",
            targets: ["TestSupport"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/ilyathewhite/FoundationEx.git", .exact("1.0.15")),
        .package(url: "https://github.com/ilyathewhite/CombineEx.git", .exact("1.0.5")),
        .package(url: "https://github.com/ilyathewhite/AsyncNavigation.git", .exact("1.0.13")),
        .package(url: "https://github.com/pointfreeco/swift-tagged.git", .exact("0.10.0")),
        .package(url: "https://github.com/ilyathewhite/GraphStorage.git", .exact("1.0.0"))
    ],
    targets: [
        .target(
            name: "ReducerArchitecture",
            dependencies: [
                "FoundationEx",
                "CombineEx",
                "AsyncNavigation",
                .product(name: "Tagged", package: "swift-tagged"),
                "GraphStorage"
            ],
            swiftSettings: [
//                .unsafeFlags([
//                    "-Xfrontend",
//                    "-warn-long-function-bodies=100",
//                    "-Xfrontend",
//                    "-warn-long-expression-type-checking=100"
//                ])
            ]
        ),
        .target(
            name: "TestSupport",
            dependencies: ["FoundationEx", "CombineEx", "ReducerArchitecture"],
            path: "Tests/TestSupport",
            swiftSettings: [
//                .unsafeFlags([
//                    "-Xfrontend",
//                    "-warn-long-function-bodies=100",
//                    "-Xfrontend",
//                    "-warn-long-expression-type-checking=100"
//                ])
            ]
        ),
        .testTarget(
            name: "ReducerArchitectureTests",
            dependencies: ["ReducerArchitecture", "TestSupport"],
            path: "Tests",
            exclude: ["TestApp", "TestSupport", ".DS_Store"]
        )
    ]
)
