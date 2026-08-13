// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "omp-companion",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "omp-companion", targets: ["omp-companion"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0")
    ],
    targets: [
        .executableTarget(
            name: "omp-companion",
            dependencies: [
                .product(name: "Yams", package: "Yams")
            ],
            path: "Sources/omp-companion"
        ),

    ]
)
