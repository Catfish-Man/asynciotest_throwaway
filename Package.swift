// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "demo",
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .executable(
            name: "demo",
            targets: ["demo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-system", branch: "david/ioring"),
        .package(url: "https://github.com/apple/swift-algorithms", from: "1.2.0"),
        // other dependencies
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "demo",
            dependencies: [
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "Algorithms", package: "swift-algorithms"),
            ]),
        .testTarget(
            name: "demoTests",
            dependencies: ["demo"]
        ),
    ]
)
