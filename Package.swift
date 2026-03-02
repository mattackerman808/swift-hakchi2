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
            name: "MbedCrypto",
            path: "vendor/mbedtls",
            sources: ["library/"],
            publicHeadersPath: "include",
            cSettings: [
                .define("MBEDTLS_CONFIG_FILE", to: "\"mbedtls/mbedtls_config.h\""),
            ]
        ),
        .target(
            name: "LibSSH2",
            dependencies: ["MbedCrypto"],
            path: "vendor/libssh2",
            sources: ["src/"],
            publicHeadersPath: "include",
            cSettings: [
                .define("LIBSSH2_MBEDTLS"),
                .define("HAVE_CONFIG_H"),
                .headerSearchPath("src"),
            ]
        ),
        .target(
            name: "USBBridge",
            dependencies: ["LibSSH2"],
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
            resources: [
                .copy("Resources/fes1.bin"),
                .copy("Resources/basehmods.tar"),
                .copy("Resources/hakchi.hmod"),
                .copy("Resources/snescarts.xml"),
                .copy("Resources/nescarts.xml"),
                .copy("Resources/romfiles.xml"),
                .copy("Resources/AppIcon.icns"),
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
    ]
)
