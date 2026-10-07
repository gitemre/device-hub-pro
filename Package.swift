// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "DeviceHubPro",
    // The string form: `.v26` needs swift-tools-version 6.2.
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "DeviceHubPro", targets: ["DeviceHubProApp"]),
        .library(name: "DeviceHubProKit", targets: ["DeviceHubProKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.4.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0"),
        // In-app updates (MIT). Pinned exactly: the packaging script signs
        // the framework's nested code by name (Scripts/package-app.sh).
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0"),
    ],
    targets: [
        // The private simulator bridge (ObjC): CoreSimulator through dlopen,
        // libxpc's *_4sim entry points through dlsym, nothing private linked.
        .target(
            name: "DeviceHubProSimBridge",
            path: "Sources/DeviceHubProSimBridge",
            exclude: ["PROVENANCE.md"]
        ),
        // The private native live view of a physical iPhone (ObjC): CoreDevice and
        // the conferencing library through dlopen, nothing private linked.
        .target(
            name: "DeviceHubProNativeMirror",
            path: "Sources/DeviceHubProNativeMirror"
        ),
        .target(
            name: "DeviceHubProKit",
            dependencies: [
                "DeviceHubProSimBridge",
                "DeviceHubProNativeMirror",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            ],
            path: "Sources/DeviceHubProKit",
            exclude: [
                "Protos/google",
                // The language helper's source and notes; the dex is the resource.
                "Controls/LocaleHelper/DeviceHubProLocales.java",
                "Controls/LocaleHelper/README.md",
            ],
            resources: [
                // The pinned scrcpy server is pushed to the device at runtime;
                // its license and provenance notes ship with it.
                .copy("Scrcpy/Resources/scrcpy-server"),
                .copy("Scrcpy/Resources/LICENSE.scrcpy"),
                .copy("Scrcpy/Resources/README.md"),
                // The device-language helper, pushed and deleted per run
                // (Scripts/build-locale-helper.sh builds it from its source).
                .copy("Controls/LocaleHelper/devicehubpro-locales.dex"),
            ],
            plugins: [
                .plugin(name: "GRPCProtobufGenerator", package: "grpc-swift-protobuf")
            ]
        ),
        .executableTarget(
            name: "DeviceHubProApp",
            dependencies: [
                "DeviceHubProKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/DeviceHubProApp",
            // Copied, not processed: the app compiles the shader source at
            // runtime, and processing would ask for the separate Metal
            // toolchain in release builds (missing on plain Xcode installs).
            resources: [.copy("Shaders.metal")],
            linkerSettings: [
                // SwiftPM writes the deployment target into LC_BUILD_VERSION's
                // SDK slot, so a plain 26.0 build reads `sdk 26.0`: an older
                // SDK than the one the app is built and verified with. (At
                // the old 15.0 target the same slot silently opted the app
                // out of the macOS 26+ design: legacy traffic lights, toolbar
                // band, controls.) Claim the real SDK so the app gets the
                // current SDK's behaviour, like Device Hub. The minimum
                // (first number) must match `platforms` and packaging/
                // Info.plist's LSMinimumSystemVersion (DeploymentTargetTests
                // and package-app.sh check all three); the SDK (second) must
                // stay >= 26.0 (the design gate) and in sync with the
                // toolchain's SDK when it advances. `.unsafeFlags` also makes
                // this package ineligible as a dependency (it is the app).
                .unsafeFlags([
                    "-Xlinker", "-platform_version",
                    "-Xlinker", "macos",
                    "-Xlinker", "26.0",
                    "-Xlinker", "27.0",
                ])
            ]
        ),
        .testTarget(
            name: "DeviceHubProKitTests",
            dependencies: ["DeviceHubProKit"],
            path: "Tests/DeviceHubProKitTests",
            // Byte-exact device captures, read through #filePath rather than
            // bundled as resources.
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "DeviceHubProAppTests",
            dependencies: ["DeviceHubProApp", "DeviceHubProKit"],
            path: "Tests/DeviceHubProAppTests"
        ),
        // The iOS verifier's UIKit-free registry and readings, checked on the
        // Mac against controls-rows.json; the app itself (App/) is built for
        // the simulator by ios/verifier/build.sh, never by SwiftPM.
        .testTarget(
            name: "IOSVerifierRegistryTests",
            path: "ios/verifier",
            exclude: ["App", "Info.plist", "build.sh", "README.md"],
            sources: ["Shared", "RegistryTests"]
        ),
        // Debug tool for the simulator bridge (Scripts/ios-bridge-smoke.sh);
        // never packaged.
        .executableTarget(
            name: "DeviceHubProSimBridgeSmoke",
            dependencies: ["DeviceHubProKit"],
            path: "Sources/DeviceHubProSimBridgeSmoke"
        ),
    ]
)
