// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftHakchi",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/tsolomko/SWCompression.git", from: "4.8.0"),
    ],
    targets: [
        .target(
            name: "USBBridge",
            path: "USBBridge",
            sources: ["src"],
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .executableTarget(
            name: "SwiftHakchi",
            dependencies: [
                "USBBridge",
                .product(name: "SWCompression", package: "SWCompression"),
            ],
            path: "SwiftHakchi",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
    ]
)
