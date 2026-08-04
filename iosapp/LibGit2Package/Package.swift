// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LibGit2",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "LibGit2",
            targets: ["LibGit2"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")
    ],
    targets: [
        .binaryTarget(
            name: "libgit2",
            path: "../libgit2.xcframework"
        ),
        .systemLibrary(
            name: "Clibgit2",
            path: "Sources/Clibgit2"
        ),
        .target(
            name: "LibGit2",
            dependencies: [
                "Clibgit2",
                "libgit2",
                .product(name: "Yams", package: "Yams")
            ],
            cSettings: [
                .headerSearchPath("../../libgit2.xcframework/ios-arm64/Headers"),
                .headerSearchPath("../../libgit2.xcframework/ios-arm64-simulator/Headers")
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("z"),
                .linkedLibrary("iconv")
            ]
        ),
    ]
)

