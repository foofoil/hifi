// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "hifi",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HiFiExtensionCore", targets: ["HiFiExtensionCore"]),
        .library(name: "HiFiExtensionRuntime", type: .dynamic, targets: ["HiFiExtensionRuntime"]),
        .executable(name: "hifi-inspect", targets: ["HiFiInspect"]),
        .executable(name: "hifi-runtime-smoke", targets: ["HiFiRuntimeSmoke"]),
        .executable(name: "hifi-hal-probe", targets: ["HiFiHALProbe"])
    ],
    targets: [
        .target(
            name: "MACLib",
            path: "Sources/MACLib",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("ThirdParty/MAC/Source/Shared"),
                .headerSearchPath("ThirdParty/MAC/Source/MACLib"),
                // 内嵌 Monkey's Audio 上游未标 override；第三方源码整体抑制该一致性告警，不改上游文件。
                .unsafeFlags(["-Wno-inconsistent-missing-override"]),
            ]
        ),
        .target(name: "HiFiExtensionCore", dependencies: ["MACLib"]),
        .target(name: "HiFiExtensionRuntime", dependencies: ["HiFiExtensionCore"]),
        .executableTarget(name: "HiFiInspect", dependencies: ["HiFiExtensionCore"]),
        .executableTarget(name: "HiFiRuntimeSmoke", dependencies: ["HiFiExtensionRuntime"]),
        .executableTarget(name: "HiFiHALProbe", dependencies: ["HiFiExtensionCore"]),
        .testTarget(
            name: "HiFiExtensionCoreTests",
            dependencies: ["HiFiExtensionCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "HiFiExtensionRuntimeTests", dependencies: ["HiFiExtensionRuntime"])
    ]
)
