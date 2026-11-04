// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SparseGrid",
    platforms: [
        .iOS("18.0"),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SparseGrid",
            targets: ["SparseGrid"]
        )
    ],
    targets: [
        .target(
            name: "SparseGrid"
        ),
        .testTarget(
            name: "SparseGridTests",
            dependencies: ["SparseGrid"]
        )
    ]
)
