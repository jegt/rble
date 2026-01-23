// swift-tools-version: 5.9
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
        .package(url: "https://github.com/PureSwift/BluetoothLinux.git", from: "5.0.0"),
        // GATT - Generic Attribute Profile implementation
        .package(url: "https://github.com/PureSwift/GATT.git", from: "3.3.0")
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
