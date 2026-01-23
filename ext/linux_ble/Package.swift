// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "RBLELinuxHelper",
    platforms: [
        .macOS(.v10_15)  // For development on macOS; production runs on Linux
    ],
    products: [
        .executable(name: "RBLELinuxHelper", targets: ["RBLELinuxHelper"])
    ],
    dependencies: [
        // BluetoothLinux - direct HCI access bypassing D-Bus
        // Using master branch as stable releases have dependency resolution issues with Swift 6
        .package(url: "https://github.com/PureSwift/BluetoothLinux.git", branch: "master"),
        // GATT - Generic Attribute Profile implementation
        .package(url: "https://github.com/PureSwift/GATT.git", branch: "master")
    ],
    targets: [
        .executableTarget(
            name: "RBLELinuxHelper",
            dependencies: [
                .product(name: "BluetoothLinux", package: "BluetoothLinux", condition: .when(platforms: [.linux])),
                .product(name: "GATT", package: "GATT", condition: .when(platforms: [.linux]))
            ],
            path: "Sources/RBLELinuxHelper"
        )
    ]
)
