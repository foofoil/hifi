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
        .target(name: "HiFiExtensionCore"),
        .target(name: "HiFiExtensionRuntime", dependencies: ["HiFiExtensionCore"]),
        .executableTarget(name: "HiFiInspect", dependencies: ["HiFiExtensionCore"]),
        .executableTarget(name: "HiFiRuntimeSmoke", dependencies: ["HiFiExtensionRuntime"]),
        .executableTarget(name: "HiFiHALProbe", dependencies: ["HiFiExtensionCore"]),
        .testTarget(name: "HiFiExtensionCoreTests", dependencies: ["HiFiExtensionCore"])
    ]
)
