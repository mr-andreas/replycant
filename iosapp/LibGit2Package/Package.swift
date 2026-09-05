// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LibGit2",
    platforms: [
        // Raised from 15 by the vendored TailscaleKit, whose framework declares
        // a minimum of 18.1. The app already targets 18.5, so this only makes
        // the package's declared floor match what actually ships. Spelled as a
        // string because `.v18` needs swift-tools-version 6.0, and bumping that
        // would also switch every target to Swift 6 language mode.
        .iOS("18.0")
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
        // Built from a pinned libtailscale commit by `make ios-tailscalekit`
        // rather than committed, because the xcframework is 70 MB and this
        // repository's history is public and permanent.
        .binaryTarget(
            name: "TailscaleKit",
            path: "../TailscaleKit.xcframework"
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
                "TailscaleKit",
                .product(name: "Yams", package: "Yams")
            ],
            cSettings: [
                .headerSearchPath("../../libgit2.xcframework/ios-arm64/Headers"),
                .headerSearchPath("../../libgit2.xcframework/ios-arm64-simulator/Headers")
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Network"),
                .linkedLibrary("z"),
                .linkedLibrary("iconv")
            ]
        ),
    ]
)

