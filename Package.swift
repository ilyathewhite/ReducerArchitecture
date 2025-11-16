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
        )
    ],
    dependencies: [
        .package(url: "https://github.com/ilyathewhite/CombineEx.git", .upToNextMinor(from: "1.0.5")),
        .package(url: "https://github.com/ilyathewhite/AsyncNavigation", .upToNextMinor(from: "1.0.4"))
    ],
    targets: [
        .target(
            name: "ReducerArchitecture",
            dependencies: ["CombineEx", "AsyncNavigation"],
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
            name: "Shared",
            dependencies: ["CombineEx", "ReducerArchitecture"],
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
            name: "NavigationTests",
            dependencies: ["ReducerArchitecture", "Shared"]
        )
    ]
)
