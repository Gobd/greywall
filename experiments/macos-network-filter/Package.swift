// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GreywallNetworkExperiment",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "network-probe", targets: ["NetworkProbe"]),
        .library(name: "FilterPrototype", targets: ["FilterPrototype"]),
        .library(name: "NetworkPolicy", targets: ["NetworkPolicy"]),
        .library(name: "NativeControl", targets: ["NativeControl"]),
    ],
    targets: [
        .target(name: "ProcessInfoShim", linkerSettings: [.linkedLibrary("bsm")]),
        .target(name: "NetworkPolicy", dependencies: ["ProcessInfoShim"]),
        .target(name: "NativeControl", dependencies: ["NetworkPolicy"]),
        .target(name: "FilterPrototype", dependencies: ["NetworkPolicy", "NativeControl", "ProcessInfoShim"],
                linkerSettings: [.linkedFramework("NetworkExtension")]),
        .executableTarget(name: "NetworkProbe", dependencies: ["NetworkPolicy"],
                linkerSettings: [.linkedFramework("NetworkExtension")]),
        .testTarget(name: "NetworkPolicyTests", dependencies: ["NetworkPolicy", "NativeControl"]),
    ]
)
