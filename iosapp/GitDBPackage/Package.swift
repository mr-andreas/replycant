// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GitDB",
    platforms: [
        .iOS(.v15),
        .macOS(.v10_15)
    ],
    products: [
        .library(
            name: "GitDB",
            targets: ["GitDB"]
        )
    ],
    dependencies: [
        .package(path: "../LibGit2Package"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")
    ],
    targets: [
        .target(
            name: "GitDB",
            dependencies: [
                .product(name: "LibGit2", package: "LibGit2Package"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Yams", package: "Yams")
            ]
        ),
        .testTarget(
            name: "GitDBTests",
            dependencies: ["GitDB"]
        )
    ]
)
