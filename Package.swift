// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftHDR",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SwiftHDR", targets: ["SwiftHDR"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "5ee435b15ad40ec1f644b5eb9d247f263ccd2170"
        )
    ],
    targets: [
        .executableTarget(
            name: "SwiftHDR",
            path: "Sources/SwiftHDR"
        ),
        .testTarget(
            name: "SwiftHDRTests",
            dependencies: [
                "SwiftHDR",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/SwiftHDRTests"
        )
    ]
)
