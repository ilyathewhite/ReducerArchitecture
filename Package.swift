// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let package = Package(
    name: "ReducerArchitecture",
    platforms: [
        .macOS(.v10_15), .iOS(.v13), .tvOS(.v13)
    ],
    products: [
        .library(
            name: "ReducerArchitecture",
            targets: ["ReducerArchitecture"]
        )
    ],
    dependencies: [
        .package(name: "CombineEx", url: "https://github.com/RocketLaunchpad/CombineEx.git", .branch("main"))
    ],
    targets: [
        .target(
            name: "ReducerArchitecture",
            dependencies: ["CombineEx"]
        )
    ]
)
